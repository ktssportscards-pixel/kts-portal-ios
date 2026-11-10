import SwiftUI

// Native "power-on surge" launch animation — replicates the web splash:
// flash → blue glow ignites → energy rings expand → crest snaps in w/ glow →
// electric flicker → sheen sweep → PORTAL wordmark wipes in + gold underline →
// tagline fades up → hold → fade to app. ~2.1s. Honors Reduce Motion.
struct SplashView: View {
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animated state
    @State private var flash = 0.0
    @State private var glowScale = 0.6
    @State private var glowOpacity = 0.0
    @State private var ring1Scale = 0.3
    @State private var ring1Opacity = 0.0
    @State private var ring2Scale = 0.3
    @State private var ring2Opacity = 0.0
    @State private var crestScale = 0.86
    @State private var crestOpacity = 0.0
    @State private var crestBrightness = 0.0
    @State private var sheenX = -1.2
    @State private var wordWipe = 0.0
    @State private var underline = 0.0
    @State private var tagOpacity = 0.0
    @State private var tagY = 8.0
    @State private var splashOpacity = 1.0

    // Palette (from the approved web splash)
    private let glowBlue = Color(hex: 0x468CFF)   // rgba(70,140,255)
    private let ringBlue = Color(hex: 0x82B9FF)   // rgba(130,185,255)
    private let crestSize: CGFloat = 232

