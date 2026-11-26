import SwiftUI
import UIKit

/// Debug screen for US-002: runs the probe on open, logs the report, and copies it on request.
struct DeviceProbeView: View {
    @State private var report: ProbeReport?
    @State private var copied = false

    var body: some View {
        List {
            if let report {
                ForEach(report.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.key)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(row.value)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Device probe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy report") {
                    guard let report else { return }
                    UIPasteboard.general.string = report.text
                    copied = true
                }
                .disabled(report == nil)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Run again", action: run)
            }
        }
        .task {
            if report == nil { run() }
        }
    }

    private func run() {
        let next = DeviceProbe.run()
        report = next
        copied = false
        for line in next.text.split(separator: "\n", omittingEmptySubsequences: false) {
            AppLog.probe.info("probe \(line)")
        }
    }
}
