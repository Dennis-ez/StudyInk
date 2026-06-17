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

/// The app mark: a you-accent rounded square with a gold highlight dot — the
/// shared brand glyph used in the sidebar wordmark and the splash.
struct BrandMark: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .fill(Color(red: 1.0, green: 0.839, blue: 0.039)) // #FFD60A
                    .frame(width: size * 0.46, height: size * 0.46)
            )
            .accessibilityHidden(true)
    }
}

/// Sidebar nav row: no resting fill — it reads as text until touched, then
/// dims/insets on press so it reacts like a button under the finger.
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1, anchor: .leading)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
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

/// Launch splash: the brand mark (theme-accent square + gold dot) on warm
/// paper with the serif wordmark, a single spring entrance. No spinner.
/// Follows the active skin so it flows into the app with no flash.
struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            SemanticColor.paperBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                SplashMark()
                    .frame(width: 104, height: 104)
                    .elevation(.e2)
                    .scaleEffect(appeared ? 1 : 0.84)
                    .opacity(appeared ? 1 : 0)
                Text(verbatim: "StudyInk")
                    .font(.fraunces(30, weight: .bold, relativeTo: .title))
                    .foregroundStyle(.primary)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { appeared = true }
        }
    }
}

/// The launch mark — the app-icon motif in SwiftUI: a theme-accent rounded
/// square holding a cream ruled page (tilted) with a gold study dot.
struct SplashMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.88), Color.accentColor],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: s * 0.08, style: .continuous)
                        .fill(Color(red: 0.988, green: 0.980, blue: 0.961))
                        .frame(width: s * 0.56, height: s * 0.62)
                        .overlay {
                            VStack(spacing: s * 0.065) {
                                ForEach(0..<4, id: \.self) { _ in
                                    Capsule().fill(.black.opacity(0.08)).frame(height: s * 0.018)
                                }
                            }
                            .padding(.horizontal, s * 0.10)
                        }
                        .rotationEffect(.degrees(-6))
                        .shadow(color: .black.opacity(0.12), radius: s * 0.03, y: s * 0.02)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.839, blue: 0.039))
                        .frame(width: s * 0.30, height: s * 0.30)
                        .padding(s * 0.06)
                }
        }
        .accessibilityHidden(true)
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
