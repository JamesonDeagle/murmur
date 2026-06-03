import SwiftUI

/// Notch-style overlay. Solid-black pill that sits immediately below the
/// MacBook notch (or below the menu bar on Macs without one). When shown
/// the pill **expands vertically downward** — width is constant, only the
/// height grows from zero to full. To the eye it reads as something
/// emerging from under the notch.
///
/// Animation curve is `easeOut` per Apple's recommendation for elements
/// that appear in response to user action — fast start, gentle settle.
struct WaveformView: View {
    @EnvironmentObject var panel: WaveformPanel

    private let barCount = 11
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 3.5
    private let baseHeights: [CGFloat] = [8, 14, 20, 26, 30, 36, 30, 26, 20, 14, 8]

    /// Bottom-only corner radius. The top edge of the panel is flush with
    /// the very top of the screen and continues the physical notch line,
    /// so it MUST be a straight 90° corner there — anything rounded would
    /// reveal a seam against the screen edge. Only the bottom two corners
    /// curve away from the notch, like a teardrop being pulled downward.
    private let cornerRadius: CGFloat = 22

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
        // isVisible animation is driven explicitly by WaveformPanel.show()/
        // hide() via withAnimation — two different curves (easeOutBack on
        // open, easeOut on close), so we don't set it here. Only the
        // recording↔transcribing content swap stays declarative.
        .animation(.easeOut(duration: 0.22), value: panel.mode == .transcribing)
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
        .overlay(content)
        // No drop-shadow: SwiftUI renders `.shadow` against the view's
        // rectangular bounding box rather than the shape's path, which
        // leaked sharp corners at the bottom of the pill against the
        // transparent NSPanel background. The pill reads clearly enough
        // against any backdrop without one.
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch panel.mode {
            case .recording:
                recordingWaveform
            case .transcribing:
                transcribingOrb
                    .transition(.scale(scale: 0.65).combined(with: .opacity))
            }
        }
        // Top `panel.topInset` pt sits behind the notch / menu bar.
        // Content is centered in the remaining area — the pill height
        // is tuned (see panelHeight in WaveformOverlay) so the orbital
        // loader's height equals that remaining area, making it touch
        // the notch's bottom edge as the user wants.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, panel.topInset)
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingWaveform: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let level = CGFloat(i < panel.levels.count ? max(0.15, panel.levels[i]) : 0.15)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: barWidth, height: baseHeights[i] * level)
                    .animation(.easeOut(duration: 0.08), value: panel.levels)
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Transcribing

    @ViewBuilder
    private var transcribingOrb: some View {
        OrbitalLoader()
            .frame(width: 52, height: 52)
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

// MARK: - Orbital Loader

/// Spinning orbital indicator used while we wait for the transcription
/// engine. White-on-black to match the notch panel's color scheme.
struct OrbitalLoader: View {
    @State private var outerAngle: Double = 0
    @State private var innerAngle: Double = 0
    @State private var corePulse: CGFloat = 1.0

    private let outerCount = 8
    private let innerCount = 5
    private let outerR: CGFloat = 18
    private let innerR: CGFloat = 10

    var body: some View {
        ZStack {
            // Outer ring — gradient dots with trail fade
            ForEach(0..<outerCount, id: \.self) { i in
                let size = 4.0 - CGFloat(i) * 0.3
                let fade = 1.0 - Double(i) / Double(outerCount) * 0.7

                Circle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
                    .shadow(color: .white.opacity(0.3), radius: 3)
                    .offset(x: outerR)
                    .rotationEffect(.degrees(Double(i) / Double(outerCount) * 360 + outerAngle))
                    .opacity(fade)
            }

            // Inner ring — counter-rotating, subtle
            ForEach(0..<innerCount, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 2.5, height: 2.5)
                    .offset(x: innerR)
                    .rotationEffect(.degrees(Double(i) / Double(innerCount) * 360 - innerAngle))
            }

            // Core glow pulse
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.2), Color.white.opacity(0.05), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 20, height: 20)
                .scaleEffect(corePulse)

            // Tiny bright center dot
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 3, height: 3)
                .shadow(color: .white.opacity(0.3), radius: 4)
        }
        .onAppear { startAnimations() }
    }

    private func startAnimations() {
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            outerAngle = 360
        }
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            innerAngle = 360
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
            corePulse = 1.35
        }
    }
}
