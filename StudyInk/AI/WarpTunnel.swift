import SwiftUI

// MARK: - Warp Tunnel (in-note) — peek at the question without leaving your answer
//
// The full spec wanted deep-linking into an external textbook's cached coordinate
// map — that needs a backend this client app doesn't have. The buildable,
// reliable version: when you're writing an answer on a later page, slide up a
// preview of the page that holds the PROBLEM — the page carrying the pasted
// question image, else the first page — so you can re-read it in place.

@MainActor
final class WarpTunnelController: ObservableObject {
    struct Preview { let pageIndex: Int; let image: UIImage }
    @Published var preview: Preview?
    @Published var isFinding = false
    @Published var notice: String?

    func dismiss() { withAnimation(.easeOut(duration: 0.25)) { preview = nil } }

    private func showNotice(_ message: String) {
        notice = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run { if self?.notice == message { self?.notice = nil } }
        }
    }

    /// Finds the problem page and slides up its preview.
    func showQuestion(note: Note, currentPageIndex: Int, darkMode: Bool) async {
        let pages = note.sortedPages
        // The question is usually a pasted screenshot/photo (a page with media),
        // otherwise the first page. Never preview the page you're already on.
        let target: Int? = {
            if let media = pages.enumerated().first(where: { $0.offset != currentPageIndex && !$0.element.mediaItems.isEmpty }) {
                return media.offset
            }
            if currentPageIndex != 0, !pages.isEmpty { return 0 }
            return nil
        }()
        guard let index = target, pages.indices.contains(index) else {
            showNotice(String(localized: "warp.none"))
            return
        }
        isFinding = true
        defer { isFinding = false }
        let snapshot = PageRenderer.Snapshot(page: pages[index])
        let image = await Task.detached(priority: .userInitiated) {
            PageRenderer.render(snapshot, darkMode: darkMode, scale: 2)
        }.value
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            preview = Preview(pageIndex: index, image: image)
        }
        Haptics.tap()
    }
}

/// Slide-up panel showing the question page; pinch/scroll to inspect, tap ✕ to close.
struct WarpTunnelPanel: View {
    let preview: WarpTunnelController.Preview
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                HStack {
                    Label(title: { Text("warp.question \(preview.pageIndex + 1)") },
                          icon: { Image(systemName: "doc.text.magnifyingglass") })
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Image(uiImage: preview.image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
            }
            .frame(height: 400)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SemanticColor.separator))
            .shadow(color: .black.opacity(0.2), radius: 18, y: -4)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // A downward drag dismisses, like a sheet.
            .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.height > 40 { onDismiss() }
            })
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
