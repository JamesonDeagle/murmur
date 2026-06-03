import SwiftUI
import AppKit

/// Floating overlay window that visually emerges from the MacBook notch
/// (or top-of-screen on Macs without a notch) and shows the recording
/// waveform / transcription orbital loader inside it.
///
/// Visual trick: the window is solid black with the top edge flush against
/// the screen edge and only the **bottom** corners rounded. To the eye it
/// reads as the physical notch "expanding" downward to make room for our
/// UI. On Macs without a notch the same pill just looks like a Dynamic-
/// Island-style tab at the top.
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

    // The pill the user sees: notch height (37 on M-series Pro) plus the
    // orbital loader's diameter (52pt). Centered content lands flush
    // against the notch's bottom edge.
    private let pillVisibleHeight: CGFloat = 89

    /// Extra transparent space BELOW the pill, sized to absorb the
    /// easeOutBack overshoot (peaks around +13% of pill height ≈ 12pt;
    /// 24pt gives a comfortable margin). Without this buffer the
    /// `scaleEffect` blooms past NSPanel.bounds and the bottom of the
    /// pill clips against the window's hard edge during the bounce.
    private let overshootBuffer: CGFloat = 24

    /// NSPanel height = pill + bounce slack. Top of the window stays
    /// flush with the top of the screen; the extra room is at the bottom
    /// (where it's invisible since the pill is opaque and that area is
    /// transparent).
    private var panelHeight: CGFloat { pillVisibleHeight + overshootBuffer }

    /// Pushed to the SwiftUI view so the pill renders at a fixed visible
    /// height regardless of the host NSPanel size.
    @Published var pillHeight: CGFloat = 89
    /// Fallback width for Macs without a physical notch (Mac mini, Studio,
    /// older MacBooks, external displays). 200 pt approximates an M-series
    /// notch so the pill keeps the same visual scale on every Mac.
    private let fallbackWidth: CGFloat = 200

    /// Computed in `repositionPanel()` and read by NSPanel.setFrame.
    private var panelWidth: CGFloat = 200

    /// Height of the notch / menu bar — content inside the panel needs to
    /// sit BELOW this so the physical notch doesn't cover the waveform.
    /// Recomputed on each show() in `repositionPanel()`.
    @Published var topInset: CGFloat = 24

    /// easeOutBack — quick start with a slight overshoot at the end so the
    /// notch "snaps" into place instead of arriving stiff. Bezier values
    /// are the CSS standard for easeOutBack (cubic-bezier 0.34, 1.56,
    /// 0.64, 1.0).
    private let showAnimation: Animation = .timingCurve(0.34, 1.56, 0.64, 1.0, duration: 0.26)
    /// easeOut — same fast start, gentle settle, no overshoot on the way
    /// out (Apple HIG recommends not bouncing on dismiss).
    private let hideAnimation: Animation = .easeOut(duration: 0.18)
    /// Match `hideAnimation` so the window only orders out after the fade
    /// has finished visually.
    private let hideAnimationDuration: TimeInterval = 0.18

    func show() {
        if panel == nil { createPanel() }
        repositionPanel()      // recompute every show — multi-monitor / display hot-plug
        mode = .recording
        pillHeight = pillVisibleHeight   // keep in sync if values change
        panel?.orderFront(nil)
        withAnimation(showAnimation) {
            isVisible = true
        }
    }

    func hide() {
        withAnimation(hideAnimation) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAnimationDuration + 0.04) { [weak self] in
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
        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // .statusBar — above the system menu bar so we visually flow out
        // of the notch instead of sitting under the menu bar.
        panel.level = .statusBar
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

    /// Position the panel so its **top edge is flush with the very top of
    /// the screen**, covering the menu bar / notch area entirely, and its
    /// **width matches the physical notch exactly** (or a notch-sized
    /// fallback on Macs without one). The black surface then reads as the
    /// physical notch stretching straight down — same width as the notch,
    /// extending only the height.
    ///
    /// `topInset` (notch height on MacBooks, menu-bar height elsewhere)
    /// is published so `WaveformView` can pad its content down past the
    /// notch — otherwise the waveform would be hidden behind the physical
    /// cutout.
    private func repositionPanel() {
        guard let panel = panel else { return }
        guard let screen = screenWithMouse()
                        ?? NSScreen.main
                        ?? NSScreen.screens.first else { return }

        let f = screen.frame
        // visibleFrame.maxY < frame.maxY by the notch height on M-series
        // (because the OS treats the notch as outside the safe area) or
        // by the menu bar height on Macs without a notch.
        topInset = max(24, f.maxY - screen.visibleFrame.maxY)
        panelWidth = Self.physicalNotchWidth(of: screen) ?? fallbackWidth

        let x = f.midX - panelWidth / 2
        let y = f.maxY - panelHeight   // flush against the top edge

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
    }

    /// Width of the MacBook camera notch on `screen`, or nil if this Mac
    /// has no notch.
    ///
    /// macOS 12+ exposes `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` —
    /// the menu-bar rectangles to the LEFT and RIGHT of the notch. The
    /// gap between them is the notch itself:
    ///
    ///     | leftArea ◀--notch--▶ rightArea |
    ///     0                                screen.width
    ///
    /// Both auxiliary areas return nil on Macs without a notch, which we
    /// treat as "no notch" and let the caller fall back to a fixed width.
    /// Measured widths on M-series MacBooks: 14"/16" Pro ≈ 187 pt,
    /// Air 13"/15" ≈ 174 pt.
    private static func physicalNotchWidth(of screen: NSScreen) -> CGFloat? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = screen.frame.width - leftArea.width - rightArea.width
        // Sanity: a real notch is wider than ~100 pt and narrower than
        // ~300 pt. Anything outside that, treat as a measurement glitch.
        guard width > 100, width < 300 else { return nil }
        return width
    }

    /// Screen currently containing the mouse cursor. For a menubar-only
    /// app with no key window this beats `NSScreen.main`, which can drift
    /// when foreground apps shuffle across displays.
    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}
