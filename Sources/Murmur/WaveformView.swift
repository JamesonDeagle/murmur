import SwiftUI

/// Ambient-light glow that wraps the perimeter of the MacBook notch.
///
/// The host NSPanel (see WaveformOverlay) is sized as
/// `notchWidth + 2 × glowPaddingSides × topInset + glowPaddingBottom`
/// (currently `notchWidth + 320 × topInset + 170`). The notch occupies
/// the top-centre, so the glow's blurred stroke is only visible **around
/// the notch's lower contour** — two side rails plus a wide arc below.
/// On notch-less Macs the same shape sits at the top edge as a soft
/// status indicator.
///
/// While **recording**: colours flow **left → right** along the contour
/// (pink starts at the left, drifts right, mixes with white/yellow/cyan).
/// The flow speed and the stroke intensity both scale with the mic level
/// — quiet talking gives a slow, gentle shimmer; loud talking ramps it
/// into a fast, bright stream.
///
/// While **transcribing**: the palette switches to blue ↔ white. The
/// flow keeps moving at a steady moderate pace; intensity breathes on a
/// slow sine instead of from RMS, since the mic is no longer recording.
struct WaveformView: View {
    @EnvironmentObject var panel: WaveformPanel

    // MARK: - Intensity (stroke width + blur)

    /// Idle baseline so the glow is faintly visible at silence — just
    /// enough that you know the recorder is on, not enough to compete
    /// with anything on screen. Lowered from 0.15 so silence reads as
    /// "thin shimmer" and talking reads as "this thing is alive".
    private let baseIntensity: CGFloat = 0.06
    private let maxIntensity: CGFloat = 1.0

    /// Stroke width and blur radius scale linearly from idle → peak.
    /// Baseline values are tiny (1 / 3 pt) so silence renders as a very
    /// thin halo; gain values are large so loud speech blooms out
    /// dramatically — overall stroke ratio is now ~25× silence→peak,
    /// up from ~5× before.
    private let baseStroke: CGFloat = 1
    private let strokeGain: CGFloat = 36
    private let baseBlur: CGFloat = 3
    private let blurGain: CGFloat = 46

    /// Power-curve boost on the smoothed level. Audio RMS lives mostly
    /// in the lower half of [0, 1]; `pow(level, 0.55)` lifts that into
    /// the visibly-reactive band while still letting peaks max out.
    private let levelCurve: CGFloat = 0.55

    // MARK: - Flow speed (gradient phase)

    /// Baseline cycle frequency at silence — one full colour cycle every
    /// ~25 seconds. Deliberately glacial so the glow visibly *stops*
    /// flowing when the user isn't talking, and any speech reads as a
    /// dramatic speed-up by contrast.
    private let basePhaseSpeed: CGFloat = 0.04
    /// Additional cycles-per-second at level=1.0. So a loud speaker can
    /// push the cycle rate up to ~1.24 cps = one cycle every 0.8 s.
    /// The contribution runs through `speedLevelCurve` first so quiet
    /// speech gets a disproportionately large bump (sqrt curve), giving
    /// the user clear visual feedback even when they don't shout.
    private let levelSpeedBoost: CGFloat = 1.2
    /// Power curve applied to level before it multiplies `levelSpeedBoost`.
    /// 0.5 = sqrt → quiet/medium volume jumps the speed dramatically, peaks
    /// still max out. Compared to a linear mapping this gives:
    ///   - level 0.10 →  37 % boost (instead of 10 %)
    ///   - level 0.30 →  55 % boost (instead of 30 %)
    ///   - level 0.50 →  71 % boost (instead of 50 %)
    /// So quiet conversation already feels like brisk shimmer, not just
    /// "slightly faster than silence".
    private let speedLevelCurve: CGFloat = 0.5
    /// Constant moderate flow rate used during transcribing (no live
    /// mic level), ~one cycle every 4 s. Reads as "still alive, just
    /// waiting on whisper".
    private let transcribingPhaseSpeed: CGFloat = 0.25

    // MARK: - Geometry

    /// How much wider than the notch the glow shape is on each side.
    /// The stroke runs along the perimeter of *this* rectangle, so the
    /// glow contour sits **outside** the physical notch instead of being
    /// pinched against its edges. Without this slack we get little
    /// coloured corners poking out from under the notch's rounded
    /// bottom — exactly the bug the user reported.
    private let glowExtraSides: CGFloat = 12
    /// Extra height below the notch — controls how far the bottom arc
    /// of the glow extends past the notch into the menu-bar area.
    private let glowExtraBottom: CGFloat = 16
    /// Bottom corner radius for the glow contour. Tuned so the rounded
    /// curve flows smoothly around the physical notch's own rounded
    /// internal corners (which are ~8 pt) plus our `glowExtraBottom`
    /// slack, giving an `8 + 16 ≈ 24` pt visual radius. We round it to
    /// 22 — looks more deliberate than the exact algebraic value.
    private let glowBottomCornerRadius: CGFloat = 22

