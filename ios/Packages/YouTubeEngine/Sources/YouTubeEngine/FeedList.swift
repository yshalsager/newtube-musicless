import Foundation

/// A paged list as the phone shows it (US-019; the Android phone app's list rules):
/// - **No Shorts** (`ShortsFilter`): every list drops them, always; there is no setting. A Short is
///   what the item says it is, never a guess from its length.
/// - **Channels first** (`MobileSearchActivity.hoistChannels`): channel results among the first
///   page's first 10 items move to the top, in order.
/// - **Each item once:** a later page repeating an item doesn't add it again.
/// - **Top-up** (`FilteredPageTopUp`): a list that dropped Shorts and keeps fewer than 10 items asks
///   for its next page itself, at most 5 pages per user action, so a query of mostly Shorts ends
///   instead of paging forever and a short list still fills the screen.
public struct FeedList: Sendable {
    public static let enough = 10
    public static let maxAutomaticPages = 5
    static let hoistSlice = 10

    public private(set) var items: [FeedItem] = []
    public private(set) var continuation: String?
    /// Shorts dropped so far.
    public private(set) var droppedShorts = 0
    private var seen: Set<String> = []
    private var automaticPages = 0
    private var landed = false
    private var pages = 0

    public init() {}

    public var hasMore: Bool { continuation != nil }

    /// A page landed. Returns how many of its items were kept.
    @discardableResult
    public mutating func append(_ page: FeedPage) -> Int {
        let first = pages == 0
        pages += 1
        var kept: [FeedItem] = []
        for item in page.items {
            if item.kind == .short {
                droppedShorts += 1
                continue
            }
            guard seen.insert("\(item.kind.rawValue):\(item.id)").inserted else { continue }
            kept.append(item)
        }
        if first {
            // Channels within the first 10 kept items (Android hoists from the list it shows,
            // after the Shorts are gone).
            let channels = kept.prefix(Self.hoistSlice).filter { $0.kind == .channel }
            if !channels.isEmpty {
                let rest = kept.enumerated().filter { !($0.offset < Self.hoistSlice && $0.element.kind == .channel) }.map(\.element)
                kept = channels + rest
            }
        }
        items += kept
        continuation = page.continuation
        landed = true
        return kept.count
    }

    /// The user scrolled to the end (or started this list): a fresh top-up budget.
    public mutating func userAskedForMore() { automaticPages = 0 }

    /// The list's end came into view. In a list of at least `enough` items that took a scroll, so
    /// it's the user and refills the budget; in a shorter one it's a layout pass, which shares the
    /// top-up budget (`FilteredPageTopUp.takeAutomatic`): otherwise each page that keeps one item
    /// would show a new last row and ask again, forever. Whether to fetch the next page.
    public mutating func endCameIntoView() -> Bool {
        guard hasMore else { return false }
        if items.count >= Self.enough {
            automaticPages = 0
            return true
        }
        guard automaticPages < Self.maxAutomaticPages else { return false }
        automaticPages += 1
        return true
    }

    /// Right after a page landed: whether to fetch the next page now without the user
    /// (`FilteredPageTopUp.take`). A yes counts against the budget; at most one yes per page.
    public mutating func takeTopUp() -> Bool {
        let wasLanded = landed
        landed = false
        guard wasLanded, droppedShorts > 0, items.count < Self.enough, hasMore, automaticPages < Self.maxAutomaticPages else {
            return false
        }
        automaticPages += 1
        return true
    }
}
