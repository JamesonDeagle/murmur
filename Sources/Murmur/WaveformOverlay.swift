import SwiftUI
import AppKit

/// Floating overlay that surrounds the MacBook notch with an **ambient
/// light glow** while the app is recording or transcribing. There is no
/// solid panel any more — the host NSPanel is transparent and slightly
/// larger than the notch, just to give SwiftUI room to render the blurred
/// stroke of the glow around the notch's bottom and sides.
///
/// On a MacBook the physical notch covers the centre-top of the panel,
/// so the stroke is only visible **around the perimeter of the notch**
/// (the two thin rails to the left and right, and the wider arc below).
/// To the eye that reads as the notch itself emitting light.
///
/// On notch-less Macs (Mac mini, Studio, Air without notch) the same
/// rounded pill of glow sits at the top edge — looks intentional, like a
/// soft status indicator instead of an "outline of nothing".
@MainActor
class WaveformPanel: ObservableObject {
    private var panel: NSPanel?
    @Published var isVisible = false
    @Published var mode: WaveformMode = .recording
    /// Smoothed audio peak in [0, 1]. EMA over the per-frame max of the
    /// 11 RMS bands, so the glow's intensity / flow speed tracks
    /// loud↔quiet without jittering on every 60-Hz audio tick.
    /// WaveformView reads this for stroke width, blur radius, and flow
    /// rate. The raw 11-band array is consumed only on the audio
    /// callback to compute `smoothedLevel` — we don't store it; the old
    /// bar-rendering pipeline that needed all 11 bands is gone.
    @Published var smoothedLevel: CGFloat = 0

    enum WaveformMode {
        case recording
        case transcribing
    }

    /// Physical notch size — `topInset` is the notch height, `notchWidth`
    /// is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
    /// On notch-less Macs both fall back to plausible defaults so the glow
    /// has a sensible footprint to wrap.
    @Published var topInset: CGFloat = 32
    @Published var notchWidth: CGFloat = 200

    /// Extra space the NSPanel needs around the notch for the blurred
    /// stroke to render without clipping. The glow's `blur(radius:)` can
    /// extend up to ~40 pt outside the stroke's path, so we pad the panel
    /// generously on the sides and below the notch.
    private let glowPaddingSides: CGFloat = 160
    private let glowPaddingBottom: CGFloat = 170

    /// Fallback for Macs without a physical notch.
    private let fallbackWidth: CGFloat = 200

    /// Computed in `repositionPanel()` and read by NSPanel.setFrame.
    private var panelWidth: CGFloat = 320
    private var panelHeight: CGFloat = 130

    private let showAnimation: Animation = .easeOut(duration: 0.22)
    private let hideAnimation: Animation = .easeOut(duration: 0.18)
    private let hideAnimationDuration: TimeInterval = 0.18

    /// EMA smoothing factor for `smoothedLevel`. Lower = more reactive,
    /// higher = lazier. 0.4 gives a snappy response — each spoken
    /// syllable visibly bumps the flow speed instead of getting averaged
    /// out into a vague "you're talking" baseline. Anything below 0.3
    /// starts to feel jittery on every audio frame.
    private let levelSmoothing: CGFloat = 0.4

    func show() {
        if panel == nil { createPanel() }
        repositionPanel()   // recompute every show — multi-monitor / display hot-plug
        mode = .recording
        smoothedLevel = 0
        panel?.orderFront(nil)
        withAnimation(showAnimation) {
            isVisible = true
        }
    }

    func hide() {
        withAnimation(hideAnimation) {
            isVisible = false
        }
        // Reset mode out of `.transcribing` so any animation loops keyed
        // on `panel.mode == .transcribing` in WaveformView stop scheduling
        // themselves (otherwise the loop would burn main-thread budget
        // forever after the panel is invisible — that's how v3.20 broke
        // the Option+Space hotkey).
        mode = .recording
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAnimationDuration + 0.04) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func setTranscribing() {
        mode = .transcribing
    }

    func updateLevels(_ newLevels: [Float]) {
        // Track the loudest band as our intensity signal; EMA-smooth it.
        // We deliberately don't @Published-store the raw array — the new
        // ambient-glow renderer only needs the smoothed peak, and a
        // 60 Hz @Published array would trigger objectWillChange on every
        // audio frame for no consumer.
        let peak = CGFloat(newLevels.max() ?? 0)
        smoothedLevel = smoothedLevel * levelSmoothing + peak * (1 - levelSmoothing)
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
        // .statusBar — above the system menu bar so the glow's bottom
        // arc lights up the menu-bar area instead of being hidden under
        // it.
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

    /// Size the panel so the notch sits **centred-horizontally** and
    /// **flush with the top edge** of the panel, with `glowPaddingSides`
    /// of breathing room on each side and `glowPaddingBottom` below the
    /// notch. That leaves enough transparent area for the blurred stroke
    /// to draw the ambient glow without clipping at the panel edges.
    private func repositionPanel() {
        guard let panel = panel else { return }
        guard let screen = screenWithMouse()
                        ?? NSScreen.main
                        ?? NSScreen.screens.first else { return }

        let f = screen.frame
        topInset = max(24, f.maxY - screen.visibleFrame.maxY)
        notchWidth = Self.physicalNotchWidth(of: screen) ?? fallbackWidth
        panelWidth = notchWidth + glowPaddingSides * 2
        panelHeight = topInset + glowPaddingBottom

        let x = f.midX - panelWidth / 2
        let y = f.maxY - panelHeight   // flush against the top edge

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
    }

    /// Width of the MacBook camera notch on `screen`, or nil if this Mac
    /// has no notch. macOS 12+ exposes `auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea` — the menu-bar rectangles to the LEFT and
    /// RIGHT of the notch. The gap between them is the notch itself.
    private static func physicalNotchWidth(of screen: NSScreen) -> CGFloat? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = screen.frame.width - leftArea.width - rightArea.width
        guard width > 100, width < 300 else { return nil }
        return width
    }

    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}
