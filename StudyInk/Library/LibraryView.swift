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

/// Reliable drop target for the sidebar (drag a subject/divider — or a note from
/// the grid — onto a row to nest/file it). Reads the payload from the drop's item
/// providers, so it works no matter where the drag started (.dropDestination on
/// List rows was flaky).
struct SidebarDropDelegate: DropDelegate {
    let onDrop: ([String]) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.text, UTType.plainText, UTType.utf8PlainText])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let id = obj as? String else { return }
                DispatchQueue.main.async { _ = onDrop([id]) }
            }
        }
        return true
    }
}

/// Where a drop lands relative to a subject row: near the top/bottom edge =
/// reorder before/after it; the middle = nest INSIDE it (Finder-style).
enum SubjectDropZone { case before, after, inside }

struct SubjectDropHint: Equatable {
    let target: NSManagedObjectID
    let zone: SubjectDropZone
}

/// Reliable reorder + nest for a subject row laid out in a plain VStack (NOT a
/// List row — List rows swallow custom drops). Reads the drop's Y to pick the
/// zone and loads the payload from the item providers, so a subject dragged from
/// the sidebar AND a note dragged from the grid both land correctly.
struct SubjectRowDropDelegate: DropDelegate {
    let targetID: NSManagedObjectID
    let rowHeight: CGFloat
    @Binding var hint: SubjectDropHint?
    let perform: (String, SubjectDropZone) -> Bool

