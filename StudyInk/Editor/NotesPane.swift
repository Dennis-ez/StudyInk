import SwiftUI
import CoreData

/// Left-edge drawer inside the editor: the sibling notes of the open note
/// (same subject), tap to switch without going back to the library.
struct NotesPane: View {
    @ObservedObject var currentNote: Note
    var onSelect: (Note) -> Void

    @FetchRequest(
        entity: PersistenceController.model.entitiesByName["Note"]!,
        sortDescriptors: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
    ) private var allNotes: FetchedResults<Note>

    private var siblings: [Note] {
        allNotes.filter { $0.deletedAt == nil && $0.subject == currentNote.subject }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: currentNote.subject?.name ?? String(localized: "library.allNotes"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(siblings, id: \.objectID) { note in
                        noteCell(note)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 172)
        .studyGlass(cornerRadius: 18)
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
