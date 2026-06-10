import SwiftUI
import PencilKit

/// Thumbnail strip for page navigation. Long-press a thumbnail for add / duplicate /
/// reorder / delete; tap to jump. Docks to the bottom (horizontal) or side (vertical).
struct PageNavigatorStrip: View {
    @ObservedObject var note: Note
    @Binding var currentIndex: Int
    var horizontal = true

    var body: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: 10))
            : AnyLayout(VStackLayout(spacing: 10))

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array(note.sortedPages.enumerated()), id: \.element.objectID) { index, page in
                    thumbnail(for: page, index: index)
                }
                Button(action: addPage) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 54, height: 72)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(Text("page.add"))
            }
            .padding(10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
            .onTapGesture { currentIndex = index }
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
        let target = Int32(index ?? note.sortedPages.count - 1)
        note.addPage(after: target)
        PersistenceController.shared.save()
        currentIndex = Int(target) + 1
    }

    private func duplicate(index: Int) {
        let source = note.sortedPages[index]
        let copy = note.addPage(after: Int32(index))
        copy.copyContents(from: source)
        PersistenceController.shared.save()
        currentIndex = index + 1
    }

    private func move(from: Int, to: Int) {
        let pages = note.sortedPages
        guard pages.indices.contains(from), pages.indices.contains(to) else { return }
        pages[from].index = Int32(to)
        pages[to].index = Int32(from)
        note.touch()
        PersistenceController.shared.save()
        currentIndex = to
    }

    private func delete(index: Int) {
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
                        accentColor: Color("accentBlue")
                    )
                }
                if let drawingImage {
                    Image(uiImage: drawingImage)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .task(id: page.drawingData) { renderDrawing() }
        .onChange(of: colorScheme) { renderDrawing() }
    }

    private func renderDrawing() {
        let drawing = page.drawing
        guard !drawing.strokes.isEmpty else {
            drawingImage = nil
            return
        }
        let pageRect = CGRect(origin: .zero, size: PageSize.from(id: page.pageSizeID).size)
        let dark = colorScheme == .dark
        Task.detached(priority: .utility) {
            // PKDrawing.image is appearance-sensitive via the trait collection.
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            var image: UIImage?
            traits.performAsCurrent {
                image = drawing.image(from: pageRect, scale: 0.2)
            }
            await MainActor.run { drawingImage = image }
        }
    }
}
