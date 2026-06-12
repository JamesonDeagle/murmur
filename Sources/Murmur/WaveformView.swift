import SwiftUI

// MARK: - GlowShaderSupport

/// Locates the compiled Metal shader library at runtime and exposes a
/// `ShaderLibrary` for the domain-warped glow field. Returns `nil` when no
/// compiled `.metallib` is present (e.g. a plain `swift build` binary run
/// from `.build/release` where the Metal toolchain never compiled the
/// `.metal` source) — the caller then falls back to the `FlowingGradient`
/// renderer, so debug builds and any toolchain hiccup degrade to the known
/// v3.21 visual instead of a blank rectangle.
///
/// Search order matters. The production build path (`build-app.sh` /
/// `build-mas.sh`, both on plain `swift build`) explicitly compiles the
/// shader into `Murmur.app/Contents/Resources/default.metallib` via
/// `xcrun metal` — that is the PRIMARY artifact, found through
/// `Bundle.main`. The SPM resource bundle (`Murmur_Murmur.bundle`,
/// produced only when building through `xcodebuild`) is the secondary
/// fallback. We probe `Bundle.main` first for that reason.
enum GlowShaderSupport {
    /// Name of the stitchable function in `GlowField.metal`. Referenced in
    /// exactly one place so a rename can't drift.
    static let functionName = "glowField"

    /// The library that actually contains a compiled metallib, or nil.
    static let library: ShaderLibrary? = {
        // 1. PRIMARY: default.metallib next to the executable in the app's
        //    main bundle Resources. This is what both build scripts produce.
        if mainBundleHasMetallib {
            return ShaderLibrary.default
        }
        // 2. SECONDARY: SPM resource bundle (xcodebuild path only).
        if let bundle = spmBundle {
            return ShaderLibrary.bundle(bundle)
        }
        return nil
    }()

    static var isAvailable: Bool { library != nil }

    /// True when `Bundle.main` carries any compiled `*.metallib`. We check
    /// for existence rather than trusting `ShaderLibrary.default`
    /// unconditionally: a plain `swift build` binary has no metallib, and
    /// using a missing library would render the `colorEffect` as a no-op
    /// (white rectangle) inside the mask.
    private static var mainBundleHasMetallib: Bool {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: "metallib",
            subdirectory: nil
        ) else { return false }
        return !urls.isEmpty
    }

    /// The SPM-generated resource bundle, only if it exists AND contains a
    /// compiled metallib (plain `swift build` may copy the raw `.metal`
    /// into the bundle without compiling it — then there is no shader).
    private static var spmBundle: Bundle? {
        let name = "Murmur_Murmur.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name),
        ]
        for url in candidates {
            guard let url, let bundle = Bundle(url: url) else { continue }
            let metallibs = bundle.urls(
                forResourcesWithExtension: "metallib",
                subdirectory: nil
            )
            if metallibs?.isEmpty == false {
                return bundle
            }
        }
        return nil
    }
}

