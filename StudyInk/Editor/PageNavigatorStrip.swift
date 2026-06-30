import SwiftUI

/// Thumbnail strip for page navigation. Long-press a thumbnail for add / duplicate /
/// reorder / delete; tap to jump. Docks to the bottom (horizontal) or side (vertical).
struct PageNavigatorStrip: View {
    @ObservedObject var note: Note
    @Binding var currentIndex: Int
    var horizontal = true
    /// Runs before any page-list mutation so the editor can flush the live
    /// canvas's debounced ink save while indices still mean the same pages.
    var onWillMutatePages: () -> Void = {}
    /// Index currently lifted by a drag (dimmed in place while hovering).
    @State private var draggingIndex: Int?
    /// Page delete awaiting confirmation.
    @State private var pendingDeleteIndex: Int?

    var body: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: 10))
            : AnyLayout(VStackLayout(spacing: 10))

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array(note.sortedPages.enumerated()), id: \.element.objectID) { index, page in
                    thumbnail(for: page, index: index)
                        .opacity(draggingIndex == index ? 0.4 : 1)
                        // Live reorder: pages shift out of the way while the
                        // dragged thumbnail hovers, and the .move proposal
                        // keeps the green "+" copy badge off the preview.
                        .onDrag {
                            onWillMutatePages()
                            draggingIndex = index
                            return NSItemProvider(object: "studyink.page" as NSString)
                        }
                        .onDrop(of: [.text], delegate: PageReorderDropDelegate(
                            index: index,
                            draggingIndex: $draggingIndex,
                            move: liveMove,
                            end: commitReorder
                        ))
                }
                addPageButton
            }
            .padding(10)
            // Thumbnails slide into place on reorder/insert/delete instead of
            // teleporting (keyed on the page order).
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: note.sortedPages.map(\.objectID))
        }
        .studyGlass(cornerRadius: 16)
        .frame(maxWidth: horizontal ? 460 : 84, maxHeight: horizontal ? 100 : 480)
        .alert(Text("page.delete.confirm"), isPresented: Binding(
            get: { pendingDeleteIndex != nil },
            set: { if !$0 { pendingDeleteIndex = nil } }
        )) {
            Button("action.cancel", role: .cancel) { pendingDeleteIndex = nil }
            Button("action.delete", role: .destructive) {
                if let index = pendingDeleteIndex { delete(index: index) }
                pendingDeleteIndex = nil
            }
        } message: {
            Text("delete.permanent.message")
        }
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
                    Button(role: .destructive) { pendingDeleteIndex = index } label: { Label("page.delete", systemImage: "trash") }
                }
            }
            .accessibilityLabel(Text("page.thumbnail \(index + 1)"))
    }

    /// Dashed "+ add page" affordance at the end of the strip (spec §3.2).
    private var addPageButton: some View {
        Button {
            addPage()
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SemanticColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 54, height: 72)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("page.addAfter"))
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

    /// Hover-time reorder: reindexes in memory (animated) — no save until the
    /// drop commits, so the strip can shuffle freely under the drag.
    private func liveMove(from: Int, to: Int) {
        guard from != to else { return }
        var pages = note.sortedPages
        guard pages.indices.contains(from), pages.indices.contains(to) else { return }
        let moved = pages.remove(at: from)
        pages.insert(moved, at: to)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            for (index, page) in pages.enumerated() { page.index = Int32(index) }
        }
        currentIndex = to
    }

    private func commitReorder() {
        note.touch()
        PersistenceController.shared.save()
        Haptics.success()
    }

    private func delete(index: Int) {
        onWillMutatePages()
        note.deletePage(note.sortedPages[index])
        PersistenceController.shared.save()
        currentIndex = min(index, note.sortedPages.count - 1)
    }
}

/// Reorders pages live as the drag hovers over each slot; `.move` keeps the
/// system's green "+" copy badge off the drag preview.
private struct PageReorderDropDelegate: DropDelegate {
    let index: Int
    @Binding var draggingIndex: Int?
    let move: (Int, Int) -> Void
    let end: () -> Void