    /// How far the **blur halo** is allowed to spill past the glow
    /// shape's rectangle. Both the FlowingGradient fill and the mask
    /// stroke live inside this larger frame so the blur can fade out
    /// smoothly on all sides — without it, the blur clips against the
    /// frame edge and we see hard rectangular cut-offs.
    ///
    /// Sized for the worst-case loud-talk peak. At intensity = 1.0:
    ///   - inner-line blur radius = `baseBlur + blurGain = 3 + 46 = 49`
    ///   - outer-halo blur radius = `49 × 1.4 = 68.6 pt`
    /// Gaussian visible falloff is ~σ × 3 (where σ ≈ radius / 2 for
    /// SwiftUI's `.blur`), so ~100 pt of bloom past the stroke at peak.
    /// On corners the bloom from two adjacent edges stacks → empirically
    /// add ~40 pt for safety. We want ≥ 140 pt slack here.
    ///
    /// Must be ≤ `glowPaddingSides`/`glowPaddingBottom` in
    /// WaveformOverlay, or the slack clips against the NSPanel's own
    /// edge instead of helping.
    private let blurSpill: CGFloat = 140

    // MARK: - State

    /// Accumulated gradient phase in [0, 1). Advanced each animation
    /// frame inside the TimelineView body via a phantom-view
    /// `onChange(of: now)`. We integrate `speed(level) × dt` so the
    /// gradient flow stays smooth when `smoothedLevel` changes — a
    /// straight `phase = time × speed(level)` mapping would snap the
    /// phase whenever the level shifts.
    @State private var phase: CGFloat = 0
    @State private var lastPhaseUpdate: TimeInterval = 0

    /// 0 → full recording visuals (pink/white/yellow/cyan, level-driven
    /// intensity, level-driven flow speed).
    /// 1 → full transcribing visuals (blue/white, sine-driven intensity,
    /// fixed moderate flow speed).
    /// Driven by `withAnimation` in `onChange(of: panel.mode)`. Every
    /// rendered property (palette, intensity, phase speed) reads
    /// through this progress, so the swap looks like one continuous
    /// morph instead of three independent jump-cuts.
    @State private var transitionProgress: CGFloat = 0
    /// Duration of the recording ↔ transcribing morph.
    private let modeTransitionDuration: TimeInterval = 0.55

