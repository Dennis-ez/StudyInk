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

/// What the note grid is showing: a smart section or one subject.
enum LibrarySection: Hashable {
    case all, recents, favorites, deleted
    case subject(Subject)

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: return "library.allNotes"
        case .recents: return "library.recents"
        case .favorites: return "library.favorites"
        case .deleted: return "library.recentlyDeleted"
        case .subject: return "library.allNotes" // unused — subject rows show their name
        }
    }
}

/// The home screen: smart sections + subjects (folders + dividers) in the
/// sidebar, notes in a grid or list, full-text + handwriting-OCR search.
struct LibraryView: View {
    @Environment(\.managedObjectContext) private var context
    // ALL subjects, not just roots: the fetch request is what makes SwiftUI
    // re-render — fetching only roots meant a nested folder's color change
    // never refreshed until its parent collapsed/expanded.
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Subject"]!,
        sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)]
    ) private var allSubjects: FetchedResults<Subject>

    private var rootSubjects: [Subject] { allSubjects.filter { $0.parent == nil } }

    // NSFetchedResultsController needs at least one sort descriptor to track
    // changes — with [] the badge counts (Recently Deleted especially) went
    // stale until the section was re-entered.
    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotesForCounts: FetchedResults<Note>

    @State private var selection: LibrarySection = .all
    /// Subjects whose children are hidden in the sidebar.
    @State private var collapsedSubjects: Set<NSManagedObjectID> = []
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
            // Explicit stack: navigationDestination/push inside a split view's
            // detail column needs one, or it targets a non-existent next column
            // (console was full of "navigationDestination is misplaced").
            NavigationStack {
                NoteGridView(
                    section: selection,
                    searchText: searchText,
                    gridLayout: gridLayout,
                    sort: LibrarySort(rawValue: sortRaw) ?? .dateModified,
                    onNoteOpened: {
                        // The canvas deserves the whole screen.
                        withAnimation { columnVisibility = .detailOnly }
                    },
                    onNoteClosed: {
                        withAnimation { columnVisibility = .all }
                    }
                )
                .navigationTitle(detailTitle)
                .toolbar { detailToolbar }
                // The toolbar's New Note goes straight into the editor.
                .navigationDestination(isPresented: Binding(
                    get: { autoOpenNote != nil },
                    set: { if !$0 { autoOpenNote = nil } }
                )) {
                    if let note = autoOpenNote {
                        NoteEditorContainer(note: note)
                            .onAppear { withAnimation { columnVisibility = .detailOnly } }
                            .onDisappear { withAnimation { columnVisibility = .all } }
                    }
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
        .onAppear(perform: purgeExpiredNotes)
    }

    private var detailTitle: Text {
        if case .subject(let subject) = selection, let name = subject.name {
            return Text(verbatim: name)
        }
        return Text(selection.titleKey)
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingSubject != nil }, set: { if !$0 { renamingSubject = nil } })
    }

    // MARK: - Counts

    private var activeNotes: [Note] { allNotesForCounts.filter { $0.deletedAt == nil } }
    private var deletedCount: Int { allNotesForCounts.count(where: { $0.deletedAt != nil }) }
    private var favoritesCount: Int { activeNotes.count(where: \.isFavorite) }
    private var recentsCount: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return activeNotes.count(where: { ($0.modifiedAt ?? .distantPast) > cutoff })
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Explicit selection buttons: List(selection:) silently stopped
        // selecting once rows became custom HStacks.
        List {
            Section {
                // One tint across the smart sections — the sidebar reads as a
                // set, not a rainbow.
                sectionRow(.all, systemName: "tray.full.fill", count: activeNotes.count)
                sectionRow(.recents, systemName: "clock.fill", count: recentsCount)
                sectionRow(.favorites, systemName: "star.fill", count: favoritesCount)
            }
            Section(header: Text("library.subjects").font(.caption.smallCaps()).foregroundStyle(.secondary)) {
                ForEach(rootSubjects, id: \.objectID) { subject in
                    subjectRows(subject, depth: 0)
                }
            }
            Section {
                sectionRow(.deleted, systemName: "trash.fill", count: deletedCount)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("library.searchPrompt"))
        .scrollContentBackground(.hidden)
        .background(SemanticColor.sidebarBackground)
        // The sidebar is the library's spine — it can't be hidden from the
        // main screen (the editor still takes the full screen when a note opens).
        .hideSidebarToggle()
        // No app-name header — the sidebar speaks for itself.
        .toolbarTitleDisplayMode(.inline)
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

    private func sectionRow(_ section: LibrarySection, systemName: String, count: Int) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                iconTile(systemName: systemName, tint: .accentColor)
                Text(section.titleKey)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                countBadge(count)
            }
        }
        .listRowBackground(selection == section ? roundedRowBackground(Color.accentColor.opacity(0.14)) : nil)
    }

    private func roundedRowBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func subjectRows(_ subject: Subject, depth: Int) -> AnyView {
        AnyView(
            Group {
                subjectRow(subject, depth: depth)
                if !collapsedSubjects.contains(subject.objectID) {
                    ForEach(sortedChildren(of: subject), id: \.objectID) { child in
                        subjectRows(child, depth: depth + 1)
                    }
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
            .contentShape(Rectangle())
            .draggable("subject:\(subject.id?.uuidString ?? "")")
            .contextMenu { subjectContextMenu(subject) }
        } else {
            let tint = Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor
            let isSelected = selection == .subject(subject)
            Button {
                selection = .subject(subject)
            } label: {
                HStack(spacing: 10) {
                    iconTile(systemName: "folder.fill", tint: tint)
                    Text(verbatim: subject.name ?? "")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    countBadge(activeCount(of: subject))
                    if !(subject.children?.isEmpty ?? true) {
                        // Collapse/expand chevron — a separate tap target from the row.
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                if !collapsedSubjects.insert(subject.objectID).inserted {
                                    collapsedSubjects.remove(subject.objectID)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(collapsedSubjects.contains(subject.objectID) ? -90 : 0))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("library.toggleChildren"))
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            // Subject rows carry their color as a soft wash; selection darkens
            // it. Rounded so the wash doesn't end in hard edges.
            .listRowBackground(roundedRowBackground(tint.opacity(isSelected ? 0.26 : 0.10)))
            .draggable("subject:\(subject.id?.uuidString ?? "")")
            .contextMenu { subjectContextMenu(subject) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteSubject(subject)
                } label: { Label("action.delete", systemImage: "trash") }
                    // Explicit red — the app-wide accent tint overrides the
                    // destructive role's background.
                    .tint(Color("errorRed"))
            }
            // Accepts notes (to file them) and subjects/dividers (to nest them).
            .dropDestination(for: String.self) { ids, _ in
                handleDrop(ids, into: subject)
            }
        }
    }

    /// Drop payloads: plain note UUIDs file notes; "subject:" prefixed UUIDs
    /// reparent folders/dividers (cycles rejected).
    private func handleDrop(_ items: [String], into target: Subject) -> Bool {
        var changed = false
        var noteIDs: [String] = []
        for item in items {
            if item.hasPrefix("subject:") {
                let uuid = String(item.dropFirst("subject:".count))
                if let dragged = allSubjects.first(where: { $0.id?.uuidString == uuid }),
                   canNest(dragged, into: target) {
                    withAnimation { dragged.parent = target }
                    changed = true
                }
            } else {
                noteIDs.append(item)
            }
        }
        if !noteIDs.isEmpty {
            changed = moveNotes(ids: noteIDs, to: target) || changed
        }
        if changed { PersistenceController.shared.save() }
        return changed
    }

    /// A subject can't be nested into itself or any of its descendants.
    private func canNest(_ dragged: Subject, into target: Subject) -> Bool {
        guard !target.isDivider else { return false }
        var node: Subject? = target
        while let current = node {
            if current == dragged { return false }
            node = current.parent
        }
        return true
    }

    /// Plain tinted glyph — sidebar rows read lighter without tile backgrounds.
    private func iconTile(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
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
                ForEach(Self.subjectColors, id: \.hex) { option in
                    Button {
                        subject.colorHex = option.hex
                        PersistenceController.shared.save()
                    } label: {
                        Label {
                            Text(LocalizedStringKey(option.nameKey))
                        } icon: {
                            // .alwaysOriginal keeps the real color inside the
                            // menu — template rendering made every dot gray.
                            Image(uiImage: Self.swatchImage(hex: option.hex, selected: subject.colorHex == option.hex))
                        }
                    }
                }
            } label: { Label("library.subjectColor", systemImage: "paintpalette") }

            Button { addSubject(kind: "folder", parent: subject) } label: {
                Label("library.newNestedSubject", systemImage: "folder.badge.plus")
            }
        }

        Button(role: .destructive) {
            deleteSubject(subject)
        } label: { Label("action.delete", systemImage: "trash") }
    }

    /// Deleting a folder takes its whole subtree: notes (own and nested) go
    /// to Recently Deleted; subfolders go with the parent instead of popping
    /// out as new roots (the nullify delete rule made children "replace" the
    /// deleted parent).
    private func deleteSubject(_ subject: Subject) {
        softDelete(subject)
        if case .subject(let selected) = selection, selected.isDeleted || selected == subject {
            selection = .all
        }
        PersistenceController.shared.save()
    }

    private func softDelete(_ subject: Subject) {
        for note in subject.notes ?? [] { note.deletedAt = Date() }
        for child in subject.children ?? [] { softDelete(child) }
        context.delete(subject)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selection != .deleted {
                Button(action: addNote) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(Text("library.newNote"))
            }
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

    private func activeCount(of subject: Subject) -> Int {
        (subject.notes ?? []).count(where: { $0.deletedAt == nil })
    }

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
        var subject: Subject?
        if case .subject(let s) = selection { subject = s }
        let note = Note.create(in: context, title: String(localized: "library.untitledNote"), subject: subject)
        if selection == .favorites { note.isFavorite = true }
        PersistenceController.shared.save()
        autoOpenNote = note
    }

    /// Recently Deleted is a 30-day grace period, not an archive.
    private func purgeExpiredNotes() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let expired = allNotesForCounts.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(context.delete)
        PersistenceController.shared.save()
    }

    /// Named subject colors (the old menu showed raw hex strings, and menu
    /// template rendering made every swatch the same gray).
    private static let subjectColors: [(hex: String, nameKey: String)] = [
        ("#0A84FF", "subjectColor.blue"),
        ("#FF453A", "subjectColor.red"),
        ("#30D158", "subjectColor.green"),
        ("#FFD60A", "subjectColor.yellow"),
        ("#FF9F0A", "subjectColor.orange"),
        ("#BF5AF2", "subjectColor.purple"),
        ("#8E8E93", "subjectColor.gray"),
    ]

    private static func swatchImage(hex: String, selected: Bool) -> UIImage {
        let color = UIColor(hex: hex) ?? .systemBlue
        let name = selected ? "checkmark.circle.fill" : "circle.fill"
        return (UIImage(systemName: name) ?? UIImage())
            .withTintColor(color, renderingMode: .alwaysOriginal)
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

private extension View {
    /// Removes the system sidebar-toggle button (iOS 17.4+); earlier systems
    /// keep it — there's no public API to remove it there.
    @ViewBuilder
    func hideSidebarToggle() -> some View {
        if #available(iOS 17.4, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
