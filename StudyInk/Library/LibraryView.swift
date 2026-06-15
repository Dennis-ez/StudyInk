import SwiftUI
import CoreData
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable {
    case dateModified, name, createdDate

    var labelKey: LocalizedStringKey {
        switch self {
        case .dateModified: return "library.sort.date"
        case .name: return "library.sort.name"
        case .createdDate: return "library.sort.created"
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
    @Environment(\.themePaper) private var themePaper
    @Environment(\.themeSidebar) private var themeSidebar
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
    @State private var importingPDF = false
    @State private var renamingSubject: Subject?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var autoOpenNote: Note?
    /// Set by delete actions; the confirmation alert commits or clears it.
    @State private var subjectPendingDelete: Subject?
    /// Multi-select mode, entered from the ⋯ menu.
    @State private var selectingNotes = false

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
                    selecting: $selectingNotes,
                    onNoteOpened: {
                        // The canvas deserves the whole screen.
                        withAnimation { columnVisibility = .detailOnly }
                    },
                    onNoteClosed: {
                        // Instant — animating left the sidebar missing for a
                        // beat after returning from the editor.
                        columnVisibility = .all
                    }
                )
                // The big title lives in the content (serif); keep the bar for
                // the action buttons only, transparent over the warm paper.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { detailToolbar }
                .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
                    if case .success(let url) = result { importPDFAsNote(from: url) }
                }
                // The toolbar's New Note goes straight into the editor.
                .navigationDestination(isPresented: Binding(
                    get: { autoOpenNote != nil },
                    set: { if !$0 { autoOpenNote = nil } }
                )) {
                    if let note = autoOpenNote {
                        NoteEditorContainer(note: note)
                            .onAppear { withAnimation { columnVisibility = .detailOnly } }
                            .onDisappear { columnVisibility = .all }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear(perform: purgeExpiredNotes)
        .alert(Text("library.deleteSubject.confirm"), isPresented: Binding(
            get: { subjectPendingDelete != nil },
            set: { if !$0 { subjectPendingDelete = nil } }
        )) {
            Button("action.cancel", role: .cancel) { subjectPendingDelete = nil }
            Button("action.delete", role: .destructive) {
                if let subject = subjectPendingDelete { deleteSubject(subject) }
                subjectPendingDelete = nil
            }
        } message: {
            Text("library.deleteSubject.message")
        }
    }

    private var detailTitle: Text {
        if case .subject(let subject) = selection, let name = subject.name {
            return Text(verbatim: name)
        }
        return Text(selection.titleKey)
    }

    private func commitInlineRename() {
        guard let subject = renamingSubject else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            subject.name = trimmed
            PersistenceController.shared.save()
        }
        renamingSubject = nil
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
            // Wordmark: the app-icon mark (accent square + drop) + serif name.
            HStack(spacing: 10) {
                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(verbatim: "StudyInk")
                    .font(.fraunces(22, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 2)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Search — a rounded paper field, not the system search bar.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                TextField("library.searchPrompt", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(themePaper, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.black.opacity(0.06)))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                // One tint across the smart sections — the sidebar reads as a
                // set, not a rainbow.
                sectionRow(.all, systemName: "tray.full", count: activeNotes.count)
                sectionRow(.recents, systemName: "clock", count: recentsCount)
                sectionRow(.favorites, systemName: "star", count: favoritesCount)
            }
            Section(header:
                HStack {
                    Text("library.subjects").font(.caption.smallCaps()).foregroundStyle(.secondary)
                    Spacer()
                    // New folder/divider lives next to its section title.
                    Menu {
                        Button { addSubject(kind: "folder") } label: { Label("library.newSubject", systemImage: "folder.badge.plus") }
                        Button { addSubject(kind: "divider") } label: { Label("library.newDivider", systemImage: "minus") }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.subheadline)
                    }
                    .accessibilityLabel(Text("library.newSubject"))
                }
                // Dropping a nested folder/divider on the header pulls it out
                // to the top level.
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    var changed = false
                    for item in ids where item.hasPrefix("subject:") {
                        let uuid = String(item.dropFirst("subject:".count))
                        if let dragged = allSubjects.first(where: { $0.id?.uuidString == uuid }), dragged.parent != nil {
                            withAnimation { dragged.parent = nil }
                            changed = true
                        }
                    }
                    if changed { PersistenceController.shared.save() }
                    return changed
                }
            ) {
                ForEach(rootSubjects, id: \.objectID) { subject in
                    subjectRows(subject, depth: 0)
                }
            }
            Section {
                sectionRow(.deleted, systemName: "trash", count: deletedCount)
            }
        }
        .scrollContentBackground(.hidden)
        // Plain (not .sidebar) = edge-to-edge rows with no grouped inset, so the
        // warm panel reads as a full-bleed spine.
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        // Full-bleed, full-height warm sidebar (no floating-panel inset).
        .background(themeSidebar.ignoresSafeArea())
        // Settings pinned to the very bottom of the sidebar (Paper & Ink).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { showSettings = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 22)
                    Text("settings.title").font(.subheadline.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(themeSidebar.ignoresSafeArea())
        }
        // The sidebar is the library's spine — it can't be hidden from the
        // main screen (the editor still takes the full screen when a note opens).
        .hideSidebarToggle()
        // Single fixed width = the user can't drag-resize the sidebar.
        .navigationSplitViewColumnWidth(280)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func sectionRow(_ section: LibrarySection, systemName: String, count: Int) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 16))
                    .frame(width: 22)
                Text(section.titleKey)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(SidebarRowButtonStyle())
        .listRowBackground(roundedRowBackground(selected ? Color.accentColor : .clear))
        .listRowSeparator(.hidden)
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
                    .listRowSeparator(.hidden)
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
        if renamingSubject == subject {
            // Inline rename, right in the row — no popup. Focus lands
            // immediately so the keyboard comes up with it.
            HStack(spacing: 10) {
                if !subject.isDivider {
                    Circle()
                        .fill(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                        .frame(width: 13, height: 13)
                        .frame(width: 30, height: 30)
                }
                TextField("library.subjectName", text: $renameText)
                    .focused($renameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(commitInlineRename)
            }
            .padding(.leading, CGFloat(depth) * 20)
            // Focus on the next runloop so the field is in the responder chain
            // first — otherwise the keyboard doesn't come up for a just-added
            // subject (the row is still being inserted when onAppear fires).
            .onAppear { DispatchQueue.main.async { renameFieldFocused = true } }
            .onChange(of: renameFieldFocused) { _, focused in
                // Tapping away commits too — never strand an unnamed folder.
                if !focused { commitInlineRename() }
            }
        } else if subject.isDivider {
            HStack {
                Text(verbatim: subject.name ?? "")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.leading, CGFloat(depth) * 20)
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
                    // The subject IS its color — a plain dot, not a folder glyph.
                    Circle()
                        .fill(tint)
                        .frame(width: 13, height: 13)
                        .frame(width: 30, height: 30)
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
            .padding(.leading, CGFloat(depth) * 20)
            // Subject rows carry their color as a soft wash; selection darkens
            // it. Rounded, and indented WITH the row so nesting reads as a tree.
            .listRowBackground(
                roundedRowBackground(tint.opacity(isSelected ? 0.38 : 0.18))
                    .padding(.leading, CGFloat(depth) * 20)
            )
            .draggable("subject:\(subject.id?.uuidString ?? "")")
            .contextMenu { subjectContextMenu(subject) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    subjectPendingDelete = subject
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

    private func siblings(of subject: Subject) -> [Subject]? {
        let pool = subject.parent.map { sortedChildren(of: $0) } ?? rootSubjects
        return pool.isEmpty ? nil : pool
    }

    private func siblingIndex(of subject: Subject) -> Int {
        siblings(of: subject)?.firstIndex(of: subject) ?? 0
    }

    /// Swap sort positions with the neighbor `offset` away (±1), normalizing
    /// sortIndex across the sibling group so future moves stay stable.
    private func moveAmongSiblings(_ subject: Subject, by offset: Int) {
        guard var pool = siblings(of: subject),
              let index = pool.firstIndex(of: subject),
              pool.indices.contains(index + offset) else { return }
        pool.swapAt(index, index + offset)
        withAnimation {
            for (position, sibling) in pool.enumerated() {
                sibling.sortIndex = Int32(position)
            }
            PersistenceController.shared.save()
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

        // Reorder among siblings (sortIndex swap, animated).
        if siblingIndex(of: subject) > 0 {
            Button {
                moveAmongSiblings(subject, by: -1)
            } label: { Label("library.moveUp", systemImage: "arrow.up") }
        }
        if let siblings = siblings(of: subject), siblingIndex(of: subject) < siblings.count - 1 {
            Button {
                moveAmongSiblings(subject, by: 1)
            } label: { Label("library.moveDown", systemImage: "arrow.down") }
        }
        if subject.parent != nil {
            Button {
                withAnimation {
                    subject.parent = subject.parent?.parent
                    PersistenceController.shared.save()
                }
            } label: { Label("library.moveOut", systemImage: "arrow.up.left") }
        }

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
            subjectPendingDelete = subject
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
        // Rightmost: New Note. To its left: the ⋯ menu with view toggle,
        // Select Notes, and a Sort By submenu showing the current choice.
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    gridLayout.toggle()
                } label: {
                    Label(
                        gridLayout ? "library.layout.list" : "library.layout.grid",
                        systemImage: gridLayout ? "list.bullet" : "square.grid.2x2"
                    )
                }
                Button {
                    selectingNotes = true
                } label: { Label("library.selectNotes", systemImage: "checkmark.circle") }
                if selection != .deleted {
                    Button {
                        importingPDF = true
                    } label: { Label("media.importPDF", systemImage: "doc.badge.plus") }
                }
                Menu {
                    Picker("library.sort", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases, id: \.rawValue) { sort in
                            Text(sort.labelKey).tag(sort.rawValue)
                        }
                    }
                } label: {
                    Label("library.sort", systemImage: "arrow.up.arrow.down")
                    Text((LibrarySort(rawValue: sortRaw) ?? .dateModified).labelKey)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .background(themePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
            }
            .accessibilityLabel(Text("library.sort"))

            if selection != .deleted {
                // Ask AI — a prominent pill that starts a new note (the AI lives
                // in the editor). Matches the Paper & Ink header.
                Button(action: addNote) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("ai.ask")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("ai.ask"))

                Button(action: addNote) {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 32, height: 32)
                        .background(themePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("library.newNote"))
            }
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

    /// Import a PDF as a brand-new note (each PDF page → a note page).
    private func importPDFAsNote(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        var subject: Subject?
        if case .subject(let s) = selection { subject = s }
        let title = url.deletingPathExtension().lastPathComponent
        let note = Note.create(in: context, title: title, subject: subject)
        // Import after the default blank page, then drop the blank.
        PDFImporter.importAsPages(data: data, into: note, after: 0)
        if note.sortedPages.count > 1, let blank = note.sortedPages.first {
            note.deletePage(blank)
        }
        note.searchableText = SearchableTextBuilder.build(for: note)
        PersistenceController.shared.save()
        autoOpenNote = note
    }

    private func addSubject(kind: String, parent: Subject? = nil) {
        let baseName = kind == "divider" ? String(localized: "library.newDividerName") : String(localized: "library.newSubjectName")
        // Pick a color no existing subject uses yet; once the palette is
        // exhausted, any of it at random.
        let used = Set(allSubjects.compactMap(\.colorHex))
        let palette = Self.subjectColors.map(\.hex)
        let color = palette.filter { !used.contains($0) }.randomElement()
            ?? palette.randomElement() ?? "#0A84FF"
        let subject = Subject.create(in: context, name: baseName, colorHex: color, kind: kind, parent: parent)
        PersistenceController.shared.save()
        // Straight into naming — start EMPTY so the user types over nothing,
        // not the "New Subject" placeholder (commit keeps baseName if blank).
        renameText = ""
        renamingSubject = subject
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