    private func zone(_ info: DropInfo) -> SubjectDropZone {
        let y = info.location.y
        if y < rowHeight * 0.28 { return .before }
        if y > rowHeight * 0.72 { return .after }
        return .inside
    }
    func dropEntered(info: DropInfo) { hint = SubjectDropHint(target: targetID, zone: zone(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hint = SubjectDropHint(target: targetID, zone: zone(info))
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if hint?.target == targetID { hint = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let z = zone(info)
        hint = nil
        let providers = info.itemProviders(for: [UTType.text, UTType.plainText, UTType.utf8PlainText])
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = obj as? String else { return }
            DispatchQueue.main.async { _ = perform(id, z) }
        }
        return true
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
    /// Live drop indicator while dragging a subject/note over the sidebar tree.
    @State private var dropHint: SubjectDropHint?
    /// Subjects whose children are hidden in the sidebar.
    @State private var collapsedSubjects: Set<NSManagedObjectID> = []
    /// Collapses the sidebar column so the editor takes the whole screen.
    @State private var sidebarCollapsed = false
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
        // A real grid shell (non-negotiable #1): the sidebar is a fixed,
        // full-bleed column flush at the leading edge — NOT NavigationSplitView's
        // iOS 26 Liquid-Glass floating column. It collapses to give the editor
        // the whole screen.
        HStack(spacing: 0) {
            // Always in the hierarchy (just width-collapsed when a note is open)
            // so it's present the instant you return — no re-insertion delay.
            sidebar
                .frame(width: sidebarCollapsed ? 0 : 264)
                .clipped()
            Rectangle()
                .fill(SemanticColor.separator)
                .frame(width: sidebarCollapsed ? 0 : 1)
                .ignoresSafeArea()
            // The content column owns navigation (grid → editor push).
            NavigationStack {
                NoteGridView(
                    section: selection,
                    searchText: searchText,
                    gridLayout: $gridLayout,
                    sortRaw: $sortRaw,
                    selecting: $selectingNotes,
                    onNoteOpened: {
                        // Collapse the spine INSTANTLY (no animation) so the content
                        // column is already full width when the editor pushes in —
                        // otherwise the desk flashes in a strip on the right.
                        withAnimation(nil) { sidebarCollapsed = true }
                    },
                    onNoteClosed: {
                        sidebarCollapsed = false
                    },
                    onNewNote: addNote,
                    onImportPDF: { importingPDF = true },
                    onOpenFolder: { folder in
                        withAnimation(.snappy(duration: 0.2)) {
                            selection = folder.map { .subject($0) } ?? .all
                        }
                    }
                )
                // The title AND the action cluster live in the content header
                // now; the nav bar only appears to host the multi-select tools.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar(selectingNotes ? .visible : .hidden, for: .navigationBar)
                .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
                    if case .success(let url) = result { importPDFAsNote(from: url) }
                }
                // The toolbar's New Note opens the editor full-screen (window
                // level) — same as tapping a note — so no sidebar collapse needed.
                .fullScreenCover(isPresented: Binding(
                    get: { autoOpenNote != nil },
                    set: { if !$0 { autoOpenNote = nil } }
                )) {
                    if let note = autoOpenNote {
                        NoteEditorContainer(note: note)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The sidebar's own fill is clipped to the safe area by the width-collapse
        // .clipped(), leaving the top/bottom safe-area gaps showing themePaper.
        // Paint the sidebar colour full-height behind the leading column so the
        // whole spine is one uniform colour.
        .background(alignment: .leading) {
            themeSidebar
                .frame(width: sidebarCollapsed ? 0 : 264)
                .ignoresSafeArea()
        }
        .background(themePaper.ignoresSafeArea())
        .fullScreenCover(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            purgeExpiredNotes()
            // One-time: give existing notes a tree position alongside folders.
            FileTree.backfillSortIndexIfNeeded(PersistenceController.shared.viewContext)
        }
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
        // Opaque warm spine behind the rows — covers the iOS 26 Liquid Glass
        // sidebar material so it reads as a solid, full-height panel.
        ZStack {
            themeSidebar.ignoresSafeArea()
            // A ScrollView + LazyVStack, NOT a List: List rows swallow custom
            // .onDrop (only .onMove fires), which is why dragging a subject into
            // another never worked. Plain stacked rows behave like the grid, so
            // reorder/nest drops fire — and the row heights are ours to set.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {

                    // Search — a rounded paper field with a ⌘K hint chip.
                    HStack(spacing: DS.Space.sm) {
                        Lucide("search", size: 16).foregroundStyle(.secondary)
                        TextField("library.searchPrompt", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.callout)
                        if searchText.isEmpty {
                            Text(verbatim: "⌘K")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(SemanticColor.separator.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        } else {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                    }
                    .frame(height: 38)
                    .padding(.horizontal, DS.Space.md)
                    .background(themePaper, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SemanticColor.separator))
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    sectionRow(.all, lucide: "layers", count: activeNotes.count)

                    // Subjects header — title + new-folder menu; drop here to un-nest.
                    HStack {
                        Text("library.subjects")
                            .font(.system(size: 11.5, weight: .bold))
                            .tracking(1.1)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button { addSubject(kind: "folder") } label: { Label("library.newSubject", systemImage: "folder.badge.plus") }
                            Button { addSubject(kind: "divider") } label: { Label("library.newDivider", systemImage: "minus") }
                        } label: {
                            Lucide("plus", size: 16)
                        }
                        .accessibilityLabel(Text("library.newSubject"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: SidebarDropDelegate { ids in
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
                    })

                    // Subject rows flush against each other (no inter-row gap).
                    VStack(spacing: 0) {
                        ForEach(rootSubjects, id: \.objectID) { subject in
                            subjectRows(subject, depth: 0)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            // Settings pinned to the very bottom of the sidebar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button { showSettings = true } label: {
                    HStack(spacing: 11) {
                        Lucide("settings", size: 16).frame(width: 22)
                        Text("settings.title").font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                // Opaque sidebar fill + a top hairline so scrolling rows pass
                // BEHIND the pinned button instead of bleeding through it.
                .background(alignment: .top) {
                    themeSidebar
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) {
                            Rectangle().fill(SemanticColor.separator).frame(height: 0.5)
                        }
                }
            }
        }
    }

    private func sectionRow(_ section: LibrarySection, lucide: String, count: Int) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 11) {
                Lucide(lucide, size: 19)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(section.titleKey)
                    .font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(SidebarRowButtonStyle())
        // Selected = subtle fill + a 3pt accent bar inset at the leading edge.
        .background(
            roundedRowBackground(selected ? SemanticColor.fillSelected : .clear)
                .overlay(alignment: .leading) {
                    if selected {
                        // Flush at the sidebar's leading edge (per the design).
                        Rectangle().fill(Color.accentColor)
                            .frame(width: 3)
                    }
                }
        )
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
            VStack(spacing: 0) {
                subjectRow(subject, depth: depth)
                if !collapsedSubjects.contains(subject.objectID) {
                    ForEach(sortedChildren(of: subject), id: \.objectID) { child in
                        subjectRows(child, depth: depth + 1)
                    }
                }
            }
        )
    }

    /// Row chrome shared by every subject/divider row now that the tree is a plain
    /// VStack (not List rows): a fixed-height capsule fill + the live drop indicator
    /// (a ring for nest, a bar for reorder), plus the reliable reorder/nest drop.
    private func subjectRowChrome<V: View>(_ subject: Subject, depth: Int, fill: Color, @ViewBuilder _ content: () -> V) -> some View {
        let inset = CGFloat(depth) * 20
        return content()
            .padding(.horizontal, 12)        // content inset (List used to provide this)
            .padding(.leading, inset)        // tree indent
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            // Full-height fill (no vertical inset) so rows sit flush, no gap between.
            .background(fill.padding(.leading, inset))
            .overlay { dropHintOverlay(subject, depth: depth) }
            .contentShape(Rectangle())
            .onDrag({ NSItemProvider(object: "subject:\(subject.id?.uuidString ?? "")" as NSString) },
                    preview: { subjectDragPreview(subject) })
            .onDrop(of: [.text], delegate: SubjectRowDropDelegate(
                targetID: subject.objectID, rowHeight: 44, hint: $dropHint,
                perform: { performSubjectDrop($0, target: subject, zone: $1) }))
    }

    @ViewBuilder
    private func dropHintOverlay(_ subject: Subject, depth: Int) -> some View {
        if let hint = dropHint, hint.target == subject.objectID {
            let inset = CGFloat(depth) * 20 + 6
            switch hint.zone {
            case .inside:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.vertical, 2).padding(.leading, inset).padding(.trailing, 6)
            case .before:
                VStack(spacing: 0) { Capsule().fill(Color.accentColor).frame(height: 2.5); Spacer(minLength: 0) }
                    .padding(.leading, inset).padding(.trailing, 6)
            case .after:
                VStack(spacing: 0) { Spacer(minLength: 0); Capsule().fill(Color.accentColor).frame(height: 2.5) }
                    .padding(.leading, inset).padding(.trailing, 6)
            }
        }
    }

    /// Apply a sidebar drop: reparent/reorder a subject, or file a note.
    private func performSubjectDrop(_ id: String, target: Subject, zone: SubjectDropZone) -> Bool {
        guard id.hasPrefix("subject:") else {
            // A note dragged from the grid — file it into the target subject.
            return handleDrop([id], into: target)
        }
        let uuid = String(id.dropFirst("subject:".count))
        guard let dragged = allSubjects.first(where: { $0.id?.uuidString == uuid }), dragged != target else { return false }
        switch zone {
        case .inside:
            guard canNest(dragged, into: target) else { return false }
            withAnimation {
                dragged.parent = target
                dragged.sortIndex = (sortedChildren(of: target).map(\.sortIndex).max() ?? -1) + 1
            }
        case .before, .after:
            let newParent = target.parent
            if let p = newParent, !canNest(dragged, into: p) { return false }
            withAnimation {
                dragged.parent = newParent
                var ordered = (newParent.map { sortedChildren(of: $0) } ?? rootSubjects).filter { $0 != dragged }
                let targetIdx = ordered.firstIndex(of: target) ?? ordered.count
                let insertAt = zone == .before ? targetIdx : targetIdx + 1
                ordered.insert(dragged, at: min(max(insertAt, 0), ordered.count))
                for (i, s) in ordered.enumerated() { s.sortIndex = Int32(i) }
            }
        }
        PersistenceController.shared.save()
        return true
    }

    @ViewBuilder
    private func subjectRow(_ subject: Subject, depth: Int) -> some View {
        if renamingSubject == subject {
            // Inline rename, right in the row — no popup. Focus lands
            // immediately so the keyboard comes up with it.
            HStack(spacing: 10) {
                if !subject.isDivider {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                        .frame(width: 11, height: 11)
                        .frame(width: 24, height: 24)
                }
                TextField("library.subjectName", text: $renameText)
                    .focused($renameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(commitInlineRename)
            }
            .padding(.horizontal, 12).padding(.leading, CGFloat(depth) * 20)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            // Same flush, subject-tinted fill as a normal subject row.
            .background(
                (Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor).opacity(0.18)
                    .padding(.leading, CGFloat(depth) * 20)
            )
            // Focus on the next runloop so the field is in the responder chain
            // first — otherwise the keyboard doesn't come up for a just-added
            // subject (the row is still being inserted when onAppear fires).
            .onAppear { DispatchQueue.main.async { renameFieldFocused = true } }
            .onChange(of: renameFieldFocused) { _, focused in
                // Tapping away commits too — never strand an unnamed folder.
                if !focused { commitInlineRename() }
            }
        } else if subject.isDivider {
            subjectRowChrome(subject, depth: depth, fill: .clear) {
                HStack {
                    Text(verbatim: subject.name ?? "")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                // Hebrew/Arabic dividers mirror so the label sits on the right.
                .environment(\.layoutDirection, nameDirection(subject.name))
            }
            .contextMenu { subjectContextMenu(subject) }
        } else {
            let tint = Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor
            let isSelected = selection == .subject(subject)
            // Subject rows carry their color as a soft wash; selection darkens it.
            subjectRowChrome(subject, depth: depth, fill: tint.opacity(isSelected ? 0.38 : 0.18)) {
              Button {
                selection = .subject(subject)
              } label: {
                HStack(spacing: 10) {
                    // The subject IS its color — a rounded chip, not a folder glyph.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint)
                        .frame(width: 11, height: 11)
                        .frame(width: 24, height: 24)
                    Text(verbatim: subject.name ?? "")
                        .font(.callout)
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
                            Lucide("chevron-down", size: 14)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(collapsedSubjects.contains(subject.objectID) ? -90 : 0))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("library.toggleChildren"))
                    }
                }
                // Hebrew/Arabic names mirror the row so the name reads from the right.
                .environment(\.layoutDirection, nameDirection(subject.name))
              }
              .buttonStyle(.plain)
            }
            .contextMenu { subjectContextMenu(subject) }
        }
    }

    private func siblings(of subject: Subject) -> [Subject]? {
        let pool = subject.parent.map { sortedChildren(of: $0) } ?? rootSubjects
        return pool.isEmpty ? nil : pool
    }

    private func siblingIndex(of subject: Subject) -> Int {
        siblings(of: subject)?.firstIndex(of: subject) ?? 0
    }

    /// Native List drag-reorder (Apple-Lists style) within a sibling group:
    /// reorder the pool and renumber sortIndex so the new order sticks. `parent`
    /// nil = the top level.
    private func moveSiblings(of parent: Subject?, from source: IndexSet, to destination: Int) {
        var pool = parent.map { sortedChildren(of: $0) } ?? rootSubjects
        pool.move(fromOffsets: source, toOffset: destination)
        withAnimation {
            for (position, sibling) in pool.enumerated() { sibling.sortIndex = Int32(position) }
            PersistenceController.shared.save()
        }
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

    /// A clean capsule shown under the finger while dragging a subject/divider —
    /// replaces the default drag snapshot (which rendered a black border).
    private func subjectDragPreview(_ subject: Subject) -> some View {
        HStack(spacing: 8) {
            if !subject.isDivider {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                    .frame(width: 11, height: 11)
            }
            Text(verbatim: subject.name ?? "—").font(.callout).lineLimit(1).foregroundStyle(.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .environment(\.layoutDirection, nameDirection(subject.name))
    }

    /// A name beginning with a Hebrew/Arabic letter reads right-to-left, so its
    /// row mirrors (name on the right). Falls back to LTR for English/numbers.
    private func nameDirection(_ name: String?) -> LayoutDirection {
        guard let scalar = name?.unicodeScalars.first(where: { CharacterSet.letters.contains($0) })
        else { return .leftToRight }
        return (0x0590...0x08FF).contains(scalar.value) ? .rightToLeft : .leftToRight
    }

    /// A subject/divider can be nested into any other subject OR divider — the
    /// only rule is it can't go into itself or one of its own descendants (that
    /// would orphan a cycle).
    private func canNest(_ dragged: Subject, into target: Subject) -> Bool {
        guard dragged != target else { return false }
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

        // Reliable reparent (dragging a row onto another is finicky inside a
        // List): move this subject/divider INTO any other one.
        let nestTargets = allSubjects.filter { canNest(subject, into: $0) && $0 != subject.parent }
        if !nestTargets.isEmpty {
            Menu {
                ForEach(nestTargets, id: \.objectID) { target in
                    Button {
                        withAnimation { subject.parent = target }
                        PersistenceController.shared.save()
                    } label: {
                        Label {
                            Text(verbatim: target.name ?? "—")
                        } icon: {
                            Image(systemName: target.isDivider ? "minus" : "folder")
                        }
                    }
                }
            } label: { Label("library.moveInto", systemImage: "arrow.turn.down.right") }
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
        // Append to the end of the current folder's tree order.
        note.sortIndex = (FileTree.children(of: subject, in: context).map(\.sortIndex).max() ?? -1) + 1
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
