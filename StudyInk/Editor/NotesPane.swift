import SwiftUI
import CoreData

/// Left-edge drawer inside the editor, swiped in from the screen edge like a
/// sidebar. Tabs switch between the open note's subject, all notes, recents,
/// and favorites; tap a note to switch without going back to the library.
struct NotesPane: View {
    @ObservedObject var currentNote: Note
    /// When set by the subjects pane, the subject tab shows THIS subject
    /// (`.some(nil)` = unfiled/all) instead of the open note's own subject.
    var subjectOverride: Subject?? = nil
    var onSelect: (Note) -> Void

    enum Tab: String, CaseIterable {
        case subject, all, recents, favorites

        /// Bundled Lucide glyph name (matches the library sidebar's icon set).
        var lucideName: String {
            switch self {
            case .subject: return "folder"
            case .all: return "layers"
            case .recents: return "clock"
            case .favorites: return "star"
            }
        }

        var labelKey: LocalizedStringKey {
            switch self {
            case .subject: return "library.subjects"
            case .all: return "library.allNotes"
            case .recents: return "library.recents"
            case .favorites: return "library.favorites"
            }
        }
    }

    @State private var tab: Tab = .subject

    // Warm, full-height spine — the same surface as the library sidebar so the
    // drawer reads as a slim version of it.
    @Environment(\.themeSidebar) private var themeSidebar

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    private var shownSubject: Subject? {
        if let override = subjectOverride { return override }
        return currentNote.subject
    }

    private var visibleNotes: [Note] {
        let active = allNotes.filter { $0.deletedAt == nil }
        switch tab {
        case .subject:
            return active.filter { $0.subject == shownSubject }
        case .all:
            return active
        case .recents:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            return active.filter { ($0.modifiedAt ?? .distantPast) > cutoff }
        case .favorites:
            return active.filter(\.isFavorite)
        }
    }

