import SwiftUI
import CoreData

/// Left-edge drawer inside the editor, swiped in from the screen edge like a
/// sidebar. Tabs switch between the open note's subject, all notes, recents,
/// and favorites; tap a note to switch without going back to the library.
struct NotesPane: View {
    @ObservedObject var currentNote: Note
    var onSelect: (Note) -> Void

    enum Tab: String, CaseIterable {
        case subject, all, recents, favorites

        var symbolName: String {
            switch self {
            case .subject: return "folder"
            case .all: return "tray.full"
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

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    private var visibleNotes: [Note] {
        let active = allNotes.filter { $0.deletedAt == nil }
        switch tab {
        case .subject:
            return active.filter { $0.subject == currentNote.subject }
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
        VStack(alignment: .leading, spacing: 0) {
            Picker("editor.notesPane", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Image(systemName: tab.symbolName)
                        .accessibilityLabel(Text(tab.labelKey))
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            headerTitle
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(visibleNotes, id: \.objectID) { note in
                        noteCell(note)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .studyGlass(cornerRadius: 18)
    }

    private var headerTitle: Text {
        if tab == .subject, let name = currentNote.subject?.name {
            return Text(verbatim: name)
        }
        return Text(tab.labelKey)
    }

    private func noteCell(_ note: Note) -> some View {
        let isCurrent = note.objectID == currentNote.objectID
        return Button {
            onSelect(note)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let first = note.sortedPages.first {
                    PageThumbnailView(page: first)
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isCurrent ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isCurrent ? 2 : 1)
                        )
                }
                Text(verbatim: note.title ?? "")
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(note.modifiedAt ?? .now, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: note.title ?? ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
