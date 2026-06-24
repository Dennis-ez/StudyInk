import CoreData

/// Stage 1 of the file-manager redesign: folders (Subject) and files (Note) are
/// modelled as siblings in one tree, ordered by `sortIndex` inside a parent
/// folder. This is purely additive over the existing entities — no note content
/// is ever moved or rewritten — so existing data is never at risk.

/// A node in the unified file tree: a folder or a file.
enum FileNode: Identifiable, Equatable {
    case folder(Subject)
    case note(Note)

    var id: NSManagedObjectID {
        switch self {
        case .folder(let s): return s.objectID
        case .note(let n): return n.objectID
        }
    }
    var sortIndex: Int32 {
        switch self {
        case .folder(let s): return s.sortIndex
        case .note(let n): return n.sortIndex
        }
    }
    var name: String {
        switch self {
        case .folder(let s): return s.name ?? ""
        case .note(let n): return n.title ?? ""
        }
    }
    var isFolder: Bool { if case .folder = self { return true }; return false }
}

enum FileTree {
    /// The ordered children of `folder` (nil = the root): its subfolders and its
    /// own non-deleted notes, interleaved by `sortIndex`, folders first on ties.
    static func children(of folder: Subject?, in context: NSManagedObjectContext) -> [FileNode] {
        let folders: [Subject]
        let notes: [Note]
        if let folder {
            folders = Array(folder.children ?? [])
            notes = (folder.notes ?? []).filter { $0.deletedAt == nil }
        } else {
            folders = rootSubjects(context)
            notes = rootNotes(context)
        }
        let nodes = folders.map(FileNode.folder) + notes.map(FileNode.note)
        return nodes.sorted { a, b in
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            if a.isFolder != b.isFolder { return a.isFolder }     // folders first on a tie
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func rootSubjects(_ context: NSManagedObjectContext) -> [Subject] {
        let r = NSFetchRequest<Subject>(entityName: "Subject")
        r.predicate = NSPredicate(format: "parent == nil")
        return (try? context.fetch(r)) ?? []
    }

    static func rootNotes(_ context: NSManagedObjectContext) -> [Note] {
        let r = NSFetchRequest<Note>(entityName: "Note")
        r.predicate = NSPredicate(format: "subject == nil AND deletedAt == nil")
        return (try? context.fetch(r)) ?? []
    }

    /// One-time, idempotent backfill: number every sibling group (folders then
    /// notes) so notes get a sensible `sortIndex` alongside folders. Renumbering
    /// only touches the ordering metadata — never note content.
    static func backfillSortIndexIfNeeded(_ context: NSManagedObjectContext) {
        let key = "filetree.backfilled.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        // Every parent group: the root, plus each folder's children.
        let allSubjects = (try? context.fetch(NSFetchRequest<Subject>(entityName: "Subject"))) ?? []
        var groups: [(folders: [Subject], notes: [Note])] = [(rootSubjects(context), rootNotes(context))]
        for s in allSubjects {
            let notes = Array(s.notes ?? []).filter { $0.deletedAt == nil }
            groups.append((Array(s.children ?? []), notes))
        }

        for group in groups {
            // Keep the folders' existing relative order; append notes (by creation).
            let folders = group.folders.sorted { ($0.sortIndex, $0.createdAt ?? .distantPast) < ($1.sortIndex, $1.createdAt ?? .distantPast) }
            let notes = group.notes.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            var index: Int32 = 0
            for f in folders { f.sortIndex = index; index += 1 }
            for n in notes { n.sortIndex = index; index += 1 }
        }

        if context.hasChanges { try? context.save() }
        UserDefaults.standard.set(true, forKey: key)
    }
}
