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
/// On screens without a physical notch (external monitors, pre-2021
/// MacBooks, or a scaled mode letterboxed below the camera) the view
/// additionally draws a solid-black "Dynamic Island" body for the glow
/// to wrap — see `hasNotch` — so the contour outlines a real shape
/// instead of empty desktop.
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
    /// On notch-less screens these describe the synthetic island instead.
    @Published var topInset: CGFloat = 32
    @Published var notchWidth: CGFloat = 200
    /// Whether the target screen has a physical camera notch. When it
    /// doesn't, WaveformView draws a solid-black Dynamic-Island body under
    /// the glow — without it the stroke would outline an invisible
    /// rectangle in the middle of the menu bar. Recomputed per show() for
    /// the screen the cursor is on, so dragging between the built-in
    /// display and an external monitor switches modes per dictation.
    @Published var hasNotch: Bool = true

    /// Extra space the NSPanel needs around the notch for the blurred
    /// stroke to render without clipping. The glow's `blur(radius:)` can
    /// extend up to ~40 pt outside the stroke's path, so we pad the panel
    /// generously on the sides and below the notch.
    private let glowPaddingSides: CGFloat = 200
    private let glowPaddingBottom: CGFloat = 200

    /// Island geometry for screens without a physical notch. Width copies
    /// the real MBP 16" notch at default scaling (185 pt — also
    /// boring.notch's fallback), so the island reads as "the notch
    /// appeared here" rather than a foreign pill. Height tracks the menu
    /// bar of the target screen; the fallback covers a hidden menu bar
    /// (auto-hide setting / fullscreen space), where
    /// `frame.maxY - visibleFrame.maxY` collapses to 0.
    private let islandWidth: CGFloat = 185
    private let islandFallbackHeight: CGFloat = 30

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
        if let notch = Self.physicalNotchGeometry(of: screen) {
            hasNotch = true
            notchWidth = notch.width
            // safeAreaInsets.top, not the menu-bar gap: the gap collapses
            // to 0 when the menu bar hides (fullscreen space / auto-hide),
            // while the physical cutout obviously stays where it is.
            topInset = notch.height
        } else {
            hasNotch = false
            notchWidth = islandWidth
            // Match the menu-bar height of THIS screen (30 pt on Tahoe
            // external displays, 24-25 pt on earlier macOS) so the island
            // merges with the bar; guard against the hidden-menu-bar zero
            // and clamp exotic values to the plausible notch range.
            let gap = f.maxY - screen.visibleFrame.maxY
            topInset = gap >= 20 ? min(gap, 38) : islandFallbackHeight
        }
        panelWidth = notchWidth + glowPaddingSides * 2
        panelHeight = topInset + glowPaddingBottom

        let x = f.midX - panelWidth / 2
        let y = f.maxY - panelHeight   // flush against the top edge

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
    }

    /// Size of the MacBook camera notch on `screen`, or nil if this screen
    /// has none. The canonical presence signal is `safeAreaInsets.top > 0`
    /// (macOS 12+, same check as Ice / NotchDrop / boring.notch);
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are non-nil exactly
    /// when that inset is non-zero and give the menu-bar rectangles to the
    /// LEFT and RIGHT of the notch — the gap between them is the notch
    /// width. Both dimensions depend on the user's scaled resolution
    /// (height 22-38 pt, width ~127-220 pt), hence the sanity window
    /// instead of constants. A notched MacBook letterboxed below the
    /// camera by a 16:10 scaled mode reports zero insets — which correctly
    /// routes us to island mode, since no physical notch is visible there.
    private static func physicalNotchGeometry(
        of screen: NSScreen
    ) -> (width: CGFloat, height: CGFloat)? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = screen.frame.width - leftArea.width - rightArea.width
        guard width > 100, width < 300 else { return nil }
        return (width, inset)
    }

    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}
