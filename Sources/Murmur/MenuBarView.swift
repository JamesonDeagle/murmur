import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.state {
            case .loading:
                if let p = appState.downloadProgress, p.totalBytes > 0 {
                    // Downloading — show two lines: size+speed, fraction+ETA
                    Label(
                        "Loading \(p.modelName): \(formatBytes(p.bytesDownloaded)) / \(formatBytes(p.totalBytes))",
                        systemImage: "arrow.down.circle"
                    )
                    .disabled(true)
                    Text("\(Int(p.fraction * 100))% · \(formatSpeed(p.bytesPerSecond))\(formatETA(p.etaSeconds))")
                        .disabled(true)
                } else {
                    // Either initializing the whisper context (post-download)
                    // or download just started and we don't have totals yet.
                    Label("Loading model...", systemImage: "hourglass")
                        .disabled(true)
                }
            case .idle:
                Text("Option+Space — record / stop")
                    .disabled(true)
                Text("Escape — cancel")
                    .disabled(true)
            case .recording:
                Label("Recording...", systemImage: "mic.fill")
                    .disabled(true)
            case .transcribing:
                Label("Transcribing...", systemImage: "brain")
                    .disabled(true)
            }

            Divider()

            Menu("Model") {
                Button {
                    Task { await appState.switchModel(to: "turbo") }
                } label: {
                    if appState.activeModel == "turbo" {
                        Label("turbo (fast)", systemImage: "checkmark")
                    } else {
                        Text("turbo (fast)")
                    }
                }
                .disabled(appState.state != .idle)
                Button {
                    Task { await appState.switchModel(to: "large") }
                } label: {
                    if appState.activeModel == "large" {
                        Label("large (best quality)", systemImage: "checkmark")
                    } else {
                        Text("large (best quality)")
                    }
                }
                .disabled(appState.state != .idle)
            }

            Menu("Microphone") {
                let devices = InputDeviceManager.availableInputDevices()
                ForEach(devices) { device in
                    Button {
                        appState.selectInputDevice(device)
                    } label: {
                        if device.uid == appState.selectedInputDeviceUID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                    .disabled(appState.state != .idle)
                }
            }

            Divider()

            Button("Quit Murmur") {
                HotkeyManager.shared.unregister()
                Task { await appState.engine.cleanup() }
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    // MARK: - Formatting helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary           // 1024-based, matches what ggml file sizes report
        f.allowedUnits = [.useMB, .useGB]
        f.includesUnit = true
        f.zeroPadsFractionDigits = false
        return f.string(fromByteCount: bytes)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    /// Returns " · ETA 1m32s" (or "") so it can be appended unconditionally.
    private func formatETA(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "" }
        let total = Int(s.rounded())
        if total >= 3600 {
            let h = total / 3600, m = (total % 3600) / 60
            return " · ETA \(h)h\(m)m"
        } else if total >= 60 {
            let m = total / 60, sec = total % 60
            return " · ETA \(m)m\(sec)s"
        } else {
            return " · ETA \(total)s"
        }
    }
}
