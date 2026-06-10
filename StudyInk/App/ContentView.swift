import SwiftUI
import CoreData

/// Phase 1: opens a scratch note directly. The full library view replaces this in phase 3.
struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var note: Note?

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    NoteEditorView(note: note)
                } else {
                    ProgressView()
                }
            }
        }
        .onAppear(perform: loadScratchNote)
    }

    private func loadScratchNote() {
        guard note == nil else { return }
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first {
            note = existing
        } else {
            note = Note.create(in: context, title: "My First Note")
            PersistenceController.shared.save()
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).viewContext)
}
