import SwiftUI
import AppKit

@MainActor
class WaveformPanel: ObservableObject {
    private var panel: NSPanel?
    @Published var isVisible = false
    @Published var mode: WaveformMode = .recording
    @Published var levels: [Float] = Array(repeating: 0.15, count: 11)

    enum WaveformMode {
        case recording
        case transcribing
    }

    // Размер панели — единый источник истины для create + reposition
    private let panelWidth: CGFloat = 260
    private let panelHeight: CGFloat = 140
    private let bottomMargin: CGFloat = 60

    func show() {
        if panel == nil { createPanel() }
        repositionPanel()           // пересчёт на каждый show — учитывает текущий монитор / Dock
        mode = .recording
        panel?.orderFront(nil)
        isVisible = true
    }

    func hide() {
        isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func setTranscribing() {
        mode = .transcribing
    }

    func updateLevels(_ newLevels: [Float]) {
        levels = newLevels
    }

    private func createPanel() {
        // Initial frame nominal — реальная позиция выставится в repositionPanel().
        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostView = NSHostingView(rootView:
            WaveformView()
                .environmentObject(self)
        )
        hostView.frame = panel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostView)

        self.panel = panel
    }

    /// Центрирует панель по горизонтали на экране с курсором, у нижнего края.
    /// Пересчитывается на каждом show() — это исправляет «иногда левее, иногда правее»
    /// при multi-monitor / переключении приложений / отключении внешнего экрана.
    private func repositionPanel() {
        guard let panel = panel else { return }
        guard let screen = screenWithMouse()
                        ?? NSScreen.main
                        ?? NSScreen.screens.first else { return }

        let f = screen.visibleFrame   // visibleFrame, а не frame — исключает Dock и menubar
        let x = f.midX - panelWidth / 2
        let y = f.minY + bottomMargin

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
    }

    /// Экран, на котором сейчас находится курсор мыши.
    /// Для menubar-app без key window это надёжнее, чем NSScreen.main.
    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}
