import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// Notes of the selected section (subject, smart list, or trash), as a grid or
/// list, filtered by search against title + typed text + handwriting OCR.
struct NoteGridView: View {
    let section: LibrarySection
    let searchText: String
    @Binding var gridLayout: Bool
    @Binding var sortRaw: String
    /// Multi-select mode — owned by the library (entered via its ⋯ menu).
    @Binding var selecting: Bool
    var onNoteOpened: () -> Void = {}
    /// Fired when the editor pops — the library restores its sidebar.
    var onNoteClosed: () -> Void = {}
    var onNewNote: () -> Void = {}
    var onImportPDF: () -> Void = {}
    /// Navigate the file browser into a folder (nil = root / All Notes).
    var onOpenFolder: (Subject?) -> Void = { _ in }

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .dateModified }

    // MARK: - File-browser (stage 2) tree state

    /// The folder currently being browsed (nil = root / All Notes).
    private var currentFolder: Subject? {
        if case .subject(let s) = section { return s }
        return nil
    }
    /// Show subfolders + drill-down: inside a subject, or All Notes' default tab.
    private var showFolderBrowse: Bool {
        if case .subject = section { return true }
        return section == .all && allTab == .all
    }
    /// The current folder's subfolders (dividers excluded — they're sidebar-only),
    /// ordered by the unified tree position, name-filtered while searching.
    private var subfolders: [Subject] {
        guard showFolderBrowse else { return [] }
        let kids = FileTree.children(of: currentFolder, in: context).compactMap { node -> Subject? in
            if case .folder(let s) = node, !s.isDivider { return s }
            return nil
        }
        guard !searchText.isEmpty else { return kids }
        return kids.filter { ($0.name ?? "").localizedStandardContains(searchText) }
    }
    /// Root → current folder, for the breadcrumb trail.
    private var breadcrumbs: [Subject] {
        var chain: [Subject] = []
        var node = currentFolder
        while let n = node { chain.insert(n, at: 0); node = n.parent }
        return chain
    }
    private func folderItemCount(_ s: Subject) -> Int {
        (s.children?.count(where: { !$0.isDivider }) ?? 0) + (s.notes?.count(where: { $0.deletedAt == nil }) ?? 0)
    }

    // MARK: - Unified drag-to-move/nest (stage 3)

    /// Move the dragged items INTO `folder` (nil = root): notes by UUID get filed
    /// there; "subject:" folders get nested (cycle-guarded). Returns true if
    /// anything moved.
    private func moveItems(_ ids: [String], into folder: Subject?) -> Bool {
        var changed = false
        for id in ids {
            if id.hasPrefix("subject:") {
                let uuid = String(id.dropFirst("subject:".count))
                if let dragged = fetchSubject(uuid), dragged != folder, canNest(dragged, into: folder) {
                    let base = (FileTree.children(of: folder, in: context).map(\.sortIndex).max() ?? -1) + 1
                    dragged.parent = folder
                    dragged.sortIndex = base
                    changed = true
                }
            } else if let note = allNotes.first(where: { $0.id?.uuidString == id }), note.subject != folder {
                let base = (FileTree.children(of: folder, in: context).map(\.sortIndex).max() ?? -1) + 1
                note.subject = folder
                note.sortIndex = base
                changed = true
            }
        }
        if changed { PersistenceController.shared.save() }
        return changed
    }

    private func fetchSubject(_ uuid: String) -> Subject? {
        let r = NSFetchRequest<Subject>(entityName: "Subject")
        return (try? context.fetch(r))?.first { $0.id?.uuidString == uuid }
    }

    // MARK: - Drag-to-reorder (stage 3b)

    /// The drag payload id for a node: a bare note UUID, or "subject:<uuid>".
    private func dragID(for node: FileNode) -> String {
        switch node {
        case .note(let n): return n.id?.uuidString ?? ""
        case .folder(let s): return "subject:\(s.id?.uuidString ?? "")"
        }
    }
    private func nodeMatches(_ node: FileNode, _ id: String) -> Bool { dragID(for: node) == id }
    private func setSortIndex(_ node: FileNode, _ index: Int32) {
        switch node {
        case .note(let n): n.sortIndex = index
        case .folder(let s): s.sortIndex = index
        }
    }

    /// Live reorder: move the dragged item to `target`'s slot among the current
    /// folder's children and renumber sortIndex. No save (the pending values
    /// reflow the grid); `commitReorder` saves on drop.
    private func reorderItem(_ draggedID: String, to target: FileNode) {
        var children = FileTree.children(of: currentFolder, in: context)
        guard let from = children.firstIndex(where: { nodeMatches($0, draggedID) }),
              let to = children.firstIndex(where: { $0.id == target.id }), from != to else { return }
        children.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        for (i, node) in children.enumerated() { setSortIndex(node, Int32(i)) }
    }
    private func commitReorder() { PersistenceController.shared.save() }

    private func noteDragPreview(_ note: Note) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(verbatim: note.title ?? "—").font(.callout).lineLimit(1).foregroundStyle(.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    /// The drop delegate for a node (reorder over notes, nest onto folders).
    private func dropDelegate(_ node: FileNode) -> FileItemDropDelegate {
        FileItemDropDelegate(
            target: node,
            draggedID: $draggedID,
            reorder: reorderItem,
            nest: { moveItems([$0], into: $1) },
            commit: commitReorder
        )
    }

    /// A folder can't be nested into itself or any of its descendants. nil target
    /// (root) is always allowed unless it's already at the root.
    private func canNest(_ dragged: Subject, into target: Subject?) -> Bool {
        guard let target else { return dragged.parent != nil }
        if dragged == target { return false }
        var node: Subject? = target
        while let n = node {
            if n == dragged { return false }
            node = n.parent
        }
        return true
    }

    /// A clean capsule drag preview for a folder (no default black snapshot).
    private func folderDragPreview(_ folder: Subject) -> some View {
        let tint = Color(hex: folder.colorHex ?? "#0A84FF") ?? .accentColor
        return HStack(spacing: 7) {
            Image(systemName: "folder.fill").foregroundStyle(tint)
            Text(verbatim: folder.name ?? "—").font(.callout).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    @Environment(\.managedObjectContext) private var context
    @Environment(\.themePaper) private var themePaper
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    @State private var renamingNote: Note?
    @State private var renameText = ""
    @FocusState private var noteRenameFocused: Bool
    @State private var autoOpenNote: Note?
    @State private var selectedIDs: Set<NSManagedObjectID> = []
    /// The drag payload of the item currently being dragged (reorder/nest).
    @State private var draggedID: String?
    /// Pending delete awaiting the user's confirmation.
    @State private var deleteRequest: DeleteRequest?

    private enum DeleteRequest {
        case note(Note)         // → Recently Deleted
        case noteForever(Note)
        case bulk               // selection → Recently Deleted
        case bulkForever

        var isPermanent: Bool {
            switch self {
            case .noteForever, .bulkForever: return true
            case .note, .bulk: return false
            }
        }
    }
    @Namespace private var zoomNamespace

    /// Trash mode (restore/permanent-delete actions, no import/new): the old
    /// sidebar section OR the new "Recently Deleted" chip under All Notes.
    private var inTrash: Bool { section == .deleted || (section == .all && allTab == .deleted) }

    /// Sub-filter tabs shown only in All Notes. Recently Deleted lives here now
    /// instead of in the sidebar.
    enum AllTab: String, CaseIterable {
        case all, recents, favorites, unfiled, deleted

        var labelKey: LocalizedStringKey {
            switch self {
            case .all: return "library.allNotes"
            case .recents: return "library.recents"
            case .favorites: return "library.favorites"
            case .unfiled: return "library.unfiled"
            case .deleted: return "library.recentlyDeleted"
            }
        }
    }

    @State private var allTab: AllTab = .all

    private var notes: [Note] {
        var result: [Note]
        switch section {
        case .all:
            if allTab == .deleted {
                result = allNotes.filter { $0.deletedAt != nil }
            } else {
                result = allNotes.filter { $0.deletedAt == nil }
                switch allTab {
                case .all:
                    // Finder root: only the notes that sit at the top level — the
                    // ones inside folders show when you navigate into the folder.
                    result = result.filter { $0.subject == nil }
                case .deleted:
                    break
                case .recents:
                    let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
                    result = result.filter { ($0.modifiedAt ?? .distantPast) > cutoff }
                case .favorites:
                    result = result.filter(\.isFavorite)
                case .unfiled:
                    result = result.filter { $0.subject == nil }
                }
            }
        case .recents:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            result = allNotes.filter { $0.deletedAt == nil && ($0.modifiedAt ?? .distantPast) > cutoff }
        case .favorites:
            result = allNotes.filter { $0.deletedAt == nil && $0.isFavorite }
        case .deleted:
            result = allNotes.filter { $0.deletedAt != nil }
        case .subject(let subject):
            result = allNotes.filter { $0.deletedAt == nil && $0.subject == subject }
        }
        if !searchText.isEmpty {
            // localizedStandardContains: case-, diacritic- (niqqud), and
            // width-insensitive — the right matcher for Hebrew + English.
            result = result.filter {
                ($0.searchableText ?? "").localizedStandardContains(searchText)
                    || ($0.title ?? "").localizedStandardContains(searchText)
            }
        }
        switch sort {
        case .dateModified:
            result.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .name:
            result.sort { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        case .createdDate:
            result.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Big serif title (Paper & Ink), in the content not the nav bar.
            HStack(spacing: 10) {
                Group {
                    if case .subject(let s) = section { Text(verbatim: s.name ?? "") }
                    else { Text(section.titleKey) }
                }
                .font(.fraunces(30, weight: .semibold, relativeTo: .largeTitle))
                .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if !selecting { headerActions }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            // Breadcrumb trail when browsing inside a folder.
            if !breadcrumbs.isEmpty { breadcrumbBar }
            // Sub-filters live under the All Notes title — only there. Pill
            // tabs (Paper & Ink), not the iOS segmented control.
            if section == .all {
                HStack(spacing: 6) {
                    ForEach(AllTab.allCases, id: \.self) { tab in
                        let on = allTab == tab
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { allTab = tab }
                        } label: {
                            Text(tab.labelKey)
                                .font(.callout.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color(.systemBackground) : .secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(SemanticColor.sidebarBackground))
                                )
                                .overlay(
                                    Capsule().strokeBorder(on ? Color.clear : SemanticColor.separator)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            content
        }
        .background(themePaper.ignoresSafeArea())
    }

    /// Top-right action cluster on the title row (design layout): Ask AI pill ·
    /// Import · More · New note.
    @ViewBuilder
    private var headerActions: some View {
        if !inTrash {
            gridCircleButton("file-up", label: "media.importPDF", action: onImportPDF)
        }

        Menu {
            Button { gridLayout.toggle() } label: {
                Label(
                    gridLayout ? "library.layout.list" : "library.layout.grid",
                    systemImage: gridLayout ? "list.bullet" : "square.grid.2x2"
                )
            }
            Button { selecting = true } label: { Label("library.selectNotes", systemImage: "checkmark.circle") }
            Menu {
                Picker("library.sort", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases, id: \.rawValue) { s in
                        Text(s.labelKey).tag(s.rawValue)
                    }
                }
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
                Text(sort.labelKey)
            }
        } label: {
            gridCircleLabel("more-horizontal")
        }
        .accessibilityLabel(Text("library.sort"))

        if !inTrash {
            Button(action: onNewNote) {
                Lucide("square-pen", size: 16)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("library.newNote"))
        }
    }

    private func gridCircleLabel(_ lucide: String) -> some View {
        Lucide(lucide, size: 16)
            .foregroundStyle(SemanticColor.textPrimary)
            .frame(width: 38, height: 38)
            .background(themePaper, in: Circle())
            .overlay(Circle().strokeBorder(SemanticColor.separator))
    }

    private func gridCircleButton(_ lucide: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { gridCircleLabel(lucide) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(label))
    }

    /// Spec empty state: a sparkles glyph in a soft circle + serif heading.
    private var emptyState: some View {
        VStack(spacing: DS.Space.md) {
            Circle()
                .fill(SemanticColor.surface2)
                .frame(width: 56, height: 56)
                .overlay(Lucide("sparkles", size: 24).foregroundStyle(Color.accentColor))
            Text("library.empty")
                .font(.fraunces(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(.primary)
            Text("library.empty.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: createNote) {
                Label("library.newNote", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if notes.isEmpty && subfolders.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView("library.noResults", systemImage: "magnifyingglass")
                } else if inTrash {
                    ContentUnavailableView {
                        Label("library.trashEmpty", systemImage: "trash")
                    } description: {
                        Text("library.trashEmpty.subtitle")
                    }
                } else {
                    emptyState
                }
            } else if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: DS.Space.xl)], spacing: DS.Space.xl) {
                        // Subfolders first, then notes — the Finder tree at this level.
                        ForEach(subfolders, id: \.objectID) { folder in
                            folderCell(folder)
                        }
                        ForEach(notes, id: \.objectID) { note in
                            noteCell(note)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
            } else {
                List {
                    ForEach(subfolders, id: \.objectID) { folder in
                        folderListRow(folder)
                    }
                    ForEach(notes, id: \.objectID) { note in
                        noteListRow(note)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                // Explicit red: the app-wide accent tint was
                                // overriding the destructive role's background.
                                if inTrash {
                                    Button(role: .destructive) {
                                        deleteRequest = .noteForever(note)
                                    } label: { Label("library.deleteForever", systemImage: "trash.slash") }
                                        .tint(Color("errorRed"))
                                    Button {
                                        note.deletedAt = nil
                                        PersistenceController.shared.save()
                                    } label: { Label("library.restore", systemImage: "arrow.uturn.backward") }
                                } else {
                                    Button(role: .destructive) {
                                        deleteRequest = .note(note)
                                    } label: { Label("action.delete", systemImage: "trash") }
                                        .tint(Color("errorRed"))
                                }
                            }
                    }
                }
                // Inset rows: .plain stretched rows edge-to-edge under the
                // sidebar, which looked broken on interaction.
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        // Full-screen (window-level) presentation: the editor covers everything,
        // so it's never constrained to the content-column width (which caused the
        // desk to flash on the right during entry). No sidebar collapse needed.
        .fullScreenCover(isPresented: Binding(
            get: { autoOpenNote != nil },
            set: { if !$0 { autoOpenNote = nil } }
        )) {
            if let note = autoOpenNote {
                NoteEditorContainer(note: note)
                    // Zoom in/out to/from the note's cell, iOS app-open style, with
                    // the drag-to-dismiss disabled (it used to pop the editor mid-draw).
                    .noteZoomDestination(id: note.objectID, in: zoomNamespace)
            }
        }
        .onChange(of: section) {
            selecting = false
            selectedIDs = []
        }
        .toolbar { selectionToolbar }
        .alert(
            deleteRequest?.isPermanent == true ? Text("library.deleteForever.confirm") : Text("library.deleteNote.confirm"),
            isPresented: Binding(
                get: { deleteRequest != nil },
                set: { if !$0 { deleteRequest = nil } }
            )
        ) {
            Button("action.cancel", role: .cancel) { deleteRequest = nil }
            Button("action.delete", role: .destructive) {
                performPendingDelete()
            }
        } message: {
            deleteRequest?.isPermanent == true ? Text("library.deleteForever.message") : Text("library.deleteNote.message")
        }
    }

    private func performPendingDelete() {
        switch deleteRequest {
        case .note(let note):
            note.deletedAt = Date()
            PersistenceController.shared.save()
        case .noteForever(let note):
            context.delete(note)
            PersistenceController.shared.save()
        case .bulk:
            applyToSelection { $0.deletedAt = Date() }
        case .bulkForever:
            applyToSelection { context.delete($0) }
        case nil:
            break
        }
        deleteRequest = nil
    }

    // MARK: - Multi-select

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if selecting {
                if inTrash {
                    Button {
                        applyToSelection { $0.deletedAt = nil }
                    } label: { Label("library.restore", systemImage: "arrow.uturn.backward") }
                        .disabled(selectedIDs.isEmpty)
                    Button(role: .destructive) {
                        deleteRequest = .bulkForever
                    } label: { Label("library.deleteForever", systemImage: "trash.slash") }
                        .disabled(selectedIDs.isEmpty)
                        // Toolbar buttons ignore the destructive role's color.
                        .tint(Color("errorRed"))
                } else {
                    Button {
                        applyToSelection { $0.isFavorite = true }
                    } label: { Label("library.favorite", systemImage: "star") }
                        .disabled(selectedIDs.isEmpty)
                    Button(role: .destructive) {
                        deleteRequest = .bulk
                    } label: { Label("action.delete", systemImage: "trash") }
                        .disabled(selectedIDs.isEmpty)
                        .tint(Color("errorRed"))
                }
                Button("action.cancel") {
                    withAnimation { selecting = false; selectedIDs = [] }
                }
            }
        }
    }

    private func applyToSelection(_ change: (Note) -> Void) {
        for note in notes where selectedIDs.contains(note.objectID) {
            change(note)
        }
        PersistenceController.shared.save()
        withAnimation {
            selecting = false
            selectedIDs = []
        }
    }

    private func toggleSelection(_ note: Note) {
        Haptics.selection()
        if !selectedIDs.insert(note.objectID).inserted {
            selectedIDs.remove(note.objectID)
        }
    }

    @ViewBuilder
    private func selectionBadge(_ note: Note) -> some View {
        let isSelected = selectedIDs.contains(note.objectID)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(Circle().fill(.background.opacity(0.85)))
            .padding(6)
    }

    private func openNote(_ note: Note) {
        // The editor is presented full-screen (window level), so it's independent
        // of the content-column width — no sidebar-collapse dance, no desk strip.
        Haptics.tap()
        autoOpenNote = note
    }

    private func commitNoteRename() {
        guard let note = renamingNote else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            note.title = trimmed
            note.touch()
            PersistenceController.shared.save()
        }
        renamingNote = nil
    }

    /// The note's title — an inline editable field while renaming (no popup),
    /// otherwise plain text.
    @ViewBuilder
    private func noteTitleView(_ note: Note, font: Font) -> some View {
        if renamingNote == note {
            TextField("library.noteTitle", text: $renameText)
                .font(font)
                .focused($noteRenameFocused)
                .submitLabel(.done)
                .onSubmit(commitNoteRename)
                .onAppear { DispatchQueue.main.async { noteRenameFocused = true } }
                .onChange(of: noteRenameFocused) { _, focused in if !focused { commitNoteRename() } }
        } else {
            Text(verbatim: note.title ?? "")
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func createNote() {
        var subject: Subject?
        if case .subject(let s) = section { subject = s }
        let note = Note.create(in: context, title: String(localized: "library.untitledNote"), subject: subject)
        if section == .favorites { note.isFavorite = true }
        PersistenceController.shared.save()
        Haptics.tap()
        autoOpenNote = note
    }

    // MARK: - Cells

    @ViewBuilder
    private func noteCell(_ note: Note) -> some View {
        if selecting {
            Button {
                toggleSelection(note)
            } label: {
                gridCellLabel(note)
                    .overlay(alignment: .topTrailing) { selectionBadge(note) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: note.title ?? ""))
        } else {
            // Binding-driven push (not NavigationLink) so the library sidebar can
            // re-expand at the START of the back gesture — see the shared
            // navigationDestination below — instead of after the pop completes.
            Button {
                if renamingNote != note { openNote(note) }
            } label: {
                gridCellLabel(note)
            }
            .buttonStyle(.plain)
            // Zoom in/out between this cell and the editor (the source of the zoom).
            .noteZoomSource(id: note.objectID, in: zoomNamespace)
            // Drag to reorder among notes, or onto a folder to file it there.
            .onDrag({
                let id = note.id?.uuidString ?? ""
                draggedID = id
                return NSItemProvider(object: id as NSString)
            }, preview: { noteDragPreview(note) })
            .onDrop(of: [.text], delegate: dropDelegate(.note(note)))
            .contextMenu { noteContextMenu(note) }
            .accessibilityLabel(Text(verbatim: note.title ?? ""))
        }
    }

    // MARK: - Folder cards / rows (stage 2)

    private func folderCell(_ folder: Subject) -> some View {
        let tint = Color(hex: folder.colorHex ?? "#0A84FF") ?? .accentColor
        return Button { onOpenFolder(folder) } label: {
            VStack(spacing: 0) {
                ZStack {
                    tint.opacity(0.16)
                    Image(systemName: "folder.fill").font(.system(size: 46)).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(9 / 10, contentMode: .fit)
                .clipped()
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SemanticColor.cardEdge).frame(height: 1)
                }
                // Footer styled IDENTICALLY to a note card's (same fonts + padding)
                // so a folder card and a note card are exactly the same height.
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: folder.name ?? "").font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    (Text(verbatim: "\(folderItemCount(folder))").font(.caption.monospacedDigit())
                        + Text(verbatim: " ") + Text("library.items").font(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .environment(\.layoutDirection, (folder.name?.isMostlyRTL ?? false) ? .rightToLeft : .leftToRight)
            }
            // Same card shell as a note (gridCellLabel) so a folder and a note are
            // pixel-for-pixel the same size, just with a colour-tile cover.
            .background(SemanticColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SemanticColor.cardEdge))
            .elevation(.e1)
        }
        .buttonStyle(.plain)
        // Drag the folder (reorder among siblings), and accept notes/folders
        // dropped ONTO it to nest them.
        .onDrag({
            let id = "subject:\(folder.id?.uuidString ?? "")"
            draggedID = id
            return NSItemProvider(object: id as NSString)
        }, preview: { folderDragPreview(folder) })
        .onDrop(of: [.text], delegate: dropDelegate(.folder(folder)))
        .accessibilityLabel(Text(verbatim: folder.name ?? ""))
    }

    private func folderListRow(_ folder: Subject) -> some View {
        let tint = Color(hex: folder.colorHex ?? "#0A84FF") ?? .accentColor
        return Button { onOpenFolder(folder) } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(tint).frame(width: 26)
                Text(verbatim: folder.name ?? "").font(.body).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text(verbatim: "\(folderItemCount(folder))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag({
            let id = "subject:\(folder.id?.uuidString ?? "")"
            draggedID = id
            return NSItemProvider(object: id as NSString)
        }, preview: { folderDragPreview(folder) })
        .onDrop(of: [.text], delegate: dropDelegate(.folder(folder)))
        .accessibilityLabel(Text(verbatim: folder.name ?? ""))
    }

    /// Root → current folder, tappable to navigate up the tree.
    @ViewBuilder private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button { onOpenFolder(nil) } label: {
                    Text("library.allNotes").font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // Drop onto a crumb to move the item UP into that folder (or root).
                .onDrop(of: [.text], delegate: SidebarDropDelegate { moveItems($0, into: nil) })
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.objectID) { i, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button { onOpenFolder(crumb) } label: {
                        Text(verbatim: crumb.name ?? "")
                            .font(.callout)
                            .foregroundStyle(i == breadcrumbs.count - 1 ? Color.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(i == breadcrumbs.count - 1)
                    .onDrop(of: [.text], delegate: SidebarDropDelegate { moveItems($0, into: crumb) })
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 6)
    }

    private func gridCellLabel(_ note: Note) -> some View {
        VStack(spacing: 0) {
            // Cover: the top of the first page, like a real notebook cover. A
            // portrait 4:5 window (taller than wide) so the card reads as a
            // notebook, not a landscape tile.
            Group {
                if let first = note.sortedPages.first {
                    // Fill the cover box (crop to the page top) so a note thumbnail
                    // matches a folder thumbnail's full-bleed size.
                    PageThumbnailView(page: first, fillCover: true)
                } else {
                    Rectangle().fill(SemanticColor.sidebarBackground)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9 / 10, contentMode: .fit)
            .clipped()
            .overlay(alignment: .bottom) {
                Rectangle().fill(SemanticColor.cardEdge).frame(height: 1)
            }

            // Footer on the card's paper: name + subject dot, then date.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    noteTitleView(note, font: .callout.weight(.semibold))
                    Spacer(minLength: 2)
                    if let subject = note.subject {
                        Circle()
                            .fill(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                            .frame(width: 9, height: 9)
                    }
                }
                Text(note.modifiedAt ?? .now, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(SemanticColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SemanticColor.cardEdge))
        .elevation(.e1)
    }

    @ViewBuilder
    private func noteListRow(_ note: Note) -> some View {
        if selecting {
            Button {
                toggleSelection(note)
            } label: {
                HStack(spacing: 12) {
                    selectionBadge(note)
                    listRowLabel(note)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if renamingNote != note { openNote(note) }
            } label: {
                listRowLabel(note)
            }
            .buttonStyle(.plain)
            .noteZoomSource(id: note.objectID, in: zoomNamespace)
            // No .draggable here: its horizontal drag swallowed the swipe
            // gesture, so swipe-to-delete never triggered in list mode.
            // (Drag-to-file-into-a-subject still works from the grid.)
            .contextMenu { noteContextMenu(note) }
        }
    }

    private func listRowLabel(_ note: Note) -> some View {
        HStack(spacing: 14) {
            if let first = note.sortedPages.first {
                PageThumbnailView(page: first)
                    .frame(width: 56, height: 74)
            }
            VStack(alignment: .leading, spacing: 3) {
                noteTitleView(note, font: .body.weight(.medium))
                HStack(spacing: 8) {
                    Text("library.created \(dateString(note.createdAt))")
                    Text("library.modified \(dateString(note.modifiedAt))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("library.pageCount \(note.sortedPages.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note) -> some View {
        if inTrash {
            Button {
                note.deletedAt = nil
                PersistenceController.shared.save()
            } label: { Label("library.restore", systemImage: "arrow.uturn.backward") }

            Button(role: .destructive) {
                deleteRequest = .noteForever(note)
            } label: { Label("library.deleteForever", systemImage: "trash.slash") }
        } else {
            Button {
                note.isFavorite.toggle()
                PersistenceController.shared.save()
            } label: {
                Label(note.isFavorite ? "library.unfavorite" : "library.favorite",
                      systemImage: note.isFavorite ? "star.slash" : "star")
            }

            Button {
                let untitled = String(localized: "library.untitledNote")
                renameText = (note.title == untitled) ? "" : (note.title ?? "")
                renamingNote = note
            } label: { Label("action.rename", systemImage: "pencil") }

            ShareLink(
                item: PDFExportFile(note: note),
                preview: SharePreview(note.title ?? "StudyInk")
            ) {
                Label("export.pdf", systemImage: "square.and.arrow.up")
            }

            // Soft delete: the note sits in Recently Deleted for 30 days.
            Button(role: .destructive) {
                deleteRequest = .note(note)
            } label: { Label("action.delete", systemImage: "trash") }
        }
    }

    private func dateString(_ date: Date?) -> String {
        (date ?? .now).formatted(date: .abbreviated, time: .omitted)
    }

    private func approximateSize(_ note: Note) -> Int {
        note.sortedPages.reduce(0) { $0 + ($1.drawingData?.count ?? 0) + ($1.customTemplatePDF?.count ?? 0) }
    }
}

/// Reliable drag reorder + nest for the file grid. Dragging OVER a note reorders
/// the dragged item into that slot live; dropping ON a folder nests it.
struct FileItemDropDelegate: DropDelegate {
    let target: FileNode
    @Binding var draggedID: String?
    let reorder: (String, FileNode) -> Void   // sets sortIndex (no save)
    let nest: (String, Subject) -> Void        // moves into a folder (saves)
    let commit: () -> Void                      // saves a reorder

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let id = draggedID, !id.isEmpty, !matches(target, id) else { return }
        // Live reorder while hovering another note; a folder stays a nest target.
        if case .note = target { reorder(id, target) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedID else { return false }
        defer { draggedID = nil }
        if case .folder(let folder) = target, !matches(target, id) {
            nest(id, folder)
        } else {
            reorder(id, target)
            commit()
        }
        return true
    }

    private func matches(_ node: FileNode, _ id: String) -> Bool {
        switch node {
        case .note(let n): return n.id?.uuidString == id
        case .folder(let s): return "subject:\(s.id?.uuidString ?? "")" == id
        }
    }
}

/// iOS-app-style zoom in/out between a note's cell and the editor (iOS 18+). The
/// zoom's interactive drag-to-dismiss — which used to pop the editor mid-draw —
/// is disabled, so only the Back button closes it; the zoom-out still plays.
extension View {
    @ViewBuilder
    func noteZoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func noteZoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
                .interactiveDismissDisabled(true)
        } else {
            self
        }
    }
}

/// Transferable wrappers so ShareLink lazily produces export data on demand.
struct PDFExportFile: Transferable {
    let note: Note

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { file in
            await MainActor.run { PageRenderer.pdfData(for: file.note) }
        }
        .suggestedFileName { ($0.note.title ?? "StudyInk") + ".pdf" }
    }
}

struct PNGExportFile: Transferable {
    let page: Page

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { file in
            await MainActor.run { PageRenderer.pngData(for: file.page, darkMode: false) ?? Data() }
        }
        .suggestedFileName { ($0.page.note?.title ?? "StudyInk") + ".png" }
    }
}
