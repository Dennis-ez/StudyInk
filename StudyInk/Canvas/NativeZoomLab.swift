import SwiftUI
import PencilKit

/// STEP 1 of the native-zoom investigation.
///
/// The user chose the PencilKit-NATIVE zoom path over the transform-zoom blur.
/// That restructure has broken input/rendering twice before, so we de-risk it in
/// ISOLATION first: this prototype does NOT touch NoteCanvasEngine or any real
/// note. It answers exactly ONE gating question before we invest in integration:
///
///   On the iOS 26 SDK, does PKCanvasView's OWN scroll-view zoom keep COMMITTED
///   ink crisp — unlike the transform-zoom path (ink blurs) and the contentsScale
///   bump (ink vanished)?
///
/// HOW TO TEST: open it, write a few small letters, then pinch to zoom all the way
/// in. If the ink EDGES stay sharp (not fuzzy/pixelated) and nothing disappears,
/// native zoom is viable and worth building into the real canvas. If the ink goes
/// blurry or vanishes, native zoom is off the table on this SDK and we stop.
struct NativeZoomLabView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            NativeZoomCanvas(darkMode: scheme == .dark)
                .ignoresSafeArea()
            HStack {
                Text(verbatim: "Write, then pinch to zoom — is the ink crisp?")
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button { dismiss() } label: {
                    Text(verbatim: "Done").fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
    }
}

/// A bare PKCanvasView using its OWN UIScrollView zoom (native re-tessellation),
/// not a parent transform. Single page, solid paper background, system tool picker.
struct NativeZoomCanvas: UIViewRepresentable {
    var darkMode: Bool

    static let page = CGSize(width: 820, height: 1160)
    static func paper(_ dark: Bool) -> UIColor {
        dark ? UIColor(white: 0.11, alpha: 1) : UIColor(white: 0.99, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput        // so finger works in the simulator too
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 4             // PencilKit re-renders ink crisp across this range
        canvas.bouncesZoom = true
        canvas.backgroundColor = Self.paper(darkMode)
        canvas.contentSize = Self.page
        canvas.contentInsetAdjustmentBehavior = .never

        // System tool picker so the page is actually drawable.
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        context.coordinator.picker = picker

        DispatchQueue.main.async { _ = canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.backgroundColor = Self.paper(darkMode)
    }

    final class Coordinator: NSObject {
        var picker: PKToolPicker?
    }
}
