import AVFoundation
import BackgroundTasks
import CoreML
import Darwin
import Metal
import UIKit
import VideoToolbox
import os

/// One measured value.
struct ProbeRow: Identifiable, Sendable {
    let key: String
    let value: String
    var id: String { key }
}

struct ProbeSection: Identifiable, Sendable {
    let title: String
    let rows: [ProbeRow]
    var id: String { title }
}

/// What this phone's OS and hardware allow (US-002). It never contains the device's name or UDID.
struct ProbeReport: Sendable {
    let generated: Date
    let milliseconds: Int
    let sections: [ProbeSection]

    /// Markdown, ready for docs/ios/DEVICE-PROBE.md.
    var text: String {
        var lines = ["# NewTube Musicless device probe",
                     "generated: \(generated.ISO8601Format())",
                     "app: \(BuildInfo.summary)",
                     "probe took: \(milliseconds) ms"]
        for section in sections {
            lines.append("")
            lines.append("## \(section.title)")
            lines += section.rows.map { "- \($0.key): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum DeviceProbe {
    /// `VTRegisterSupplementalVideoDecoderIfAvailable` lasts for the process, so only the first run
    /// after a launch sees the decoders as the OS ships them.
    private static var registeredSupplementalDecoders = false

    static func run() -> ProbeReport {
        let started = Date()
        let clock = ContinuousClock.now
        let sections = [
            system(), memory(), power(), screen(), videoDecode(), coreML(), backgroundTasks(), audioSession(),
        ]
        let elapsed = ContinuousClock.now - clock
        return ProbeReport(generated: started, milliseconds: Int(elapsed / .milliseconds(1)), sections: sections)
    }

    // MARK: Sections

    private static func system() -> ProbeSection {
        let info = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let simulator = "yes (timings prove nothing)"
        #else
        let simulator = "no"
        #endif
        return ProbeSection(title: "System", rows: [
            ProbeRow(key: "iOS", value: UIDevice.current.systemVersion),
            ProbeRow(key: "OS build", value: info.operatingSystemVersionString),
            ProbeRow(key: "model identifier", value: modelIdentifier()),
            ProbeRow(key: "simulator", value: simulator),
            ProbeRow(key: "CPU cores (active/total)", value: "\(info.activeProcessorCount)/\(info.processorCount)"),
            ProbeRow(key: "Metal GPU", value: MTLCreateSystemDefaultDevice()?.name ?? "none"),
            ProbeRow(key: "build configuration", value: buildConfiguration),
        ])
    }

    private static func memory() -> ProbeSection {
        let available = UInt64(os_proc_available_memory())
        return ProbeSection(title: "Memory", rows: [
            ProbeRow(key: "physical memory", value: bytes(ProcessInfo.processInfo.physicalMemory)),
            ProbeRow(key: "os_proc_available_memory()",
                     value: available == 0 ? "0 (no memory limit reported; normal in the simulator)" : bytes(available)),
            ProbeRow(key: "phys_footprint (this app now)", value: ProcessMetrics.footprint().map(bytes) ?? "unavailable"),
        ])
    }

    private static func power() -> ProbeSection {
        let info = ProcessInfo.processInfo
        return ProbeSection(title: "Power and thermal", rows: [
            ProbeRow(key: "thermal state", value: thermalName(info.thermalState)),
            ProbeRow(key: "Low Power Mode", value: info.isLowPowerModeEnabled ? "on" : "off"),
        ])
    }

    private static func screen() -> ProbeSection {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen else {
            return ProbeSection(title: "Screen", rows: [ProbeRow(key: "screen", value: "no window scene yet")])
        }
        let pixels = screen.nativeBounds.size
        return ProbeSection(title: "Screen", rows: [
            ProbeRow(key: "native pixels (portrait)", value: "\(Int(pixels.width)) x \(Int(pixels.height))"),
            ProbeRow(key: "native scale", value: String(format: "%.2f", screen.nativeScale)),
            ProbeRow(key: "max frames per second", value: "\(screen.maximumFramesPerSecond)"),
        ])
    }

    private static func videoDecode() -> ProbeSection {
        let codecs: [(name: String, type: CMVideoCodecType)] = [
            ("avc1", kCMVideoCodecType_H264), ("hvc1", kCMVideoCodecType_HEVC),
            ("vp09", kCMVideoCodecType_VP9), ("av01", kCMVideoCodecType_AV1),
        ]
        let fresh = !registeredSupplementalDecoders
        let before = codecs.map { VTIsHardwareDecodeSupported($0.type) }
        var registration = "not available (needs iOS 26.2)"
        var after: [Bool]?
        if #available(iOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
            registeredSupplementalDecoders = true
            registration = "called for vp09 and av01"
            after = codecs.map { VTIsHardwareDecodeSupported($0.type) }
        }
        var rows = [
            ProbeRow(key: "VTRegisterSupplementalVideoDecoderIfAvailable", value: registration),
            ProbeRow(key: "\"before\" column", value: fresh
                     ? "first probe since launch: decoders as the OS ships them"
                     : "already registered earlier in this process; relaunch for a true before"),
        ]
        for (index, codec) in codecs.enumerated() {
            let afterText = after.map { yesNo($0[index]) } ?? "n/a"
            rows.append(ProbeRow(key: "\(codec.name) hardware decode (before / after)",
                                 value: "\(yesNo(before[index])) / \(afterText)"))
        }
        // A software decoder registered for VP9 would not show in VTIsHardwareDecodeSupported, so
        // also try to open any decoder for a bare format description (no codec configuration).
        for codec in codecs {
            rows.append(ProbeRow(key: "\(codec.name) bare session create (after)",
                                 value: statusName(bareSessionStatus(codec.type))))
        }
        return ProbeSection(title: "Video decode", rows: rows)
    }

    private static func coreML() -> ProbeSection {
        ProbeSection(title: "Core ML", rows: [
            ProbeRow(key: "MLModel.availableComputeDevices",
                     value: MLModel.availableComputeDevices.map(deviceName).joined(separator: ", ")),
            ProbeRow(key: "MLComputeDevice.allComputeDevices",
                     value: MLComputeDevice.allComputeDevices.map(deviceName).joined(separator: ", ")),
        ])
    }

    private static func backgroundTasks() -> ProbeSection {
        guard #available(iOS 26.0, *) else {
            return ProbeSection(title: "Background tasks", rows: [
                ProbeRow(key: "BGTaskScheduler.supportedResources", value: "n/a (needs iOS 26)"),
            ])
        }
        let resources = BGTaskScheduler.supportedResources
        return ProbeSection(title: "Background tasks", rows: [
            ProbeRow(key: "BGTaskScheduler.supportedResources (raw)", value: "\(resources.rawValue)"),
            ProbeRow(key: "background GPU (.gpu)", value: yesNo(resources.contains(.gpu))),
        ])
    }

    /// Reads the session inactive, then active as the player will use it (.playback, .moviePlayback).
    /// `.mixWithOthers` keeps the probe from stopping whatever else is playing.
    private static func audioSession() -> ProbeSection {
        let session = AVAudioSession.sharedInstance()
        var rows = audioRows(session, label: "inactive")
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            rows += audioRows(session, label: "active")
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            rows.append(ProbeRow(key: "activation", value: "failed: \(error.localizedDescription)"))
        }
        return ProbeSection(title: "Audio session", rows: rows)
    }