    var body: some View {
        // Opaque warm spine behind the rows — the slim sibling of the library
        // sidebar (§1.4 / §3.1). No glass of its own: the editor wraps notes +
        // subjects panes in ONE container so the drawer reads as a single panel.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // Smart/section rows, styled like the main screen's sidebar.
                if let subject = shownSubject {
                    sectionRow(.subject, name: subject.name ?? "",
                               dot: Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                }
                sectionRow(.all)
                sectionRow(.recents)
                sectionRow(.favorites)

                // Serif micro-header for the visible list, with a count.
                HStack(spacing: DS.Space.sm) {
                    Text(headerTitle)
                        .font(.fraunces(13, weight: .semibold, relativeTo: .footnote))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(visibleNotes.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(SemanticColor.textMutedColor)
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.lg)
                .padding(.bottom, DS.Space.xs)

                ForEach(visibleNotes, id: \.objectID) { note in
                    noteRow(note)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.md)
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(themeSidebar.ignoresSafeArea())
        // 1px warm hairline along the trailing edge, like the library spine.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SemanticColor.separator)
                .frame(width: DS.Stroke.hairline)
                .ignoresSafeArea()
        }
    }

    private var headerTitle: LocalizedStringKey {
        if tab == .subject, let name = shownSubject?.name {
            return LocalizedStringKey(name)
        }
        return tab.labelKey
    }

    private func count(for t: Tab) -> Int {
        let active = allNotes.filter { $0.deletedAt == nil }
        switch t {
        case .subject: return active.filter { $0.subject == shownSubject }.count
        case .all: return active.count
        case .recents:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            return active.filter { ($0.modifiedAt ?? .distantPast) > cutoff }.count
        case .favorites: return active.filter(\.isFavorite).count
        }
    }

    private func sectionRow(_ t: Tab, name: String? = nil, dot: Color? = nil) -> some View {
        let selected = tab == t
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { tab = t }
        } label: {
            HStack(spacing: 11) {
                // A subject row gets its color dot; smart rows get a Lucide glyph
                // tinting to accent when selected — exactly like the library.
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 11, height: 11)
                        .frame(width: 24, height: 24)
                } else {
                    Lucide(t.lucideName, size: 19)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 24)
                }
                Group {
                    if let name { Text(verbatim: name) } else { Text(t.labelKey) }
                }
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: "\(count(for: t))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SemanticColor.textMutedColor)
            }
            .frame(height: 40)
            .padding(.horizontal, DS.Space.sm)
            // Selected = subtle fill + a 3pt accent bar inset at the leading edge.
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(selected ? SemanticColor.fillSelected : .clear)
                    .overlay(alignment: .leading) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(Color.accentColor)
                                .frame(width: DS.Stroke.thick)
                                .padding(.vertical, 6)
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func noteRow(_ note: Note) -> some View {
        // Slim list row — title + date + subject dot — echoing the library's
        // note footer (NoteGridView). The currently-open note gets the sidebar's
        // selected treatment: a soft fill plus a 3pt accent leading bar.
        let isCurrent = note.objectID == currentNote.objectID
        return Button {
            onSelect(note)
        } label: {
            HStack(spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: note.title ?? "")
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(note.modifiedAt ?? .now, style: .date)
                        .font(.caption2)
                        .foregroundStyle(SemanticColor.textMutedColor)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.xs)
                if let subject = note.subject {
                    Circle()
                        .fill(Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor)
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isCurrent ? SemanticColor.fillSelected : .clear)
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(Color.accentColor)
                                .frame(width: DS.Stroke.thick)
                                .padding(.vertical, 6)
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: note.title ?? ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Second drawer stage: the subjects sidebar that slides in to the LEFT of the
/// notes pane on a second edge swipe. Styled like the main screen's sidebar —
/// color-dot rows, count badges, soft color washes, tree indentation.
struct SubjectsPane: View {
    /// nil = All Notes.
    var onSelect: (Subject?) -> Void

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Subject"]!,
        sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)]
    ) private var allSubjects: FetchedResults<Subject>

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    private var rootSubjects: [Subject] {
        allSubjects.filter { $0.parent == nil && !$0.isDivider }
    }

    private var activeNotesCount: Int {
        allNotes.count(where: { $0.deletedAt == nil })
    }

    private func count(of subject: Subject) -> Int {
        allNotes.count(where: { $0.deletedAt == nil && $0.subject == subject })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(
                        name: String(localized: "library.allNotes"),
                        color: nil,
                        count: activeNotesCount,
                        depth: 0
                    ) { onSelect(nil) }

                    Text("library.subjects")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(rootSubjects, id: \.objectID) { subject in
                        subjectRows(subject, depth: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func subjectRows(_ subject: Subject, depth: Int) -> AnyView {
        AnyView(
            Group {
                row(
                    name: subject.name ?? "",
                    color: Color(hex: subject.colorHex ?? "#0A84FF") ?? .accentColor,
                    count: count(of: subject),
                    depth: depth
                ) { onSelect(subject) }
                ForEach((subject.children ?? []).filter { !$0.isDivider }.sorted {
                    ($0.sortIndex, $0.createdAt ?? .distantPast) < ($1.sortIndex, $1.createdAt ?? .distantPast)
                }, id: \.objectID) { child in
                    subjectRows(child, depth: depth + 1)
                }
            }
        )
    }

    private func row(name: String, color: Color?, count: Int, depth: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 13, height: 13)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "tray.full.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                Text(verbatim: name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: "\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((color ?? .clear).opacity(color == nil ? 0 : 0.10))
            )
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Hosts the editor and swaps the open note in place when the notes pane picks
/// another one. The `.id` change rebuilds the editor (fresh canvas, overlays,
/// tutor) and fires the old instance's onDisappear, which persists overlays.
struct NoteEditorContainer: View {
    @State private var current: Note

    init(note: Note) {
        _current = State(initialValue: note)
    }

    var body: some View {
        NoteEditorView(note: current, onSwitchNote: { current = $0 })
            .id(current.objectID)
    }
}
