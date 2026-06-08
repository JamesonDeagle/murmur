import SwiftUI

/// Notch-style overlay. Solid-black pill that sits immediately below the
/// MacBook notch (or below the menu bar on Macs without one). When shown
/// the pill **expands vertically downward** — width is constant, only the
/// height grows from zero to full. To the eye it reads as something
/// emerging from under the notch.
///
/// Inside the pill lives a single shared row of 11 Capsule bars that
/// represents both **recording** (each bar tracks live mic levels) and
/// **transcribing** (the outer bars collapse to zero height, the centre
/// bar shrinks to a circle and starts pulsing). Using one row for both
/// states gives the morph the user wants — the transcription indicator
/// literally grows out of the rightmost moment of the waveform — instead
/// of a hard cross-fade between waveform and spinner.
struct WaveformView: View {
    @EnvironmentObject var panel: WaveformPanel

    private let barCount = 11
    /// Bar width / capsule diameter. The same value doubles as the
    /// **minimum visible height** so the bar collapses to a perfect circle
    /// at low volume instead of a hair-thin sliver. Per the Figma spec
    /// (Website / node 13728-2528) the quietest bars must read as dots,
    /// not lines.
    private let barWidth: CGFloat = 6
    private let barSpacing: CGFloat = 4
    /// Peak heights when level=1.0. The centre is tallest, falling
    /// symmetrically toward the edges — same envelope as Apple's Voice
    /// Memos and the Figma reference.
    private let baseHeights: [CGFloat] = [12, 18, 24, 30, 34, 40, 34, 30, 24, 18, 12]
    /// Index of the bar that survives the transcribing collapse and turns
    /// into the pulsing dot.
    private let centerIndex = 5

    /// Bottom-only corner radius. The top edge of the panel is flush with
    /// the very top of the screen and continues the physical notch line,
    /// so it MUST be a straight 90° corner there — anything rounded would
    /// reveal a seam against the screen edge. Only the bottom two corners
    /// curve away from the notch, like a teardrop being pulled downward.
    private let cornerRadius: CGFloat = 22

