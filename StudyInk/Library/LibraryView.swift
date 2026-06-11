import SwiftUI
import CoreData
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable {
    case dateModified, name, size

    var labelKey: LocalizedStringKey {
        switch self {
        case .dateModified: return "library.sort.date"
        case .name: return "library.sort.name"
        case .size: return "library.sort.size"
        }
    }
}

/// The home screen: subjects (folders + dividers) in the sidebar, notes in a
/// grid or list, full-text + handwriting-OCR search across Hebrew and English.
struct LibraryView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Subject"]!,
        sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)],
        predicate: NSPredicate(format: "parent == nil")
    ) private var rootSubjects: FetchedResults<Subject>

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: []
    ) private var allNotesForCounts: FetchedResults<Note>

    @State private var selectedSubject: Subject?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var searchText = ""
    @AppStorage("library.layout.grid") private var gridLayout = true
    @AppStorage("library.sort") private var sortRaw = LibrarySort.dateModified.rawValue
    @State private var showSettings = false
    @State private var renamingSubject: Subject?
    @State private var renameText = ""
    @State private var autoOpenNote: Note?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NoteGridView(
                subject: selectedSubject,
                searchText: searchText,
                gridLayout: gridLayout,
                sort: LibrarySort(rawValue: sortRaw) ?? .dateModified,
                onNoteOpened: {
                    // The canvas deserves the whole screen.
                    withAnimation { columnVisibility = .detailOnly }
                }
            )
            .navigationTitle(selectedSubject?.name.map { Text(verbatim: $0) } ?? Text("library.allNotes"))
            .toolbar { detailToolbar }
            // The toolbar's New Note goes straight into the editor.
            .navigationDestination(isPresented: Binding(
                get: { autoOpenNote != nil },
                set: { if !$0 { autoOpenNote = nil } }
            )) {
                if let note = autoOpenNote {
                    NoteEditorView(note: note)
                        .onAppear { withAnimation { columnVisibility = .detailOnly } }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert(Text("library.renameSubject"), isPresented: renamingBinding) {
            TextField("library.subjectName", text: $renameText)
            Button("action.cancel", role: .cancel) { renamingSubject = nil }
            Button("action.done") {
                renamingSubject?.name = renameText
                PersistenceController.shared.save()
                renamingSubject = nil
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingSubject != nil }, set: { if !$0 { renamingSubject = nil } })
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Explicit selection buttons: List(selection:) silently stopped
        // selecting once rows became custom HStacks.
        List {
            Section {
                Button {
                    selectedSubject = nil
                } label: {
                    HStack(spacing: 10) {
                        iconTile(systemName: "tray.full.fill", tint: Color("accentBlue"))
                        Text("library.allNotes")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        countBadge(allNotesForCounts.count)
                    }
                }
                .listRowBackground(selectedSubject == nil ? Color.accentColor.opacity(0.14) : nil)
            }
            Section(header: Text("library.subjects").font(.caption.smallCaps()).foregroundStyle(.secondary)) {
                ForEach(rootSubjects, id: \.objectID) { subject in
                    subjectRows(subject, depth: 0)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("library.searchPrompt"))
        .scrollContentBackground(.hidden)
        .background(SemanticColor.sidebarBackground)
        .navigationTitle(Text("app.name"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { addSubject(kind: "folder") } label: { Label("library.newSubject", systemImage: "folder.badge.plus") }
                    Button { addSubject(kind: "divider") } label: { Label("library.newDivider", systemImage: "minus") }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("settings.title"))
            }
        }
    }

    @ViewBuilder
    private func subjectRows(_ subject: Subject, depth: Int) -> AnyView {
        AnyView(
            Group {
                subjectRow(subject, depth: depth)
                ForEach(sortedChildren(of: subject), id: \.objectID) { child in
                    subjectRows(child, depth: depth + 1)
                }
            }
        )
    }

    @ViewBuilder
    private func subjectRow(_ subject: Subject, depth: Int) -> some View {
        if subject.isDivider {
            HStack {
                Text(verbatim: subject.name ?? "")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .contextMenu { subjectContextMenu(subject) }
        } else {
            Button {
                selectedSubject = subject
            } label: {
                HStack(spacing: 10) {
                    iconTile(systemName: "folder.fill", tint: Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                    Text(verbatim: subject.name ?? "")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    countBadge(subject.notes?.count ?? 0)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .listRowBackground(selectedSubject == subject ? Color.accentColor.opacity(0.14) : nil)
            .contextMenu { subjectContextMenu(subject) }
            .dropDestination(for: String.self) { ids, _ in
                moveNotes(ids: ids, to: subject)
            }
        }
    }

    /// Squircle gradient tile behind a white symbol — the sidebar's visual anchor.
    private func iconTile(systemName: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
    }

    private func countBadge(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    @ViewBuilder
    private func subjectContextMenu(_ subject: Subject) -> some View {
        Button {
            renameText = subject.name ?? ""
            renamingSubject = subject
        } label: { Label("action.rename", systemImage: "pencil") }

        if !subject.isDivider {
            Menu {
                ForEach(["#0A84FF", "#FF453A", "#30D158", "#FFD60A", "#FF9F0A", "#BF5AF2", "#8E8E93"], id: \.self) { hex in
                    Button {
                        subject.colorHex = hex
                        PersistenceController.shared.save()
                    } label: {
                        Label(hex, systemImage: subject.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: { Label("library.subjectColor", systemImage: "paintpalette") }

            Button { addSubject(kind: "folder", parent: subject) } label: {
                Label("library.newNestedSubject", systemImage: "folder.badge.plus")
            }
        }

        Button(role: .destructive) {
            context.delete(subject)
            if selectedSubject == subject { selectedSubject = nil }
            PersistenceController.shared.save()
        } label: { Label("action.delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: addNote) { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(Text("library.newNote"))
            Menu {
                Picker("library.sort", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases, id: \.rawValue) { sort in
                        Text(sort.labelKey).tag(sort.rawValue)
                    }
                }
                Divider()
                Picker("library.layout", selection: $gridLayout) {
                    Label("library.layout.grid", systemImage: "square.grid.2x2").tag(true)
                    Label("library.layout.list", systemImage: "list.bullet").tag(false)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel(Text("library.sort"))
        }
    }

    // MARK: - Actions

    private func sortedChildren(of subject: Subject) -> [Subject] {
        (subject.children ?? []).sorted {
            ($0.sortIndex, $0.createdAt ?? .distantPast) < ($1.sortIndex, $1.createdAt ?? .distantPast)
        }
    }

    private func addSubject(kind: String, parent: Subject? = nil) {
        let baseName = kind == "divider" ? String(localized: "library.newDividerName") : String(localized: "library.newSubjectName")
        Subject.create(in: context, name: baseName, kind: kind, parent: parent)
        PersistenceController.shared.save()
    }

    private func addNote() {
        let note = Note.create(in: context, title: String(localized: "library.untitledNote"), subject: selectedSubject)
        PersistenceController.shared.save()
        autoOpenNote = note
    }

    private func moveNotes(ids: [String], to subject: Subject) -> Bool {
        let request = NSFetchRequest<Note>(entityName: "Note")
        let uuids = ids.compactMap(UUID.init)
        guard !uuids.isEmpty else { return false }
        request.predicate = NSPredicate(format: "id IN %@", uuids)
        guard let notes = try? context.fetch(request), !notes.isEmpty else { return false }
        for note in notes { note.subject = subject }
        PersistenceController.shared.save()
        return true
    }
}