/// Ambient-light glow that wraps the perimeter of the MacBook notch.
///
/// The host NSPanel (see WaveformOverlay) is sized as
/// `notchWidth + 2 × glowPaddingSides × topInset + glowPaddingBottom`
/// (currently `notchWidth + 320 × topInset + 170`). The notch occupies
/// the top-centre, so the glow's blurred stroke is only visible **around
/// the notch's lower contour** — two side rails plus a wide arc below.
/// On screens without a physical notch (`panel.hasNotch == false`) a
/// solid-black Dynamic-Island body is drawn on top of the strokes'
/// inner halves, so the same glow wraps a visible black "notch" that
/// slides out of the screen edge for the duration of the dictation.
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

    /// When Reduce Motion is on we stop integrating `fieldTime` so the
    /// shader field is static (it still reacts to the voice via brightness
    /// and the existing stroke/blur intensity, just without the constant
    /// morph). The fallback FlowingGradient likewise stops flowing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Intensity (stroke width + blur)

    /// Idle baseline so the glow is faintly visible at silence — just
    /// enough that you know the recorder is on, not enough to compete
    /// with anything on screen. Lowered from 0.15 so silence reads as
    /// "thin shimmer" and talking reads as "this thing is alive".
    private let baseIntensity: CGFloat = 0.06
    private let maxIntensity: CGFloat = 1.0

    /// Stroke width and blur radius scale linearly from idle → peak.
    /// Baseline values give a clearly-visible glow even at silence
    /// (so the user always knows the recorder is on), gain values are
    /// large so loud speech blooms out dramatically. Bumped from the
    /// previous tiny baseline because once the contour was pulled
    /// flush with the notch (glowExtraSides=0), half of the stroke
    /// disappears under the bezel — so the visible outside half needs
    /// to be wider to keep its visual presence.
    private let baseStroke: CGFloat = 4
    private let strokeGain: CGFloat = 42
    // Blur radii trimmed in v3.23: the shader field is soft by construction
    // (fBM), so it doesn't need the huge Gaussian the hard-edged gradient
    // did — and SwiftUI re-blurs every frame now that the fill itself
    // animates per-pixel. Halving the radius is the single biggest FPS win.
    private let baseBlur: CGFloat = 5
    private let blurGain: CGFloat = 28

    /// Power-curve boost on the smoothed level. Audio RMS lives mostly
    /// in the lower half of [0, 1]; `pow(level, 0.55)` lifts that into
    /// the visibly-reactive band while still letting peaks max out.
    private let levelCurve: CGFloat = 0.55

    // MARK: - Flow speed (gradient phase)

    /// Baseline cycle frequency at silence — one full colour cycle every
    /// ~10 seconds. Slow enough to feel ambient when nobody's talking,
    /// fast enough that you can still see the flow moving at all.
    // Raised in v3.23 after user feedback: at 0.10-0.14 the idle ribbon
    // looked frozen ("can't even tell there's an effect"). 0.26 reads as a
    // clearly alive slow shimmer while still leaving a big jump to speech.
    private let basePhaseSpeed: CGFloat = 0.26
    /// Additional cycles-per-second at level=1.0. Pushed high so a
    /// loud speaker can rip the cycle rate up to ~3.6 cps = one full
    /// pink→cyan→pink cycle every 0.28 s — visibly racing, not just
    /// "a bit faster than baseline". Combined with `basePhaseSpeed`
    /// this gives a 36× silence-to-peak speed ratio.
    private let levelSpeedBoost: CGFloat = 5.0
    /// Power curve applied to level before it multiplies `levelSpeedBoost`.
    /// 0.6 spreads the response across the whole talking range:
    ///   - level 0.10 →  25 % of boost → ~0.98 cps  (1.0 s / cycle)
    ///   - level 0.30 →  48 % of boost → ~1.78 cps  (0.56 s / cycle)
    ///   - level 0.50 →  66 % of boost → ~2.41 cps  (0.41 s / cycle)
    ///   - level 0.80 →  88 % of boost → ~3.18 cps  (0.31 s / cycle)
    ///   - level 1.00 → 100 % of boost → ~3.60 cps  (0.28 s / cycle)
    /// So quiet vs medium vs loud each give distinctly different flow
    /// rates — and the maximum is dramatically faster than silence.
    private let speedLevelCurve: CGFloat = 0.6
    /// Constant moderate flow rate used during transcribing (no live
    /// mic level), ~one cycle every 4 s. Reads as "still alive, just
    /// waiting on whisper".
    private let transcribingPhaseSpeed: CGFloat = 0.25

    // MARK: - Shader field dynamics (v3.23, only used when shader available)

    /// Domain-warp amplitude for the fBM colour field. Controls how
    /// chaotic the spots are: low → lazy, large, slow-morphing blobs;
    /// high → the field "boils", spots fracture and swirl. Recording maps
    /// it from the mic level (silence = calm, speech = roiling), so the
    /// voice drives a *third* reactive channel on top of flow-speed and
    /// stroke/blur intensity. Transcribing pins it to a steady moderate
    /// churn.
    private let baseWarpAmp: CGFloat = 1.0
    private let warpAmpGain: CGFloat = 3.4
    /// Power curve on the level before it scales `warpAmpGain` — same
    /// shape philosophy as `levelCurve`, lifts quiet-to-medium volume into
    /// a visibly more agitated field.
    private let warpAmpCurve: CGFloat = 0.55
    /// Constant warp amplitude during transcribing.
    private let transcribingWarpAmp: CGFloat = 1.3

    /// Overall brightness gain handed to the shader. A soft *extra*
    /// luminance channel layered on top of the existing stroke / blur /
    /// opacity intensity — keeps silence readable without washing peaks to
    /// pure white.
    private let baseBrightness: CGFloat = 0.80
    private let brightnessGain: CGFloat = 0.55

    // MARK: - Geometry

    /// Glow contour sits **flush** with the physical notch — no side or
    /// bottom slack. `stroke()` draws centred on the path, so half the
    /// stroke width lives inside the notch's rectangle (invisible —
    /// hidden by the physical bezel) and half lives outside (visible
    /// as the ambient ring). Without this, the glow looks "detached"
    /// from the notch with an obvious gap, especially at thin baseline
    /// (silence) widths.
    private let glowExtraSides: CGFloat = 0
    private let glowExtraBottom: CGFloat = 0
    /// Bottom corner radius — matches the physical inner radius of the
    /// MacBook notch (~8 pt on M-series) so the curve follows the
    /// hardware edge instead of cutting across it.
    private let glowBottomCornerRadius: CGFloat = 8
    /// Bottom corner radius of the Dynamic-Island body drawn on screens
    /// without a physical notch. Larger than the real notch's 8 pt —
    /// prior-art islands (~30 pt tall) read best at 10-14 pt — but well
    /// below height/2, so the shape stays notch-like, not pill-like.
    private let islandBottomCornerRadius: CGFloat = 12
    /// Outward "flare" of the island's top corners — the small CONCAVE
    /// fillet the real MacBook notch has where its vertical sides meet
    /// the screen edge. Without it the island joins the monitor edge at
    /// a sharp 90° and reads as a pasted-on rectangle.
    private let islandTopFlareRadius: CGFloat = 4

    /// Soft dark scrim under the colour glow. A wide blurred black
    /// stroke along the notch contour darkens whatever is behind it
    /// (browser tab bar, white page, etc.) so the gradient reads with
    /// the same contrast on any backdrop. Without this, on white
    /// pages the glow nearly disappears.
    ///
    /// Stroke is fat (24 pt) so the scrim body has presence even after
    /// blur. Blur is moderate (35 pt) so the darkening stays
    /// concentrated near the notch instead of fading into invisibility
    /// across 200 pt of falloff. Baseline opacity is high enough to be
    /// clearly visible on white (≈48% black → mid-grey rim).
    // Scrim toned way down in v3.23: under the dense v3.21 gradient it was
    // invisible, but the additive neon field is semi-transparent between
    // blobs and the black shadow showed through as "dirty dark" patches.
    // Keep just enough to lift the glow off bright backdrops.
    private let scrimStroke: CGFloat = 26
    private let scrimBlur: CGFloat = 40
    private let scrimBaseOpacity: CGFloat = 0.20
    private let scrimIntensityGain: CGFloat = 0.10

    /// How far the **blur halo** is allowed to spill past the glow
    /// shape's rectangle. Both the FlowingGradient fill and the mask
    /// stroke live inside this larger frame so the blur can fade out
    /// smoothly on all sides — without it, the blur clips against the
    /// frame edge and we see hard rectangular cut-offs.
    ///
    /// Sized for the worst-case loud-talk peak. At intensity = 1.0:
    ///   - inner-line blur radius = `baseBlur + blurGain = 7 + 52 = 59`
    ///   - outer-halo blur radius = `59 × 1.7 = 100.3 pt`
    /// Gaussian visible falloff is ~σ × 3 (where σ ≈ radius / 2 for
    /// SwiftUI's `.blur`), so ~150 pt of bloom past the stroke at peak.
    /// On corners the bloom from two adjacent edges stacks → add ~30 pt
    /// for safety. We want ≥ 180 pt slack here.
    ///
    /// Must be ≤ `glowPaddingSides`/`glowPaddingBottom` in
    /// WaveformOverlay, or the slack clips against the NSPanel's own
    /// edge instead of helping.
    private let blurSpill: CGFloat = 180

    // MARK: - State

    /// Accumulated field "time" (in cycles). Advanced each animation frame
    /// inside the TimelineView body via a phantom-view `onChange(of: now)`.
    /// We integrate `speed(level) × dt` so the flow stays smooth when
    /// `smoothedLevel` changes — a straight `time × speed(level)` mapping
    /// would snap whenever the level shifts.
    ///
    /// IMPORTANT (v3.23): this is NOT wrapped to [0, 1). The shader feeds
    /// it straight into noise coordinates, where wrapping would cause a
    /// visible snap as the field teleports. The `FlowingGradient` fallback
    /// takes its own `truncatingRemainder` of this value for its seamless
    /// offset wrap, so a non-wrapped accumulator serves both renderers. A
    /// safety wrap at 2048 (only reached after ~10 min of continuous
    /// shouting) guards against float precision loss; `onAppear` also
    /// resets it to 0 at the start of every dictation.
    @State private var fieldTime: CGFloat = 0
    @State private var lastPhaseUpdate: TimeInterval = 0
    /// Slow-followed mic level for the blob-SIZE channel (see advancePhase).
    /// Keeps growth/shrink smooth while flow speed stays per-syllable snappy.
    @State private var slowLevel: CGFloat = 0
    /// Safety ceiling for `fieldTime` — see above. fBM noise is periodic
    /// enough that a wrap here is imperceptible, but it should be
    /// effectively unreachable in normal use.
    private let fieldTimeWrap: CGFloat = 2048

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

                        glow(intensity: intensity, fieldTime: fieldTime)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                // Island mode additionally scales from the top edge, so
                // the black body looks like it slides out of the screen
                // edge instead of materialising mid-air. On a real notch
                // a pure fade is right — the "body" is hardware and
                // scaling the glow alone would look detached.
                .transition(
                    panel.hasNotch
                        ? AnyTransition.opacity
                        : AnyTransition.opacity.combined(
                            with: .scale(scale: 0.4, anchor: .top)
                        )
                )
                .onAppear {
                    // Reset all @State that drives the visuals to match
                    // the current panel.mode at the start of each new
                    // dictation. SwiftUI keeps @State alive across view
                    // removal/recreation in some configurations, so the
                    // previous session's leftovers can bleed in:
                    //   - phase / lastPhaseUpdate → wrong gradient start
                    //   - transitionProgress → wrong palette colour!
                    //     If the previous session ended mid-transcribing
                    //     (progress=1.0), the next recording would show
                    //     the BLUE transcribing palette instead of the
                    //     pink/yellow/cyan recording one, because
                    //     `.onChange(of: panel.mode)` only fires on
                    //     actual changes — and after `hide()` resets
                    //     mode back to .recording, the next show() sees
                    //     no change to fire on.
                    fieldTime = 0
                    lastPhaseUpdate = 0
                    slowLevel = 0
                    transitionProgress = (panel.mode == .transcribing) ? 1.0 : 0.0
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
    private func glow(intensity: CGFloat, fieldTime: CGFloat) -> some View {
        let stroke = baseStroke + strokeGain * intensity
        let blur = baseBlur + blurGain * intensity

        // Real notch keeps the plain open-top contour (the hardware hides
        // the top anyway). The island uses a custom shape with concave
        // top-corner flares so it merges into the screen edge like the
        // real notch does, instead of meeting it at a sharp 90°.
        let shape: AnyShape = panel.hasNotch
            ? AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: glowBottomCornerRadius,
                bottomTrailingRadius: glowBottomCornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            ))
            : AnyShape(IslandShape(
                topFlare: islandTopFlareRadius,
                bottomRadius: islandBottomCornerRadius
            ))

        let shapeW = panel.notchWidth + glowExtraSides * 2
        let shapeH = panel.topInset + glowExtraBottom
        let outerW = shapeW + blurSpill * 2
        let outerH = shapeH + blurSpill
        let scrimOpacity = scrimBaseOpacity + scrimIntensityGain * intensity

        // The colour source for both glow layers. When the Metal shader is
        // available we use the domain-warped fBM field; otherwise we fall
        // back to the v3.21 FlowingGradient. Both fill the same outer frame
        // and read the same `fieldTime`, so the masks / blurs below are
        // identical for either renderer — only the fill differs.
        let useShader = GlowShaderSupport.isAvailable
        let warp = currentWarpAmp()
        let brightness = baseBrightness + brightnessGain * intensity
        let palette4 = currentPalette4
        let paletteFallback = currentPalette

        ZStack {
            // Scrim — soft dark halo drawn FIRST so it sits underneath
            // the colour glow. Same shape, same outer-frame trick, but
            // filled with black (not gradient) and blurred wider. Reads
            // as the notch casting a subtle shadow onto the desktop /
            // page behind, lifting the colour glow off any backdrop.
            shape
                .stroke(.black, style: StrokeStyle(lineWidth: scrimStroke, lineCap: .round))
                .frame(width: shapeW, height: shapeH, alignment: .top)
                .frame(width: outerW, height: outerH, alignment: .top)
                .blur(radius: scrimBlur)
                .opacity(scrimOpacity)

            // Outer halo: thick crisp-stroke mask → heavy blur applied
            // to the result. The colour fill spans the **outer** frame
            // (shape size + blur spill on all sides), so when the blur
            // is applied afterward it has fill pixels to draw with
            // outside the stroke contour — no hard rectangle edges.
            colourFill(
                useShader: useShader,
                outerW: outerW, outerH: outerH,
                fieldTime: fieldTime, warp: warp, brightness: brightness,
                palette4: palette4, paletteFallback: paletteFallback
            )
            .frame(width: outerW, height: outerH, alignment: .top)
            .mask(
                shape
                    .stroke(.white, style: StrokeStyle(lineWidth: stroke * 1.9, lineCap: .round))
                    .frame(width: shapeW, height: shapeH, alignment: .top)
                    .frame(width: outerW, height: outerH, alignment: .top)
            )
            .blur(radius: blur * 0.95)
            // Outer halo opacity scales with intensity too — silence
            // gives a translucent shimmer, peaks light up. Without
            // this scaling the halo body stays equally "present" at
            // any volume and the contrast feels muted even though
            // stroke / blur are doing their job.
            .opacity(0.55 + 0.4 * intensity)

            // Inner crisp line — same composition but with a thinner
            // mask stroke and lighter blur. Same outer-frame trick so
            // it also fades to nothing at the edges instead of clipping.
            colourFill(
                useShader: useShader,
                outerW: outerW, outerH: outerH,
                fieldTime: fieldTime, warp: warp, brightness: brightness,
                palette4: palette4, paletteFallback: paletteFallback
            )
            .frame(width: outerW, height: outerH, alignment: .top)
            .mask(
                shape
                    .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .frame(width: shapeW, height: shapeH, alignment: .top)
                    .frame(width: outerW, height: outerH, alignment: .top)
            )
            .blur(radius: blur * 0.26)

            // Dynamic-Island body — screens without a physical notch only.
            // Drawn LAST so it covers the inner half of both glow strokes:
            // `stroke()` centres on the path, and on a real notch that
            // inner half is hidden by the hardware bezel. Painting black
            // on top reproduces the same occlusion, so the island reads as
            // a solid black notch with light around it, not a rectangle
            // with glowing inner rims. Deliberately NO shadow here: a soft
            // dark edge over the additive glow re-creates the "dirty halo"
            // class of bug the scrim tuning fought — the scrim plus the
            // glow itself already separate the island from any backdrop.
            if !panel.hasNotch {
                shape
                    .fill(.black)
                    .frame(width: shapeW, height: shapeH, alignment: .top)
                    .frame(width: outerW, height: outerH, alignment: .top)
            }
        }
        // Rasterize the whole glow subtree (two shader fills, two stroke
        // masks, three Gaussian blurs) into one offscreen Metal texture per
        // frame instead of compositing it through SwiftUI layer-by-layer.
        // With the per-pixel animated shader this is the difference between
        // choppy and fluid.
        .drawingGroup()
        .frame(width: outerW, height: outerH, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One colour-source layer for the glow: the Metal field when
    /// available, else the FlowingGradient. Extracted so the two glow
    /// strokes (halo + crisp) stay byte-identical.
    @ViewBuilder
    private func colourFill(
        useShader: Bool,
        outerW: CGFloat, outerH: CGFloat,
        fieldTime: CGFloat, warp: CGFloat, brightness: CGFloat,
        palette4: [Color], paletteFallback: [Color]
    ) -> some View {
        if useShader {
            GlowFieldFill(
                size: CGSize(width: outerW, height: outerH),
                time: fieldTime,
                warpAmp: warp,
                brightness: brightness,
                colors: palette4
            )
        } else {
            FlowingGradient(
                phase: fieldTime.truncatingRemainder(dividingBy: 1),
                colors: paletteFallback
            )
        }
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

    /// Four palette stops for the shader, interpolated by
    /// `transitionProgress` exactly like `currentPalette` (same RGB-struct
    /// lerp with clamp against spring-overshoot). The shader mixes colours
    /// by noise-field *values*, not by a coordinate, so there is no seam to
    /// close — the 5th seam stop the gradient needs is dropped here.
    /// Recording: pink / white / yellow / cyan. Transcribing: blue / white
    /// / blue / white.
    /// Dedicated 4-stop palettes for the shader field. NOT sliced from the
    /// gradient palettes: SwiftUI's .color() hands colours to the shader in
    /// LINEAR space, where white stops flood the field into a washed-out
    /// haze (the field mixes stops by noise values, so a white stop bleeds
    /// everywhere — unlike the gradient, where it occupied one band). All
    /// four stops are saturated; white appears only via the peak-bloom term
    /// inside the shader.
    /// User-requested mix: pink, sky blue, yellow, orange — three warm
    /// stops + one cool accent. The violet stop was dropped: pink and cyan
    /// already sum to violet-ish in the additive blend, and a dedicated
    /// violet stop tipped the whole field purple.
    private let recordingShaderPalette: [PaletteRGB] = [
        PaletteRGB(r: 1.00, g: 0.28, b: 0.62),   // hot pink
        PaletteRGB(r: 0.20, g: 0.80, b: 1.00),   // sky cyan
        PaletteRGB(r: 1.00, g: 0.80, b: 0.22),   // golden yellow
        PaletteRGB(r: 1.00, g: 0.45, b: 0.10),   // orange
    ]
    private let transcribingShaderPalette: [PaletteRGB] = [
        PaletteRGB(r: 0.20, g: 0.50, b: 1.00),   // blue
        PaletteRGB(r: 0.62, g: 0.85, b: 1.00),   // ice
        PaletteRGB(r: 0.12, g: 0.30, b: 0.95),   // deep blue
        PaletteRGB(r: 0.80, g: 0.92, b: 1.00),   // pale ice
    ]

    private var currentPalette4: [Color] {
        zip(recordingShaderPalette, transcribingShaderPalette).map { r, t in
            r.lerp(to: t, t: transitionProgress).asColor
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

    /// Domain-warp amplitude for the shader field, blended between the
    /// level-driven recording value and the steady transcribing value by
    /// `transitionProgress`. Same compute-both-and-lerp pattern as
    /// `currentIntensity`, so a level sample arriving mid-morph still
    /// nudges the field naturally and the transcribing churn doesn't pop in.
    private func currentWarpAmp() -> CGFloat {
        // slowLevel, not smoothedLevel: the size channel must ease, not jump
        // on the first syllable (see advancePhase).
        let boosted = pow(max(0, slowLevel), warpAmpCurve)
        let recordingW = baseWarpAmp + boosted * warpAmpGain
        return recordingW * (1 - transitionProgress)
             + transcribingWarpAmp * transitionProgress
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

        // Slow-follow level for the SIZE channel (warpAmp / blob growth).
        // `smoothedLevel` itself is deliberately snappy (per-syllable flow
        // speed), but feeding it straight into the mask thresholds made
        // blobs JUMP in size on the first syllable. Critically-damped
        // follower: fast-ish attack (~0.28 s), slower release (~0.55 s) —
        // blobs bloom smoothly and deflate even smoother.
        if dt > 0 {
            let target = panel.smoothedLevel
            let tau: CGFloat = target > slowLevel ? 0.28 : 0.55
            slowLevel += (target - slowLevel) * min(1, dt / tau)
        }

        // Reduce Motion: freeze the field. We still update lastPhaseUpdate
        // above so dt stays sane if it's toggled mid-session, but we don't
        // integrate — the shader renders a static field and the gradient
        // fallback stops sliding. The voice still drives brightness and the
        // stroke/blur intensity, so the glow remains responsive, just not
        // continuously morphing.
        guard !reduceMotion else { return }

        // Lerp the two speeds via transitionProgress so the flow doesn't
        // step-change at mode swap — it eases from whatever the mic was
        // driving toward the steady transcribing rate (or back).
        // `pow(level, 0.6)` lifts quiet-to-medium volume into a clearly
        // faster flow; otherwise the boost feels linear and uniform.
        let speedLevel = pow(max(0, panel.smoothedLevel), speedLevelCurve)
        let recordingSpeed = basePhaseSpeed + speedLevel * levelSpeedBoost
        let speed = recordingSpeed * (1 - transitionProgress)
                  + transcribingPhaseSpeed * transitionProgress

        // No wrap to [0, 1): `fieldTime` feeds straight into the shader's
        // noise coordinates and a wrap would snap the field. The gradient
        // fallback takes its own fractional part. A 2048-cycle safety wrap
        // (≈10 min of continuous shouting) keeps float precision sane while
        // being imperceptible — fBM is periodic enough that the jump is
        // invisible, and `onAppear` resets to 0 every dictation anyway.
        fieldTime = (fieldTime + dt * speed).truncatingRemainder(
            dividingBy: fieldTimeWrap
        )
    }
}

// MARK: - IslandShape

/// Dynamic-Island contour for screens without a physical notch: flat top
/// flush with the screen edge, convex rounded bottom corners, and small
/// **concave** flares where the vertical sides meet the top edge — the
/// same fillet the real MacBook notch has, so the island flows out of
/// the monitor edge instead of sitting on it as a sharp-cornered box.
///
/// `rect` is the island BODY; the flares extend `topFlare` pt *outside*
/// rect on each side (SwiftUI shapes don't clip their path to bounds, and
/// the callers place this inside a much larger blur-spill frame anyway).
/// Quad curves with the sharp corner as control point are used instead of
/// `addArc` — same visual result, none of the flipped-coordinate angle
/// pitfalls.
private struct IslandShape: Shape {
    var topFlare: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start on the screen edge, left of the body, at the flare's
        // outer end; close along the top edge at the end.
        p.move(to: CGPoint(x: rect.minX - topFlare, y: rect.minY))
        // Top-left flare: concave quarter-curve into the left side.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topFlare),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        // Bottom-left corner (convex).
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY))
        // Bottom-right corner (convex).
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topFlare))
        // Top-right flare: concave quarter-curve out to the screen edge.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX + topFlare, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.closeSubpath()
        return p
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

