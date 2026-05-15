import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    /// State combinations where editing settings (model / mic / pause) is safe.
    private var canEditSettings: Bool {
        appState.state == .idle || appState.state == .paused
    }

    var body: some View {
        Group {
            switch appState.state {
            case .loading:
                if let p = appState.downloadProgress {
                    if p.hasByteCount {
                        // Whisper-style: exact bytes + smoothed MB/s + ETA.
                        Label(
                            "Loading \(p.modelName): \(formatBytes(p.bytesDownloaded)) / \(formatBytes(p.totalBytes))",
                            systemImage: "arrow.down.circle"
                        )
                        .disabled(true)
                        Text("\(p.fractionPercent)% · \(formatSpeed(p.bytesPerSecond))\(formatETA(p.etaSeconds))")
                            .disabled(true)
                    } else {
                        // Parakeet/FluidAudio: fraction + phase only (no byte counts).
                        Label(
                            "\(p.phase) \(p.modelName)",
                            systemImage: "arrow.down.circle"
                        )
                        .disabled(true)
                        Text("\(p.fractionPercent)%")
                            .disabled(true)
                    }
                } else {
                    // Pre-progress (engine init / warmup) or post-progress (about to flip to idle).
                    Label("Loading \(appState.activeModel.shortName)...", systemImage: "hourglass")
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
            case .paused:
                Label("Paused — model unloaded", systemImage: "pause.circle")
                    .disabled(true)
                Text("Tap Resume to reload \(appState.activeModel.shortName)")
                    .disabled(true)
            }

            Divider()

            Menu("Model") {
                ForEach(SpeechModelOption.allCases) { option in
                    Button {
                        Task { await appState.switchModel(to: option) }
                    } label: {
                        if appState.activeModel == option {
                            Label(option.menuLabel, systemImage: "checkmark")
                        } else {
                            Text(option.menuLabel)
                        }
                    }
                    .disabled(!canEditSettings)
                }
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
                    .disabled(!canEditSettings)
                }
            }

            Divider()

            // Free / reload model context without quitting the app.
            // Useful when you want the ~600 MB–3 GB out of RAM/ANE/GPU but don't
            // want to lose the menubar app + Accessibility permission state.
            if appState.state == .paused {
                Button {
                    Task { await appState.resumeModel() }
                } label: {
                    Label("Resume \(appState.activeModel.shortName)", systemImage: "play.circle")
                }
            } else {
                Button {
                    Task { await appState.pauseModel() }
                } label: {
                    Label("Pause (free RAM)", systemImage: "pause.circle")
                }
                .disabled(appState.state != .idle)
            }

            Divider()

            Button("Quit Murmur") {
                HotkeyManager.shared.unregister()
                Task { await appState.engine?.cleanup() }
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
