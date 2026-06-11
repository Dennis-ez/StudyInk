import SwiftUI
import PencilKit

/// Thumbnail strip for page navigation. Long-press a thumbnail for add / duplicate /
/// reorder / delete; tap to jump. Docks to the bottom (horizontal) or side (vertical).
struct PageNavigatorStrip: View {
    @ObservedObject var note: Note
    @Binding var currentIndex: Int
    var horizontal = true
    /// Runs before any page-list mutation so the editor can flush the live
    /// canvas's debounced ink save while indices still mean the same pages.
    var onWillMutatePages: () -> Void = {}

    var body: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: 10))
            : AnyLayout(VStackLayout(spacing: 10))

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array(note.sortedPages.enumerated()), id: \.element.objectID) { index, page in
                    thumbnail(for: page, index: index)
                        // Drag a thumbnail onto another to reorder pages.
                        .draggable("studyink.page:\(index)")
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first, item.hasPrefix("studyink.page:"),
                                  let from = Int(item.dropFirst("studyink.page:".count)) else { return false }
                            reorder(from: from, to: index)
                            return true
                        }
                }
                Button(action: { addPage() }) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 54, height: 72)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(Text("page.add"))
            }
            .padding(10)
        }
        .studyGlass(cornerRadius: 16)
        .frame(maxWidth: horizontal ? 460 : 84, maxHeight: horizontal ? 100 : 480)
    }

    private func thumbnail(for page: Page, index: Int) -> some View {
        PageThumbnailView(page: page)
            .frame(width: 54, height: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(index == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(3)
                    .background(.thinMaterial, in: Circle())
                    .padding(2)
            }
            .onTapGesture {
                Haptics.selection()
                currentIndex = index
            }
            .contextMenu {
                Button { addPage(after: index) } label: { Label("page.addAfter", systemImage: "plus.rectangle.portrait") }
                Button { duplicate(index: index) } label: { Label("page.duplicate", systemImage: "plus.square.on.square") }
                if index > 0 {
                    Button { move(from: index, to: index - 1) } label: { Label("page.moveBack", systemImage: "arrow.backward") }
                }
                if index < note.sortedPages.count - 1 {
                    Button { move(from: index, to: index + 1) } label: { Label("page.moveForward", systemImage: "arrow.forward") }
                }
                if note.sortedPages.count > 1 {
                    Button(role: .destructive) { delete(index: index) } label: { Label("page.delete", systemImage: "trash") }
                }
            }
            .accessibilityLabel(Text("page.thumbnail \(index + 1)"))
    }

    private func addPage(after index: Int? = nil) {
        onWillMutatePages()
        let target = Int32(index ?? note.sortedPages.count - 1)
        note.addPage(after: target)
        PersistenceController.shared.save()
        currentIndex = Int(target) + 1
    }

    private func duplicate(index: Int) {
        onWillMutatePages()
        let source = note.sortedPages[index]
        let copy = note.addPage(after: Int32(index))
        copy.copyContents(from: source)
        PersistenceController.shared.save()
        currentIndex = index + 1
    }

    private func move(from: Int, to: Int) {
        onWillMutatePages()
        let pages = note.sortedPages
        guard pages.indices.contains(from), pages.indices.contains(to) else { return }
        pages[from].index = Int32(to)
        pages[to].index = Int32(from)
        note.touch()
        PersistenceController.shared.save()
        currentIndex = to
    }

    /// Drag-and-drop reorder: remove at `from`, insert at `to`, reindex all.
    private func reorder(from: Int, to: Int) {
        guard from != to else { return }
        onWillMutatePages()
        var pages = note.sortedPages
        guard pages.indices.contains(from), pages.indices.contains(to) else { return }
        let moved = pages.remove(at: from)
        pages.insert(moved, at: to)
        for (index, page) in pages.enumerated() { page.index = Int32(index) }
        note.touch()
        PersistenceController.shared.save()
        Haptics.success()
        currentIndex = to
    }

    private func delete(index: Int) {
        onWillMutatePages()
        note.deletePage(note.sortedPages[index])
        PersistenceController.shared.save()
        currentIndex = min(index, note.sortedPages.count - 1)
    }
}

/// Cheap page preview: template pattern + drawing image, dark-mode correct.
struct PageThumbnailView: View {
    @ObservedObject var page: Page
    @Environment(\.colorScheme) private var colorScheme
    @State private var drawingImage: UIImage?
    /// Measured display width — the ink renders at this size (× screen scale),
    /// not a fixed tiny raster that upscales into blur.
    @State private var displayWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let pageSize = PageSize.from(id: page.pageSizeID).size
            let scale = geo.size.width / pageSize.width

            ZStack {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color("canvasBackground")))
                    page.template.draw(
                        in: &ctx,
                        rect: CGRect(origin: .zero, size: CGSize(width: pageSize.width * scale, height: pageSize.height * scale)),
                        scale: scale,
                        lineColor: Color("templateLine"),
                        accentColor: Color("accentBlue"),
                        spacing: page.effectiveTemplateSpacing
                    )
                }
                if let drawingImage {
                    Image(uiImage: drawingImage)
                        .resizable()
                        .scaledToFit()
                }
            }
            .onAppear { displayWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in displayWidth = width }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .task(id: page.drawingData) { renderDrawing() }
        .onChange(of: colorScheme) { renderDrawing() }
        .onChange(of: displayWidth) { oldWidth, newWidth in
            // Re-render when the cell grows enough to expose the old raster.
            if newWidth > oldWidth * 1.3 { renderDrawing() }
        }
    }

    private func renderDrawing() {
        let drawing = page.drawing
        guard !drawing.strokes.isEmpty else {
            drawingImage = nil
            return
        }
        let pageRect = CGRect(origin: .zero, size: PageSize.from(id: page.pageSizeID).size)
        // Pixels-per-page-point that fills the actual cell on this screen.
        let renderScale = min(2, max(0.2, displayWidth * UIScreen.main.scale / max(pageRect.width, 1)))
        let dark = colorScheme == .dark
        Task.detached(priority: .utility) {
            // PKDrawing.image is appearance-sensitive via the trait collection.
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let image = render(in: traits)
            await MainActor.run { drawingImage = image }
        }

        @Sendable func render(in traits: UITraitCollection) -> UIImage? {
            var image: UIImage?
            traits.performAsCurrent {
                image = drawing.image(from: pageRect, scale: renderScale)
            }
            return image
        }
    }
}
