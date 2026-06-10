import SwiftUI
import PhotosUI
import VisionKit

/// Camera capture via UIImagePickerController (plain photo, not a scan).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// VisionKit document scanner — auto edge detection, multi-page scans.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScan(images)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }
    }
}

/// Sticker drawer: built-in glyph stickers plus user-imported PNGs.
struct StickerLibrarySheet: View {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var userStickers: [String] = []
    @State private var importingPNG = false

    private let columns = Array(repeating: GridItem(.adaptive(minimum: 72)), count: 1)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 14)], spacing: 14) {
                    ForEach(StickerLibrary.builtIn, id: \.name) { sticker in
                        Button {
                            if let image = StickerLibrary.render(symbol: sticker.symbol, tint: sticker.tint) {
                                onPick(image)
                                dismiss()
                            }
                        } label: {
                            Image(systemName: sticker.symbol)
                                .font(.system(size: 36))
                                .foregroundStyle(Color(sticker.tint))
                                .frame(width: 72, height: 72)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    ForEach(userStickers, id: \.self) { fileName in
                        Button {
                            if let image = MediaStore.image(named: fileName) {
                                onPick(image)
                                dismiss()
                            }
                        } label: {
                            Group {
                                if let image = MediaStore.image(named: fileName) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                }
                            }
                            .frame(width: 72, height: 72)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(Text("media.stickers"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importingPNG = true } label: { Label("media.importSticker", systemImage: "plus") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importingPNG, allowedContentTypes: [.png]) { result in
                if case .success(let url) = result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        MediaStore.save(data, sticker: true)
                        userStickers = MediaStore.userStickers()
                    }
                }
            }
            .onAppear { userStickers = MediaStore.userStickers() }
        }
        .presentationDetents([.medium, .large])
    }
}
