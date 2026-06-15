import SwiftUI

/// The brand display face — Fraunces, bundled. Used for every title/heading so
/// the serif voice is consistent across the app (the mockup's display font).
/// Falls back to the system serif if the face ever fails to load.
extension Font {
    static func fraunces(_ size: CGFloat, weight: Font.Weight = .semibold, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom("Fraunces", size: size, relativeTo: textStyle).weight(weight)
    }
}

extension View {
    /// Display text in the brand serif at a fixed scale-relative size.
    func frauncesTitle(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .title) -> some View {
        self.font(.fraunces(size, weight: weight, relativeTo: style))
    }
}

/// The app's loading indicator: a stroke of ink drawing itself round, in the
/// theme accent — never the system beachball. Used on note thumbnails, AI
/// waits, and launch.
struct InkSpinner: View {
    var size: CGFloat = 26
    var tint: Color? = nil
    @State private var spin = false

    var body: some View {
        let color = tint ?? Color.accentColor
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityLabel(Text("loading"))
    }
}

/// Launch splash: the app-icon mark (cream drop on the accent) on warm paper,
/// the drop's fill rising once, the wordmark fading in. Adapts to light/dark so
/// it flows seamlessly from the launch screen into the app — no dark flash.
struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            SemanticColor.paperBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .scaleEffect(appeared ? 1 : 0.82)
                    .opacity(appeared ? 1 : 0)
                Text(verbatim: "StudyInk")
                    .font(.fraunces(30, weight: .bold, relativeTo: .title))
                    .foregroundStyle(.primary)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

/// A simple ink teardrop: round bulb, pointed top — matches the app icon.
struct InkDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let r = w * 0.5
        let cy = h - r                 // bulb centre (SwiftUI y-down)
        p.addEllipse(in: CGRect(x: 0, y: h - 2 * r, width: 2 * r, height: 2 * r))
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addLine(to: CGPoint(x: w * 0.5 - r * 0.92, y: cy - r * 0.32))
        p.addLine(to: CGPoint(x: w * 0.5 + r * 0.92, y: cy - r * 0.32))
        p.closeSubpath()
        return p
    }
}
