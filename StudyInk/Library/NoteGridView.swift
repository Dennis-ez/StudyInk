import SwiftUI
import CoreData

/// Notes of the selected section (subject, smart list, or trash), as a grid or
/// list, filtered by search against title + typed text + handwriting OCR.
struct NoteGridView: View {
    let section: LibrarySection
    let searchText: String
    let gridLayout: Bool
    let sort: LibrarySort
    /// Multi-select mode — owned by the library (entered via its ⋯ menu).
    @Binding var selecting: Bool
    var onNoteOpened: () -> Void = {}
    /// Fired when the editor pops — the library restores its sidebar.
    var onNoteClosed: () -> Void = {}

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    @State private var renamingNote: Note?
    @State private var renameText = ""
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

    private var inTrash: Bool { section == .deleted }

    /// Sub-filter tabs shown only in All Notes.
    enum AllTab: String, CaseIterable {
        case all, recents, favorites, unfiled

        var labelKey: LocalizedStringKey {
            switch self {
            case .all: return "library.allNotes"
            case .recents: return "library.recents"
            case .favorites: return "library.favorites"
            case .unfiled: return "library.unfiled"
            }
        }
    }

    @State private var allTab: AllTab = .all

    private var notes: [Note] {
        var result: [Note]
        switch section {
        case .all:
            result = allNotes.filter { $0.deletedAt == nil }
            switch allTab {
            case .all:
                break
            case .recents:
                let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
                result = result.filter { ($0.modifiedAt ?? .distantPast) > cutoff }
            case .favorites:
                result = result.filter(\.isFavorite)
            case .unfiled:
                result = result.filter { $0.subject == nil }
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
            // Sub-filters live under the All Notes title — only there.
            if section == .all {
                Picker("library.allNotes", selection: $allTab) {
                    ForEach(AllTab.allCases, id: \.self) { tab in
                        Text(tab.labelKey).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
            content
        }
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
                    ContentUnavailableView {
                        Label("library.empty", systemImage: "pencil.and.outline")
                    } description: {
                        Text("library.empty.subtitle")
                    } actions: {
                        Button {
                            createNote()
                        } label: {
                            Label("library.newNote", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 22)], spacing: 26) {
                        ForEach(notes, id: \.objectID) { note in
                            noteCell(note)
                        }
                    }
                    .padding(20)
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
        // Freshly created notes open straight into the editor.
        .navigationDestination(isPresented: Binding(
            get: { autoOpenNote != nil },
            set: { if !$0 { autoOpenNote = nil } }
        )) {
            if let note = autoOpenNote {
                NoteEditorContainer(note: note)
                    .onAppear(perform: onNoteOpened)
                    .onDisappear(perform: onNoteClosed)
            }
        }
        .alert(Text("library.renameNote"), isPresented: renamingBinding) {
            TextField("library.noteTitle", text: $renameText)
            Button("action.cancel", role: .cancel) { renamingNote = nil }
            Button("action.done") {
                renamingNote?.title = renameText
                renamingNote?.touch()
                PersistenceController.shared.save()
                renamingNote = nil
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

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingNote != nil }, set: { if !$0 { renamingNote = nil } })
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
            NavigationLink {
                NoteEditorContainer(note: note)
                    .onAppear(perform: onNoteOpened)
                    .onDisappear(perform: onNoteClosed)
                    .noteZoomDestination(id: note.objectID, in: zoomNamespace)
            } label: {
                gridCellLabel(note)
                    .noteZoomSource(id: note.objectID, in: zoomNamespace)
            }
            .buttonStyle(.plain)
            .draggable((note.id ?? UUID()).uuidString)
            .contextMenu { noteContextMenu(note) }
            .accessibilityLabel(Text(verbatim: note.title ?? ""))
        }
    }

    private func gridCellLabel(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = note.sortedPages.first {
                // Portrait, like a page — not a square box.
                PageThumbnailView(page: first)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: note.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(note.modifiedAt ?? .now, style: .date)
                    Text(verbatim: "·")
                    Text("library.pageCount \(note.sortedPages.count)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
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
            NavigationLink {
                NoteEditorContainer(note: note)
                    .onAppear(perform: onNoteOpened)
                    .onDisappear(perform: onNoteClosed)
                    .noteZoomDestination(id: note.objectID, in: zoomNamespace)
            } label: {
                listRowLabel(note)
                    .noteZoomSource(id: note.objectID, in: zoomNamespace)
            }
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
                Text(verbatim: note.title ?? "")
                    .font(.body.weight(.medium))
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
                renameText = note.title ?? ""
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