    func dropEntered(info: DropInfo) {
        guard let from = draggingIndex, from != index else { return }
        move(from, index)
        draggingIndex = index
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingIndex = nil
        end()
        return true
    }
}

/// Page preview: instant template placeholder, then the FULL page render —
/// ink, stickers/media, and typed text — at the displayed size.
struct PageThumbnailView: View {
    @ObservedObject var page: Page
    /// Library cover mode: fill the cell (crop to the page top, like a real
    /// notebook cover) so a note thumbnail matches a folder thumbnail's full-bleed
    /// box. Default (strip) keeps the whole page in view (fit) with its own frame.
    var fillCover: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: UIImage?
    /// True once we know the page is empty OR have rendered its image — so a
    /// blank page shows just its template instead of spinning forever.
    @State private var resolved = false
    /// Measured display width — the page renders at this size (× screen scale),
    /// not a fixed tiny raster that upscales into blur.
    @State private var displayWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let pageSize = page.canvasSize
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
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: fillCover ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if !resolved {
                    // Still rendering — the ink-stroke loader, not a beachball.
                    // (A blank page resolves immediately, so it never spins.)
                    InkSpinner(size: 26)
                }
            }
            .onAppear {
                let width = geo.size.width
                DispatchQueue.main.async { displayWidth = width }
            }
            .onChange(of: geo.size.width) { _, width in
                DispatchQueue.main.async { displayWidth = width }
            }
        }
        // In cover mode the grid card supplies its own clip + border, so don't
        // round/stroke a smaller rect inside it.
        .clipShape(RoundedRectangle(cornerRadius: fillCover ? 0 : 8))
        .overlay { if !fillCover { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) } }
        .task(id: page.drawingData) { renderThumbnail() }
        .onChange(of: page.mediaItemsData) { renderThumbnail() }
        .onChange(of: page.textBoxesData) { renderThumbnail() }
        .onChange(of: colorScheme) { renderThumbnail() }
        .onChange(of: displayWidth) { oldWidth, newWidth in
            // (Re-)render once the real cell size is known, or when the cell
            // grows enough to expose the old raster.
            if newWidth > oldWidth * 1.3 { renderThumbnail() }
        }
    }

    private func renderThumbnail() {
        // Full-page snapshot: template/PDF + media + ink + text, like export.
        let snapshot = PageRenderer.Snapshot(page: page)
        guard snapshot.vectorInkData != nil || snapshot.drawingData != nil || !snapshot.mediaItems.isEmpty || !snapshot.textBoxes.isEmpty else {
            thumbnail = nil
            resolved = true   // empty page — show the template, never spin
            return
        }
        // Wait for the real cell size before rendering — otherwise we'd render a
        // tiny 0.2× raster and resolve INSTANTLY (the loader never gets seen), then
        // re-render. Keep the loader up until the actual thumbnail is ready.
        guard displayWidth > 1 else { return }
        // Pixels-per-page-point that fills the actual cell on this screen.
        let renderScale = min(2, max(0.2, displayWidth * UIScreen.main.scale / max(snapshot.pageSize.width, 1)))
        // Follow appearance — PageRenderer maps ink storage→display so a dark
        // thumbnail shows a dark page with light ink (matches the editor).
        let dark = colorScheme == .dark
        // Rasterize ink HERE on the main actor (PKDrawing.image needs main), then
        // composite off-main with no main hop — the old main.sync inside the
        // detached render stalled under load and produced black, ink-less covers.
        let ink = PageRenderer.inkLayer(for: snapshot, darkMode: dark, scale: renderScale)
        Task.detached(priority: .utility) {
            let image = PageRenderer.render(snapshot, darkMode: dark, scale: renderScale, inkLayer: ink)
            await MainActor.run { thumbnail = image; resolved = true }
        }
    }
}
