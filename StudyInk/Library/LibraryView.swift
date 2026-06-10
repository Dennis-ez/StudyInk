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

    @State private var selectedSubject: Subject?
    @State private var searchText = ""
    @AppStorage("library.layout.grid") private var gridLayout = true
    @AppStorage("library.sort") private var sortRaw = LibrarySort.dateModified.rawValue
    @State private var showSettings = false
    @State private var renamingSubject: Subject?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NoteGridView(
                subject: selectedSubject,
                searchText: searchText,
                gridLayout: gridLayout,
                sort: LibrarySort(rawValue: sortRaw) ?? .dateModified
            )
            .navigationTitle(selectedSubject?.name.map { Text(verbatim: $0) } ?? Text("library.allNotes"))
            .toolbar { detailToolbar }
        }
        .searchable(text: $searchText, prompt: Text("library.searchPrompt"))
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
        List(selection: $selectedSubject) {
            Section {
                Label("library.allNotes", systemImage: "tray.full")
                    .tag(nil as Subject?)
            }
            Section(header: Text("library.subjects")) {
                ForEach(rootSubjects, id: \.objectID) { subject in
                    subjectRows(subject, depth: 0)
                }
            }
        }
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
            Label {
                Text(verbatim: subject.name ?? "")
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .tag(subject as Subject?)
            .contextMenu { subjectContextMenu(subject) }
            .dropDestination(for: String.self) { ids, _ in
                moveNotes(ids: ids, to: subject)
            }
        }
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
        _ = note
        PersistenceController.shared.save()
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
