import Foundation
import os

/// One adaptive file's init segment, segment index and segments, read through a `MediaFetcher`
/// (US-012). The first request takes the init and index ranges plus whatever follows them up to the
/// fetcher's first-chunk size, so the opening segment (≈ 160 KB for 10 s of 128 kbps AAC) usually
/// arrives with them: one round trip instead of three before the first sound.
public struct FMP4Header: Sendable {
    public var initSegment: FMP4Init
    public var index: FMP4SegmentIndex
    /// Bytes read past the index (the start of the first segments), reused by `segments(from:)`.
    public var prefix: Data
    public var prefixOffset: Int64

    public func track(_ kind: FMP4Track.Kind) -> FMP4Track? { initSegment.tracks.first { $0.kind == kind } }
}

public enum FMP4Reader {
    /// Reads and parses the init and index ranges (inclusive byte ranges from the /player answer).
    public static func open(_ fetcher: MediaFetcher, initRange: ClosedRange<Int64>,
                            indexRange: ClosedRange<Int64>) async throws -> FMP4Header {
        let length = await fetcher.file.contentLength
        let first = fetcher.configuration.firstChunk
        let initData: Data, indexData: Data, prefix: Data
        if indexRange.lowerBound == initRange.upperBound + 1 {
            let end = min(max(indexRange.upperBound, initRange.lowerBound + first - 1), length - 1)
            let data = try await fetcher.read(initRange.lowerBound...end)
            func slice(_ range: ClosedRange<Int64>) -> Data {
                data.subdata(in: Int(range.lowerBound - initRange.lowerBound)..<Int(range.upperBound - initRange.lowerBound + 1))
            }
            initData = slice(initRange)
            indexData = slice(indexRange)
            prefix = end > indexRange.upperBound ? slice((indexRange.upperBound + 1)...end) : Data()
        } else {
            initData = try await fetcher.read(initRange)
            indexData = try await fetcher.read(indexRange)
            prefix = Data()
        }
        return FMP4Header(initSegment: try FMP4Demuxer.parseInit(initData),
                          index: try FMP4Demuxer.parseIndex(indexData, fileOffset: indexRange.lowerBound),
                          prefix: prefix, prefixOffset: indexRange.upperBound + 1)
    }

    /// The segments from sidx reference `start` to the end, each whole. Pull-based: requests group
    /// consecutive segments, starting at the fetcher's first-chunk size and doubling to its maximum
    /// (always at least one segment). Segments in `cache` are served without a request (a group stops
    /// before one), and fetched ones are added to it. With `prefetch`, the next group's request starts
    /// as soon as the current group is handed out, so a large video segment is on its way while the
    /// previous one is still being enqueued.
    public static func segments(_ fetcher: MediaFetcher, header: FMP4Header, from start: Int,
                                cache: SegmentCache? = nil, prefetch: Bool = false) -> FMP4Segments {
        FMP4Segments(fetcher: fetcher, references: header.index.references, start: start,
                     prefix: header.prefix, prefixOffset: header.prefixOffset,
                     first: fetcher.configuration.firstChunk, maxSize: fetcher.configuration.maxChunk,
                     cache: cache, prefetch: prefetch)
    }
}

/// Recently read segments of one file, least recently used out first once over `capacity` bytes, so
/// a seek back or a Remove-music restart at the same place doesn't fetch them again. Many segments
/// fit (≈ 100 of 10 s AAC in 16 MB), so the segment being played is never the one a new write evicts.
public final class SegmentCache: Sendable {
    private struct State {
        var entries: [Int: Data] = [:]
        var order: [Int] = []  // least recent first
        var bytes = 0
    }

    public let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int) { self.capacity = capacity }

    public func segment(_ index: Int) -> Data? {
        state.withLock { state in
            guard let data = state.entries[index] else { return nil }
            state.order.removeAll { $0 == index }
            state.order.append(index)
            return data
        }
    }

    public func store(_ index: Int, _ data: Data) {
        state.withLock { state in
            if let old = state.entries[index] {
                state.bytes -= old.count
                state.order.removeAll { $0 == index }
            }
            state.entries[index] = data
            state.order.append(index)
            state.bytes += data.count
            while state.bytes > capacity, state.order.count > 1 {
                let evicted = state.order.removeFirst()
                state.bytes -= state.entries.removeValue(forKey: evicted)?.count ?? 0
            }
        }
    }

    public var byteCount: Int { state.withLock { $0.bytes } }
    public func contains(_ index: Int) -> Bool { state.withLock { $0.entries[index] != nil } }
}