    /// Drives the pulsing of the centre dot during `.transcribing`. Kept
    /// out of WaveformPanel because it's pure animation state with no
    /// outside consumers.
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            if panel.isVisible {
                pill
                    // Pill's *visible* height is fixed. The host NSPanel is
                    // intentionally taller (see overshootBuffer in
                    // WaveformOverlay) so that the easeOutBack overshoot
                    // pushes the pill's scaled-up bottom edge into
                    // transparent slack instead of clipping against the
                    // window's hard edge.
                    .frame(height: panel.pillHeight)
                    .transition(.modifier(
                        active: NotchExpand(progress: 0),
                        identity: NotchExpand(progress: 1)
                    ))
            }
        }
        // Anchor the panel to the top of its window so the scale anchor
        // (.top) and the physical top edge stay aligned during animation.
        // The remaining vertical space is the overshoot buffer.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var pill: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .overlay(barsRow)
        // No drop-shadow: SwiftUI renders `.shadow` against the view's
        // rectangular bounding box rather than the shape's path, which
        // leaked sharp corners at the bottom of the pill against the
        // transparent NSPanel background. The pill reads clearly enough
        // against any backdrop without one.
    }

    @ViewBuilder
    private var barsRow: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                bar(at: i)
            }
        }
        // **Fixed-height bar zone (40 pt = centre peak).** Without this
        // explicit frame, the HStack's height tracks `max(bar heights)`,
        // which jiggles as the centre bar pumps from level changes —
        // and because vertical alignment inside the HStack is `.center`,
        // every bar's mid-line moves whenever the HStack height moves,
        // so the whole row visibly drifts up and down with the audio.
        // Locking the HStack to a constant 40 pt keeps the centre axis
        // pinned, and bars grow / shrink symmetrically around it —
        // exactly the look the user described as "от центра по
        // горизонтали".
        .frame(height: 40)
        // Top `panel.topInset` pt sits behind the notch / menu bar.
        // Pinning the bar zone to `.top` of the post-padding region
        // puts the **peak of the centre bar flush against the notch's
        // bottom edge**; the spare 4 pt added to `pillVisibleHeight`
        // then collects entirely at the bottom of the pill as
        // breathing room.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, panel.topInset)
        // No row-level `.animation(value: panel.mode)` here — each bar
        // owns its own animation with its own staggered delay so the
        // collapse propagates as a wave from the edges inward.
        .onChange(of: panel.mode) { _, newMode in
            handleModeChange(newMode)
        }
    }

    private func bar(at i: Int) -> some View {
        let isCenter = (i == centerIndex)
        let height = barHeight(at: i)
        // Outer bars vanish via scale + opacity. We DON'T animate their
        // height — keeping the bar's geometry stable during the fade
        // stops it from looking like it's "morphing into the centre dot"
        // (the bug the user just hit).
        let visibilityScale: CGFloat = (panel.mode == .transcribing && !isCenter) ? 0.0 : 1.0
        let opacity: CGFloat = (panel.mode == .transcribing && !isCenter) ? 0.0 : 1.0
        let pulseFactor: CGFloat = (panel.mode == .transcribing && isCenter) ? pulseScale : 1.0
        let modeDelay = collapseDelay(forBar: i)
        // **Centre snaps to circle instantly** (animation = nil). The user
        // wants the centre to BE a dot the moment the edges start their
        // disappearance wave, not to gradually shrink alongside them.
        // Edges fade out with a sharp Material "decelerate" easeOut and
        // a per-pair stagger.
        let modeAnimation: Animation? = isCenter
            ? nil
            : .timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(modeDelay)
        return Capsule()
            .fill(Color.white.opacity(0.92))
            .frame(width: barWidth, height: height)
            .scaleEffect(visibilityScale * pulseFactor, anchor: .center)
            .opacity(Double(opacity))
            .animation(modeAnimation, value: panel.mode)
            // Live RMS jitter only while actually recording — a competing
            // animation during transcribing makes the centre dot wobble.
            .animation(
                panel.mode == .recording ? .easeOut(duration: 0.08) : nil,
                value: panel.levels
            )
    }

    /// Stagger so bars disappear in pairs from the edges inward when we
    /// enter `.transcribing`:
    ///
    ///   pair (0, 10) — delay 0.000s   ← first to go
    ///   pair (1, 9)  — delay 0.045s
    ///   pair (2, 8)  — delay 0.090s
    ///   pair (3, 7)  — delay 0.135s
    ///   pair (4, 6)  — delay 0.180s
    ///   centre (5)   — delay 0.225s   ← morphs to a dot
    ///
    /// On the way back to `.recording` everything pops in at once
    /// (delay = 0) so the row doesn't feel reluctant to restart.
    private func collapseDelay(forBar i: Int) -> Double {
        guard panel.mode == .transcribing else { return 0 }
        let distanceFromCenter = abs(i - centerIndex)
        return Double(centerIndex - distanceFromCenter) * 0.045
    }

    /// Height of the i-th bar for the current mode.
    ///
    /// `.recording`: scaled by live RMS, clamped to `barWidth` so the
    /// quietest bars read as round dots, never as thin lines.
    /// `.transcribing`:
    ///   - centre — `barWidth` (a circle). Snapped instantly via
    ///     `modeAnimation = nil` in `bar(at:)`.
    ///   - edges — kept at their full envelope height. They fade out
    ///     via scale + opacity; not touching height stops the bar from
    ///     looking like it's collapsing toward the centre dot during the
    ///     wave.
    private func barHeight(at i: Int) -> CGFloat {
        if i == centerIndex && panel.mode == .transcribing {
            return barWidth
        }
        let level = CGFloat(i < panel.levels.count ? max(0.15, panel.levels[i]) : 0.15)
        let raw = baseHeights[i] * level
        return max(barWidth, raw)
    }

    /// Start / stop the centre dot's pulse when the mode flips.
    ///
    /// We delay the start of the pulse so the wave-collapse has time to
    /// land — otherwise the dot starts pulsing while the outer bars are
    /// still fading, which reads as noisy.
    ///
    /// The pulse itself is a two-stroke loop (not a `repeatForever`
    /// autoreverse), so we can give each direction its own animation:
    /// **springy bounce on the way up**, **calm easeOut on the way down**.
    /// On the way out of `.transcribing` we snap back to 1; the guard in
    /// each completion handler then breaks the loop.
    private func handleModeChange(_ newMode: WaveformPanel.WaveformMode) {
        if newMode == .transcribing {
            // Reset first so we don't start the pulse from whatever scale
            // it was at the last time we transcribed.
            pulseScale = 1.0
            // Timed to the moment the innermost pair (bars 4 and 6,
            // distance=1 from centre) finishes fading out:
            //   collapseDelay(4) = (5 − 1) × 0.045 = 0.18 s
            //   + animation duration                = 0.22 s
            //   ------------------------------------ = 0.40 s
            // So the centre dot starts its first expansion the instant
            // it becomes the only visible element. Earlier we waited an
            // extra 0.1 s with the dot just sitting there, which on
            // short transcriptions sometimes finished before the pulse
            // had even started.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // Mode could have flipped back during the delay.
                guard panel.mode == .transcribing else { return }
                pulseUp()
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                pulseScale = 1.0
            }
        }
    }

    /// Spring up to peak scale. `extraBounce: 0.35` gives the dot a
    /// pronounced overshoot — it shoots past the target and wobbles into
    /// place. As soon as the spring settles, `pulseDown()` takes over.
    private func pulseUp() {
        withAnimation(.bouncy(duration: 0.42, extraBounce: 0.35)) {
            pulseScale = 2.0
        } completion: {
            guard panel.mode == .transcribing else { return }
            pulseDown()
        }
    }

    /// Calm easeOut back to 1.0 — no overshoot on the way down per the
    /// user's spec. Immediately schedules the next `pulseUp()` so the
    /// loop continues without a visible pause at the bottom.
    private func pulseDown() {
        withAnimation(.easeOut(duration: 0.35)) {
            pulseScale = 1.0
        } completion: {
            guard panel.mode == .transcribing else { return }
            pulseUp()
        }
    }
}

// MARK: - Notch expansion transition

/// Custom transition modifier: scales ONLY along the Y axis from the top
/// anchor and fades. So the pill drops out from under the notch instead
/// of also stretching horizontally (which the v3.19 spring/scale combo
/// did, looking like the notch itself was widening — wrong).
struct NotchExpand: ViewModifier {
    /// 0 = collapsed (zero height), 1 = fully expanded.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: progress, anchor: .top)
            .opacity(progress)
    }
}
