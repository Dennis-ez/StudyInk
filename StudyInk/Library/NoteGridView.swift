import SwiftUI
import CoreData

/// Notes of the selected section (subject, smart list, or trash), as a grid or
/// list, filtered by search against title + typed text + handwriting OCR.
struct NoteGridView: View {
    let section: LibrarySection
    let searchText: String
    let gridLayout: Bool
    let sort: LibrarySort
    var onNoteOpened: () -> Void = {}

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    @State private var renamingNote: Note?
    @State private var renameText = ""
    @State private var autoOpenNote: Note?
    @Namespace private var zoomNamespace

    private var inTrash: Bool { section == .deleted }

    private var notes: [Note] {
        var result: [Note]
        switch section {
        case .all:
            result = allNotes.filter { $0.deletedAt == nil }
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
        case .size:
            result.sort { approximateSize($0) > approximateSize($1) }
        }
        return result
    }

    var body: some View {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 24) {
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
                    }
                }
                .listStyle(.plain)
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

    private func noteCell(_ note: Note) -> some View {
        NavigationLink {
            NoteEditorContainer(note: note)
                .onAppear(perform: onNoteOpened)
                .noteZoomDestination(id: note.objectID, in: zoomNamespace)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let first = note.sortedPages.first {
                    PageThumbnailView(page: first)
                        .frame(height: 190)
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
            .noteZoomSource(id: note.objectID, in: zoomNamespace)
        }
        .buttonStyle(.plain)
        .draggable((note.id ?? UUID()).uuidString)
        .contextMenu { noteContextMenu(note) }
        .accessibilityLabel(Text(verbatim: note.title ?? ""))
    }

    private func noteListRow(_ note: Note) -> some View {
        NavigationLink {
            NoteEditorContainer(note: note)
                .onAppear(perform: onNoteOpened)
                .noteZoomDestination(id: note.objectID, in: zoomNamespace)
        } label: {
            HStack(spacing: 14) {
                if let first = note.sortedPages.first {
                    PageThumbnailView(page: first)
                        .frame(width: 44, height: 58)
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
            .noteZoomSource(id: note.objectID, in: zoomNamespace)
        }
        .draggable((note.id ?? UUID()).uuidString)
        .contextMenu { noteContextMenu(note) }
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note) -> some View {
        if inTrash {
            Button {
                note.deletedAt = nil
                PersistenceController.shared.save()
            } label: { Label("library.restore", systemImage: "arrow.uturn.backward") }

            Button(role: .destructive) {
                context.delete(note)
                PersistenceController.shared.save()
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
                note.deletedAt = Date()
                PersistenceController.shared.save()
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

/// Zoom transition between a library cell and the editor (iOS 18+); silently
/// a no-op on iOS 17 so the deployment target stays put.
extension View {
    @ViewBuilder
    func noteZoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func noteZoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
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