// MARK: - GlowFieldFill (Metal shader)

/// Fills its frame with the domain-warped fBM colour field from
/// `GlowField.metal` via `.colorEffect`. The white `Rectangle` is only a
/// source of `alpha = 1` — the shader writes the colour and multiplies by
/// that alpha so the whole rect is opaque field, ready to be masked by the
/// notch-contour stroke in `glow(...)`.
///
/// Uniform order matches the shader's parameter list exactly (after the
/// implicit `position` + `color`): `size, time, warpAmp, brightness, cA,
/// cB, cC, cD`. The four colours are the already-lerped 4-stop palette.
private struct GlowFieldFill: View {
    let size: CGSize
    let time: CGFloat
    let warpAmp: CGFloat
    let brightness: CGFloat
    /// Exactly four colour stops (see `currentPalette4`). Guarded below so a
    /// short array can never crash the shader call.
    let colors: [Color]

    var body: some View {
        // Pad to 4 stops defensively — `currentPalette4` always supplies
        // four, but a shader argument mismatch would be a hard crash, so we
        // never index past the end.
        let c0 = colors.indices.contains(0) ? colors[0] : .white
        let c1 = colors.indices.contains(1) ? colors[1] : .white
        let c2 = colors.indices.contains(2) ? colors[2] : .white
        let c3 = colors.indices.contains(3) ? colors[3] : .white

        Rectangle()
            .fill(.white)
            .modifier(
                GlowFieldEffect(
                    size: size,
                    time: time,
                    warpAmp: warpAmp,
                    brightness: brightness,
                    c0: c0, c1: c1, c2: c2, c3: c3
                )
            )
    }
}

/// Applies the `glowField` shader as a `colorEffect`, or no effect at all
/// if the library is somehow unavailable (the caller already gates on
/// `GlowShaderSupport.isAvailable`, so this is a belt-and-suspenders no-op
/// rather than a fallback path — the FlowingGradient handles real
/// unavailability one level up).
private struct GlowFieldEffect: ViewModifier {
    let size: CGSize
    let time: CGFloat
    let warpAmp: CGFloat
    let brightness: CGFloat
    let c0, c1, c2, c3: Color

    func body(content: Content) -> some View {
        if let library = GlowShaderSupport.library {
            let shader = library[dynamicMember: GlowShaderSupport.functionName](
                .float2(Float(size.width), Float(size.height)),
                .float(Float(time)),
                .float(Float(warpAmp)),
                .float(Float(brightness)),
                .color(c0), .color(c1), .color(c2), .color(c3)
            )
            content.colorEffect(shader)
        } else {
            content
        }
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
