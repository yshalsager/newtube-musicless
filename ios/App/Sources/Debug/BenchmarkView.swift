import SwiftUI

/// Debug screen for US-006.
struct BenchmarkView: View {
    @State var benchmark: SeparationBenchmark
    var autoStart: Bool? = nil  // true = locked run, false = foreground run, nil = wait for a tap

    var body: some View {
        List {
            Section {
                Button("Run in the foreground") { Task { await benchmark.run(locked: false) } }
                Button("Run with the screen locked") { Task { await benchmark.run(locked: true) } }
            } footer: {
                Text("10 windows of 64 and of 512 frames per backend: ONNX Runtime CPU, and the CoreML "
                     + "execution provider with all compute units and with CPU + Neural Engine. The locked "
                     + "run plays silence and starts once the screen locks; keep the phone still.")
            }
            .disabled(benchmark.isBusy)

            Section("Status") {
                Text(status)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if !benchmark.summary.isEmpty {
                Section("Results") {
                    ForEach(Array(benchmark.summary.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Separation benchmark")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let autoStart { await benchmark.run(locked: autoStart) }
        }
    }

    private var status: String {
        switch benchmark.phase {
        case .idle: "Ready"
        case .waitingForLock: "Lock the screen (or wait for Auto-Lock); the run starts then"
        case .running(let what): "Running: \(what)"
        case .done(let message): "Done. \(message)"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