    var body: some View {
        ZStack {
            // 1. Deep-navy radial background
            RadialGradient(gradient: Gradient(stops: [
                .init(color: Color(hex: 0x0A1832), location: 0.0),
                .init(color: Color(hex: 0x071129), location: 0.45),
                .init(color: Color(hex: 0x040B1C), location: 0.78),
                .init(color: Color(hex: 0x02060F), location: 1.0),
            ]), center: .center, startRadius: 0, endRadius: 560)
            .ignoresSafeArea()

            // 4. Energy rings
            Circle().stroke(ringBlue.opacity(ring1Opacity), lineWidth: 2.5)
                .frame(width: crestSize * 0.9, height: crestSize * 0.9)
                .scaleEffect(ring1Scale)
                .shadow(color: ringBlue.opacity(ring1Opacity * 0.8), radius: 12)
            Circle().stroke(ringBlue.opacity(ring2Opacity), lineWidth: 2)
                .frame(width: crestSize * 0.9, height: crestSize * 0.9)
                .scaleEffect(ring2Scale)
                .shadow(color: ringBlue.opacity(ring2Opacity * 0.7), radius: 10)

            // 3. Blue glow bloom behind the crest
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [glowBlue.opacity(0.85), glowBlue.opacity(0.0)]),
                                     center: .center, startRadius: 0, endRadius: crestSize * 0.7))
                .frame(width: crestSize * 1.5, height: crestSize * 1.5)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)
                .blur(radius: 8)

            VStack(spacing: 26) {
                // 5–7. Crest with silhouette glow + sheen sweep
                ZStack {
                    Image("SplashCrest", bundle: .main)
                        .resizable().scaledToFit()
                        .frame(width: crestSize, height: crestSize)
                        .shadow(color: glowBlue.opacity(0.65), radius: 16)
                        .shadow(color: glowBlue.opacity(0.45), radius: 32)
                        .brightness(crestBrightness)

                    // 7. Diagonal sheen, clipped to the dragon's alpha shape
                    GeometryReader { geo in
                        LinearGradient(gradient: Gradient(colors: [.clear, Color.white.opacity(0.55), .clear]),
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: sheenX * geo.size.width)
                            .rotationEffect(.degrees(18))
                    }
                    .frame(width: crestSize, height: crestSize)
                    .mask(Image("SplashCrest", bundle: .main).resizable().scaledToFit().frame(width: crestSize, height: crestSize))
                    .blendMode(.screen)
                }
                .scaleEffect(crestScale)
                .opacity(crestOpacity)

                // 8. PORTAL wordmark (gradient fill, left-to-right wipe) + gold underline + tagline
                VStack(spacing: 12) {
                    TrackedText("PORTAL", spacing: 15)
                        .font(.system(size: 42, weight: .heavy))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xDFE8FF), Color(hex: 0xB9C8EF)],
                                                        startPoint: .top, endPoint: .bottom))
                        .mask(GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * wordWipe, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        })

                    LinearGradient(colors: [Color(hex: 0xF3C45E), Color(hex: 0xFFD98A), Color(hex: 0xF3C45E)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 150 * underline, height: 2.5)
                        .clipShape(Capsule())
                        .shadow(color: KTS.accent.opacity(0.6), radius: 5)

                    TrackedText("PROFESSIONAL CARD BUYING", spacing: 2.5)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: 0x9DB3E6))
                        .opacity(tagOpacity)
                        .offset(y: tagY)
                }
            }

            // 2. White-blue flash
            RadialGradient(gradient: Gradient(colors: [Color(hex: 0xBFD6FF), .clear]),
                           center: .center, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
                .blendMode(.screen)
                .opacity(flash)
                .allowsHitTesting(false)
        }
        .opacity(splashOpacity)
        .onAppear { reduceMotion ? runReduced() : run() }
    }

    // Full timeline
    private func run() {
        // 2. Flash
        withAnimation(.easeOut(duration: 0.14)) { flash = 0.88 }
        at(0.16) { withAnimation(.easeIn(duration: 0.36)) { flash = 0.0 } }

        // 3. Glow ignites
        at(0.06) { withAnimation(.easeOut(duration: 0.5)) { glowScale = 1.1; glowOpacity = 0.9 } }
        at(0.60) { withAnimation(.easeInOut(duration: 0.6)) { glowScale = 1.0; glowOpacity = 0.55 } }

        // 4. Energy rings — pop bright, then expand outward + fade (separate transactions)
        at(0.14) { ring1Opacity = 0.9 }
        at(0.16) { withAnimation(.easeOut(duration: 0.80)) { ring1Scale = 2.5; ring1Opacity = 0.0 } }
        at(0.28) { ring2Opacity = 0.75 }
        at(0.30) { withAnimation(.easeOut(duration: 0.80)) { ring2Scale = 2.4; ring2Opacity = 0.0 } }

        // 5. Crest snaps in (spring overshoot past 1.0 then settles)
        at(0.30) {
            withAnimation(.easeOut(duration: 0.35)) { crestOpacity = 1.0 }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.52)) { crestScale = 1.0 }
        }

        // 6. Electric flicker
        flicker(0.64, [1.9, 0.62, 1.7, 0.86, 1.25, 1.0])

        // 7. Sheen sweep across the dragon
        at(0.88) { withAnimation(.easeInOut(duration: 0.6)) { sheenX = 1.2 } }

        // 8. Wordmark wipe + gold underline + tagline
        at(1.02) { withAnimation(.easeOut(duration: 0.5)) { wordWipe = 1.0 } }
        at(1.24) { withAnimation(.easeOut(duration: 0.45)) { underline = 1.0 } }
        at(1.56) { withAnimation(.easeOut(duration: 0.4)) { tagOpacity = 1.0; tagY = 0 } }

        // 9. Hold, then fade out → reveal app
        at(2.10) { withAnimation(.easeOut(duration: 0.5)) { splashOpacity = 0.0 } }
        at(2.62) { onDone() }
    }

    // Reduce Motion: compose the final frame, hold, fade out — no surge.
    private func runReduced() {
        glowOpacity = 0.5; glowScale = 1.0
        crestOpacity = 1.0; crestScale = 1.0
        wordWipe = 1.0; underline = 1.0
        withAnimation(.easeIn(duration: 0.4)) { tagOpacity = 1.0; tagY = 0 }
        at(1.4) { withAnimation(.easeOut(duration: 0.5)) { splashOpacity = 0.0 } }
        at(1.95) { onDone() }
    }

    private func flicker(_ start: Double, _ values: [Double]) {
        var t = start
        for v in values {
            at(t) { withAnimation(.linear(duration: 0.05)) { crestBrightness = (v - 1.0) * 0.5 } }
            t += 0.09
        }
        at(t) { withAnimation(.easeOut(duration: 0.12)) { crestBrightness = 0.0 } }
    }

    private func at(_ delay: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// Letter-spaced text (iOS 15-safe stand-in for .tracking, which is iOS 16+).
// Font + foreground style applied by the caller propagate to each letter.
struct TrackedText: View {
    let text: String
    let spacing: CGFloat
    init(_ text: String, spacing: CGFloat) { self.text = text; self.spacing = spacing }
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                Text(ch == " " ? "\u{00A0}" : String(ch))
            }
        }
    }
}
