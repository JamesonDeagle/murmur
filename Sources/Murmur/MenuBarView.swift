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
                            t("Loading \(p.modelName): \(formatBytes(p.bytesDownloaded)) / \(formatBytes(p.totalBytes))",
                              ru: "Загрузка \(p.modelName): \(formatBytes(p.bytesDownloaded)) / \(formatBytes(p.totalBytes))"),
                            systemImage: "arrow.down.circle"
                        )
                        .disabled(true)
                        Text("\(p.fractionPercent)% · \(formatSpeed(p.bytesPerSecond))\(formatETA(p.etaSeconds))")
                            .disabled(true)
                    } else {
                        // Fraction-only fallback: phase + percent, no byte counts.
                        // whisper always reports bytes, so this branch is dead
                        // today — kept for a future fraction-only engine.
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
                    Label(t("Loading \(appState.activeModel.shortName)...",
                          ru: "Загрузка \(appState.activeModel.shortName)…"),
                          systemImage: "hourglass")
                        .disabled(true)
                }
            case .idle:
                Text(t("\(appState.hotkeyLabel) — record / stop",
                     ru: "\(appState.hotkeyLabel) — запись / стоп"))
                    .disabled(true)
                Text(t("Escape — cancel",
                     ru: "Escape — отмена"))
                    .disabled(true)
            case .recording:
                Label(t("Recording...", ru: "Запись…"), systemImage: "mic.fill")
                    .disabled(true)
            case .transcribing:
                Label(t("Transcribing...", ru: "Распознавание…"), systemImage: "brain")
                    .disabled(true)
            case .paused:
                Label(t("Paused — model unloaded",
                      ru: "Пауза — модель выгружена"),
                      systemImage: "pause.circle")
                    .disabled(true)
                Text(t("Tap Resume to reload \(appState.activeModel.shortName)",
                     ru: "Нажмите «Продолжить», чтобы загрузить \(appState.activeModel.shortName)"))
                    .disabled(true)
            }

            Divider()

            Menu(t("Model", ru: "Модель")) {
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

            Menu(t("Microphone", ru: "Микрофон")) {
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

            Menu(t("Shortcut", ru: "Сочетание клавиш")) {
                ForEach(HotkeyCombo.allCases) { combo in
                    Button {
                        appState.setHotkeyCombo(combo)
                    } label: {
                        if appState.hotkeyCombo == combo {
                            Label(combo.resolved.label, systemImage: "checkmark")
                        } else {
                            Text(combo.resolved.label)
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
                    Label(t("Resume \(appState.activeModel.shortName)",
                          ru: "Продолжить \(appState.activeModel.shortName)"),
                          systemImage: "play.circle")
                }
            } else {
                Button {
                    Task { await appState.pauseModel() }
                } label: {
                    Label(t("Pause (free RAM)",
                          ru: "Пауза (освободить ОЗУ)"),
                          systemImage: "pause.circle")
                }
                .disabled(appState.state != .idle)
            }

            Divider()

            Button(t("Quit Murmur", ru: "Выйти")) {
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
        // ByteCountFormatter respects the system locale automatically —
        // "1.5 GB" in English locales becomes "1,5 ГБ" in Russian.
        return f.string(fromByteCount: bytes)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        let suffix = t("/s", ru: "/с")
        return "\(formatBytes(Int64(bytesPerSecond)))\(suffix)"
    }

    /// Returns " · ETA 1m32s" (or "") so it can be appended unconditionally.
    /// Russian variant uses "ост." (осталось) and ru abbreviations.
    private func formatETA(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "" }
        let total = Int(s.rounded())
        let etaPrefix = t(" · ETA ", ru: " · ост. ")
        let h = t("h", ru: "ч")
        let m = t("m", ru: "м")
        let sUnit = t("s", ru: "с")
        if total >= 3600 {
            let hh = total / 3600, mm = (total % 3600) / 60
            return "\(etaPrefix)\(hh)\(h)\(mm)\(m)"
        } else if total >= 60 {
            let mm = total / 60, ss = total % 60
            return "\(etaPrefix)\(mm)\(m)\(ss)\(sUnit)"
        } else {
            return "\(etaPrefix)\(total)\(sUnit)"
        }
    }
}
