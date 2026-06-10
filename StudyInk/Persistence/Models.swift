import CoreData
import PencilKit

// MARK: - Subject (folder or divider)

@objc(Subject)
final class Subject: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var colorHex: String?
    @NSManaged var kind: String?
    @NSManaged var sortIndex: Int32
    @NSManaged var createdAt: Date?
    @NSManaged var parent: Subject?
    @NSManaged var children: Set<Subject>?
    @NSManaged var notes: Set<Note>?

    var isDivider: Bool { kind == "divider" }

    static func create(in context: NSManagedObjectContext, name: String, colorHex: String = "#0A84FF", kind: String = "folder", parent: Subject? = nil) -> Subject {
        let s = Subject(context: context)
        s.id = UUID()
        s.name = name
        s.colorHex = colorHex
        s.kind = kind
        s.parent = parent
        s.createdAt = Date()
        return s
    }
}

// MARK: - Note

@objc(Note)
final class Note: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var title: String?
    @NSManaged var createdAt: Date?
    @NSManaged var modifiedAt: Date?
    @NSManaged var searchableText: String?
    @NSManaged var subjectContext: String?
    @NSManaged var subject: Subject?
    @NSManaged var pages: Set<Page>?
    @NSManaged var recordings: Set<Recording>?

    var sortedPages: [Page] {
        (pages ?? []).sorted { $0.index < $1.index }
    }

    static func create(in context: NSManagedObjectContext, title: String, subject: Subject? = nil) -> Note {
        let n = Note(context: context)
        n.id = UUID()
        n.title = title
        n.createdAt = Date()
        n.modifiedAt = Date()
        n.subject = subject
        n.subjectContext = "calculus1"
        let first = Page(context: context)
        first.id = UUID()
        first.index = 0
        first.note = n
        return n
    }

    func touch() { modifiedAt = Date() }

    @discardableResult
    func addPage(after index: Int32? = nil, templateID: String? = nil) -> Page {
        guard let context = managedObjectContext else { fatalError("note detached from context") }
        let insertIndex = (index ?? Int32(sortedPages.count) - 1) + 1
        for p in sortedPages where p.index >= insertIndex { p.index += 1 }
        let page = Page(context: context)
        page.id = UUID()
        page.index = insertIndex
        page.templateID = templateID ?? sortedPages.first(where: { $0.index == insertIndex - 1 })?.templateID ?? "blank"
        page.note = self
        touch()
        return page
    }

    func deletePage(_ page: Page) {
        guard let context = managedObjectContext, sortedPages.count > 1 else { return }
        let removed = page.index
        context.delete(page)
        for p in sortedPages where p.index > removed { p.index -= 1 }
        touch()
    }
}

// MARK: - Page

@objc(Page)
final class Page: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var index: Int32
    @NSManaged var drawingData: Data?
    @NSManaged var templateID: String?
    @NSManaged var templateSpacing: Double
    @NSManaged var pageSizeID: String?
    @NSManaged var customTemplatePDF: Data?
    @NSManaged var textBoxesData: Data?
    @NSManaged var mediaItemsData: Data?
    @NSManaged var pinnedBubblesData: Data?
    @NSManaged var ocrText: String?
    @NSManaged var note: Note?

    var drawing: PKDrawing {
        get {
            guard let data = drawingData, let d = try? PKDrawing(data: data) else { return PKDrawing() }
            return d
        }
        set {
            drawingData = newValue.dataRepresentation()
            note?.touch()
        }
    }

    /// Typed text boxes, JSON-encoded so the schema can evolve without migrations.
    var textBoxes: [TextBoxModel] {
        get { decode([TextBoxModel].self, from: textBoxesData) ?? [] }
        set { textBoxesData = try? JSONEncoder().encode(newValue); note?.touch() }
    }

    var mediaItems: [MediaItemModel] {
        get { decode([MediaItemModel].self, from: mediaItemsData) ?? [] }
        set { mediaItemsData = try? JSONEncoder().encode(newValue); note?.touch() }
    }

    var template: PageTemplate { PageTemplate.from(id: templateID) }

    /// Line/grid density multiplier (0.75 compact … 1.4 wide); 0 = legacy rows.
    var effectiveTemplateSpacing: CGFloat {
        templateSpacing > 0 ? CGFloat(templateSpacing) : 1
    }

    /// Deep copy used by page duplication.
    func copyContents(from other: Page) {
        drawingData = other.drawingData
        templateID = other.templateID
        templateSpacing = other.templateSpacing
        pageSizeID = other.pageSizeID
        customTemplatePDF = other.customTemplatePDF
        textBoxesData = other.textBoxesData
        mediaItemsData = other.mediaItemsData
        ocrText = other.ocrText
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Recording (audio, phase 8)

@objc(Recording)
final class Recording: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var fileName: String?
    @NSManaged var duration: Double
    @NSManaged var strokeTimelineData: Data?
    @NSManaged var note: Note?
}