    var body: some View {
        // CRITICAL: TimelineView lives *inside* `if panel.isVisible`,
        // not outside it. Otherwise the timeline keeps ticking 60 fps
        // forever — even after `hide()` orders the NSPanel out — and
        // every tick still runs `currentIntensity()` + `advancePhase()`
        // + `onChange(of: now)` state mutations. Murmur is an always-on
        // menubar app: idle gaps between dictations are hours long, and
        // that background animation work both burns battery and starves
        // the main runloop. v3.20 had the same class of bug (a pulse
        // loop that re-armed via completion handlers) and it ate the
        // Option+Space hotkey. Don't repeat that here.
        //
        // The `.transition(.opacity)` lets `withAnimation(hideAnimation)
        // { isVisible = false }` in WaveformPanel still fade the glow
        // out before SwiftUI removes the TimelineView from the tree.
        Group {
            if panel.isVisible {
                TimelineView(.animation) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let intensity = currentIntensity(
                        date: context.date,
                        modeNow: panel.mode
                    )

                    ZStack {
                        // Phantom view to advance phase on every timeline
                        // tick. We can't mutate @State directly inside
                        // the body closure (SwiftUI would loop), so we
                        // hook into `onChange(of: now)` which fires after
                        // the body returns.
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onChange(of: now) { _, newNow in
                                advancePhase(now: newNow)
                            }

                        glow(intensity: intensity, phase: phase)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .transition(.opacity)
                .onAppear {
                    // Reset phase state every time the panel becomes
                    // visible. `@State` survives view removal/recreation
                    // in some SwiftUI configurations, so we make the
                    // reset explicit — guarantees every dictation starts
                    // from phase 0 and `lastPhaseUpdate=0` triggers the
                    // skip-first-frame branch in `advancePhase()`.
                    phase = 0
                    lastPhaseUpdate = 0
                }
                .onChange(of: panel.mode) { _, newMode in
                    // Single source of truth for "are we mid-morph".
                    // Every read of palette / intensity / flow speed
                    // runs through `transitionProgress`, so they all
                    // blend in lockstep.
                    let target: CGFloat = (newMode == .transcribing) ? 1.0 : 0.0
                    withAnimation(.easeInOut(duration: modeTransitionDuration)) {
                        transitionProgress = target
                    }
                }
            }
        }
    }

    // MARK: - Glow rendering

    /// The glow itself. A double-stroke (a wider soft halo + a tighter
    /// crisper line) gives the light a visible body without making the
    /// blur look fuzzy. The flowing-gradient fill is masked by each
    /// stroke so the colours appear to travel along the contour rather
    /// than inside the notch shape.
    @ViewBuilder
    private func glow(intensity: CGFloat, phase: CGFloat) -> some View {
        let stroke = baseStroke + strokeGain * intensity
        let blur = baseBlur + blurGain * intensity

        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: glowBottomCornerRadius,
            bottomTrailingRadius: glowBottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )

        let palette = currentPalette
        let shapeW = panel.notchWidth + glowExtraSides * 2
        let shapeH = panel.topInset + glowExtraBottom
        let outerW = shapeW + blurSpill * 2
        let outerH = shapeH + blurSpill

        ZStack {
            // Outer halo: thick crisp-stroke mask → heavy blur applied
            // to the result. The gradient fill spans the **outer** frame
            // (shape size + blur spill on all sides), so when the blur
            // is applied afterward it has gradient pixels to draw with
            // outside the stroke contour — no hard rectangle edges.
            FlowingGradient(phase: phase, colors: palette)
                .frame(width: outerW, height: outerH, alignment: .top)
                .mask(
                    shape
                        .stroke(.white, style: StrokeStyle(lineWidth: stroke * 1.6, lineCap: .round))
                        .frame(width: shapeW, height: shapeH, alignment: .top)
                        .frame(width: outerW, height: outerH, alignment: .top)
                )
                .blur(radius: blur * 1.4)
                // Outer halo opacity scales with intensity too — silence
                // gives a translucent shimmer, peaks light up. Without
                // this scaling the halo body stays equally "present" at
                // any volume and the contrast feels muted even though
                // stroke / blur are doing their job.
                .opacity(0.4 + 0.5 * intensity)

            // Inner crisp line — same composition but with a thinner
            // mask stroke and lighter blur. Same outer-frame trick so
            // it also fades to nothing at the edges instead of clipping.
            FlowingGradient(phase: phase, colors: palette)
                .frame(width: outerW, height: outerH, alignment: .top)
                .mask(
                    shape
                        .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .frame(width: shapeW, height: shapeH, alignment: .top)
                        .frame(width: outerW, height: outerH, alignment: .top)
                )
                .blur(radius: blur * 0.55)
        }
        .frame(width: outerW, height: outerH, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Palette

    /// Pink → white → yellow → cyan → pink. Lively recording palette.
    /// Stored as `(r, g, b)` so we can lerp it against the transcribing
    /// palette without going through SwiftUI's opaque `Color` type.
    private let recordingPalette: [PaletteRGB] = [
        PaletteRGB(r: 1.00, g: 0.40, b: 0.75),   // pink
        PaletteRGB(r: 1.00, g: 1.00, b: 1.00),   // white
        PaletteRGB(r: 1.00, g: 0.92, b: 0.45),   // soft yellow
        PaletteRGB(r: 0.45, g: 0.85, b: 1.00),   // cyan
        PaletteRGB(r: 1.00, g: 0.40, b: 0.75),   // pink (seam)
    ]
    /// Blue ↔ white. Focused transcribing palette. Same length as the
    /// recording palette so we can lerp 1:1 between matched stops.
    private let transcribingPalette: [PaletteRGB] = [
        PaletteRGB(r: 0.25, g: 0.55, b: 1.00),   // blue
        PaletteRGB(r: 1.00, g: 1.00, b: 1.00),   // white
        PaletteRGB(r: 0.25, g: 0.55, b: 1.00),   // blue
        PaletteRGB(r: 1.00, g: 1.00, b: 1.00),   // white
        PaletteRGB(r: 0.25, g: 0.55, b: 1.00),   // blue (seam)
    ]

    /// Colour stops for the current mode, **interpolated** between
    /// recording and transcribing palettes by `transitionProgress`. So
    /// during the half-second morph the pink-cyan band gradually becomes
    /// the blue-white band instead of cutting hard.
    private var currentPalette: [Color] {
        zip(recordingPalette, transcribingPalette).map { rec, trans in
            rec.lerp(to: trans, t: transitionProgress).asColor
        }
    }

    // MARK: - Intensity (level-driven for recording, sine for transcribing)

    /// Blend recording's level-driven intensity with transcribing's
    /// sine-breathing intensity by `transitionProgress`. During the
    /// half-second morph both contribute; before/after only one matters.
    /// We always compute *both* (cheap) and lerp — that way an audio
    /// level sample arriving while we're mid-transition still nudges the
    /// glow naturally, and the sine doesn't pop in suddenly when the
    /// mode flips.
    private func currentIntensity(date: Date, modeNow: WaveformPanel.WaveformMode) -> CGFloat {
        let level = panel.smoothedLevel
        let boosted = pow(max(0, level), levelCurve)
        let recordingI = min(maxIntensity, baseIntensity + boosted * (1.0 - baseIntensity))

        // 1.2 s sine, swings baseline → baseline + 0.55.
        let t = date.timeIntervalSinceReferenceDate
        let p = (sin(t * 2 * .pi / 1.2) + 1) / 2
        let swing: CGFloat = 0.55
        let transcribingI = baseIntensity + CGFloat(p) * swing

        return recordingI * (1 - transitionProgress) + transcribingI * transitionProgress
    }

    // MARK: - Phase advance

    /// Integrate flow speed × dt into `phase`. Speed depends on mode and
    /// (during recording) on smoothedLevel — quiet speech = slow drift,
    /// loud speech = fast flow. dt is clamped to [0, 0.1 s] so a hiccup
    /// in the timeline can't dump a huge phase jump.
    private func advancePhase(now: TimeInterval) {
        let dt: CGFloat
        if lastPhaseUpdate > 0 {
            dt = CGFloat(max(0, min(0.1, now - lastPhaseUpdate)))
        } else {
            dt = 0
        }
        lastPhaseUpdate = now

        // Lerp the two speeds via transitionProgress so the flow doesn't
        // step-change at mode swap — it eases from whatever the mic was
        // driving toward the steady transcribing rate (or back).
        // `pow(level, 0.5)` lifts quiet-to-medium volume into a clearly
        // faster flow; otherwise the boost feels linear and uniform.
        let speedLevel = pow(max(0, panel.smoothedLevel), speedLevelCurve)
        let recordingSpeed = basePhaseSpeed + speedLevel * levelSpeedBoost
        let speed = recordingSpeed * (1 - transitionProgress)
                  + transcribingPhaseSpeed * transitionProgress

        phase = (phase + dt * speed).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - PaletteRGB

/// One RGB triple in [0, 1]. Plain values (not `Color`) so we can lerp
/// arithmetically — `Color` is an opaque token in SwiftUI and gives no
/// way to read its components back out for interpolation.
private struct PaletteRGB {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    var asColor: Color { Color(red: r, green: g, blue: b) }

    func lerp(to other: PaletteRGB, t: CGFloat) -> PaletteRGB {
        // `t` can transiently exceed [0, 1] mid-spring; clamp so we
        // never produce out-of-range components.
        let tc = max(0, min(1, t))
        return PaletteRGB(
            r: r + (other.r - r) * tc,
            g: g + (other.g - g) * tc,
            b: b + (other.b - b) * tc
        )
    }
}

// MARK: - FlowingGradient

/// Horizontal gradient that slides **left → right** as `phase` advances
/// from 0 to 1. Implemented as three side-by-side copies of the same
/// linear gradient inside a 3×-wide HStack, with the HStack offset by
/// `phase × width` — so when the phase wraps, the next cycle's leading
/// edge is already in position (no flicker at the seam). Direction:
/// content moves to the right, the eye reads it as colours travelling
/// rightward.
private struct FlowingGradient: View {
    let phase: CGFloat
    let colors: [Color]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                ForEach(0..<3) { _ in
                    LinearGradient(
                        gradient: Gradient(colors: colors),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w)
                }
            }
            .frame(width: w * 3, alignment: .leading)
            // Slide the HStack so phase=0 reveals the middle cycle and
            // phase=1 reveals the leftmost cycle. The eye sees content
            // travelling rightward → new colours emerge from the left.
            .offset(x: -w + phase * w)
            // No `.clipped()` — we *want* the HStack overflow to spill
            // into the surrounding padding so the parent mask + blur can
            // pull gradient pixels from there for a soft halo at the
            // edges instead of a hard cut-off.
        }
    }
}