public struct FMP4Segments: AsyncSequence, Sendable {
    public struct Segment: Sendable {
        /// Index of the sidx reference.
        public let index: Int
        public let reference: FMP4SegmentIndex.Reference
        public let data: Data
        /// The first segment of a range request that went to googlevideo (not the cache or the
        /// header's prefix): the wall rule reads request starts (US-017).
        public var requestStart = false
    }

    let fetcher: MediaFetcher
    let references: [FMP4SegmentIndex.Reference]
    let start: Int
    let prefix: Data
    let prefixOffset: Int64
    let first: Int64
    let maxSize: Int64
    let cache: SegmentCache?
    let prefetch: Bool

    public func makeAsyncIterator() -> Iterator {
        Iterator(sequence: self, next: start, size: first)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let sequence: FMP4Segments
        var next: Int
        var size: Int64
        var buffered: [Segment] = []
        var pending: Task<[Segment], Error>?

        public mutating func next() async throws -> Segment? {
            if buffered.isEmpty {
                if pending == nil { pending = schedule() }
                guard let task = pending else { return nil }
                pending = nil
                buffered = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            let segment = buffered.removeFirst()
            if buffered.isEmpty && sequence.prefetch && pending == nil { pending = schedule() }
            return segment
        }

        /// Stops a prefetch in flight (the consumer is done with this position).
        public mutating func cancel() {
            pending?.cancel()
            pending = nil
        }

        /// The next group's work: cached segments at once, or one request for consecutive uncached
        /// ones; nil at the end of the file.
        private mutating func schedule() -> Task<[Segment], Error>? {
            let sequence = sequence
            let references = sequence.references
            guard next < references.count else { return nil }
            let first = next
            if let cache = sequence.cache, let data = cache.segment(first) {
                var group = [Segment(index: first, reference: references[first], data: data)]
                while first + group.count < references.count, let more = cache.segment(first + group.count) {
                    group.append(Segment(index: first + group.count, reference: references[first + group.count], data: more))
                }
                next = first + group.count
                return Task { group }
            }
            // Group whole uncached segments up to the current request size (at least one).
            var last = first
            while last + 1 < references.count, sequence.cache?.contains(last + 1) != true,
                  references[last + 1].bytes.upperBound - references[first].bytes.lowerBound + 1 <= size {
                last += 1
            }
            next = last + 1
            let wanted = references[first].bytes.lowerBound...references[last].bytes.upperBound
            // Bytes already read by `open` cover the start of the range; fetch only the rest.
            let prefixEnd = sequence.prefixOffset + Int64(sequence.prefix.count) - 1
            var head = Data()
            var from = wanted.lowerBound
            if !sequence.prefix.isEmpty, wanted.lowerBound >= sequence.prefixOffset, wanted.lowerBound <= prefixEnd {
                let upTo = Swift.min(prefixEnd, wanted.upperBound)
                head = sequence.prefix.subdata(in: Int(wanted.lowerBound - sequence.prefixOffset)..<Int(upTo - sequence.prefixOffset + 1))
                from = upTo + 1
            }
            if from <= wanted.upperBound { size = Swift.min(size * 2, sequence.maxSize) }
            let range = first...last
            return Task { [head, from] in
                var data = head
                let fetched = from <= wanted.upperBound
                if fetched { data.append(try await sequence.fetcher.read(from...wanted.upperBound)) }
                return range.map { index in
                    let bytes = references[index].bytes
                    let segment = data.subdata(in: Int(bytes.lowerBound - wanted.lowerBound)..<Int(bytes.upperBound - wanted.lowerBound + 1))
                    sequence.cache?.store(index, segment)
                    return Segment(index: index, reference: references[index], data: segment,
                                   requestStart: fetched && bytes.contains(from))
                }
            }
        }
    }
}
