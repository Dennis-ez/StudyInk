import SwiftUI
import CoreData

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

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .dateModified }

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
                case .all, .deleted:
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
            if notes.isEmpty {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: DS.Space.xl)], spacing: DS.Space.xl) {
                        ForEach(notes, id: \.objectID) { note in
                            noteCell(note)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
            } else {
                List {
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
            .draggable((note.id ?? UUID()).uuidString)
            .contextMenu { noteContextMenu(note) }
            .accessibilityLabel(Text(verbatim: note.title ?? ""))
        }
    }

    private func gridCellLabel(_ note: Note) -> some View {
        VStack(spacing: 0) {
            // Cover: the top of the first page, like a real notebook cover. A
            // portrait 4:5 window (taller than wide) so the card reads as a
            // notebook, not a landscape tile.
            Group {
                if let first = note.sortedPages.first {
                    PageThumbnailView(page: first)
                        .aspectRatio(3 / 4, contentMode: .fill)
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

/// Both no-ops. The iOS 18 zoom transition (.navigationTransition(.zoom))
/// these used to apply brings its own interactive dismissal — drag DOWN or
/// drag RIGHT pops the editor, with no API to disable just the gesture. That
/// was the "drag takes me back to the main screen" the user kept hitting
/// after every edge-pan recognizer was already disabled. Plain push wins.
extension View {
    func noteZoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        self
    }

    func noteZoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        self
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