    private static func audioRows(_ session: AVAudioSession, label: String) -> [ProbeRow] {
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        return [
            ProbeRow(key: "\(label): sample rate", value: String(format: "%.0f Hz", session.sampleRate)),
            ProbeRow(key: "\(label): IO buffer duration",
                     value: String(format: "%.2f ms (%.0f frames)", session.ioBufferDuration * 1000,
                                   session.ioBufferDuration * session.sampleRate)),
            ProbeRow(key: "\(label): output latency", value: String(format: "%.2f ms", session.outputLatency * 1000)),
            ProbeRow(key: "\(label): output channels", value: "\(session.outputNumberOfChannels)"),
            ProbeRow(key: "\(label): route outputs", value: outputs.isEmpty ? "none" : outputs),
        ]
    }

    // MARK: Helpers

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulated)"
        }
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func bareSessionStatus(_ codec: CMVideoCodecType) -> OSStatus {
        var format: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: 1920, height: 1080, extensions: nil,
                                                    formatDescriptionOut: &format)
        guard status == noErr, let format else { return status }
        var session: VTDecompressionSession?
        status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                              decoderSpecification: nil, imageBufferAttributes: nil,
                                              outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status
    }

    private static func statusName(_ status: OSStatus) -> String {
        let names: [OSStatus: String] = [
            noErr: "OK", kVTCouldNotFindVideoDecoderErr: "kVTCouldNotFindVideoDecoderErr",
            kVTVideoDecoderUnsupportedDataFormatErr: "kVTVideoDecoderUnsupportedDataFormatErr",
            kVTVideoDecoderBadDataErr: "kVTVideoDecoderBadDataErr",
            kVTVideoDecoderMalfunctionErr: "kVTVideoDecoderMalfunctionErr",
            kVTParameterErr: "kVTParameterErr",
            // QuickTime's codecExtensionNotFoundErr: a decoder answered but wants its config atom
            // (hvcC, vpcC) in the format description, so the decoder itself is present.
            -8971: "codecExtensionNotFoundErr: decoder present, needs its config atom",
        ]
        return "\(status)" + (names[status].map { " (\($0))" } ?? "")
    }

    private static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: "CPU"
        case .gpu(let gpu): "GPU (\(gpu.metalDevice.name))"
        case .neuralEngine(let engine): "Neural Engine (\(engine.totalCoreCount) cores)"
        @unknown default: "\(device)"
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown (\(state.rawValue))"
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        String(format: "%.0f MiB (%llu bytes)", Double(value) / 1_048_576, value)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
