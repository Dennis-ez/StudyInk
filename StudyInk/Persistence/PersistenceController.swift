import CoreData

/// Core Data stack with a programmatic model (no .xcdatamodeld — keeps the schema
/// reviewable in source control). Local store in phases 1–7; phase 8 switches the
/// container to NSPersistentCloudKitContainer when iCloud sync is enabled.
final class PersistenceController {
    static let shared = PersistenceController()
    static let cloudKitContainerID = "iCloud.com.studyink.app"

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        // iCloud sync: NSPersistentCloudKitContainer mirrors the same local store
        // into the user's private CloudKit database. Toggled in Settings; the
        // store URL is shared, so flipping the toggle never loses data.
        let useCloud = !inMemory && UserDefaults.standard.bool(forKey: "settings.iCloudSync")
        if useCloud {
            container = NSPersistentCloudKitContainer(name: "StudyInk", managedObjectModel: Self.model)
            if let description = container.persistentStoreDescriptions.first {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: Self.cloudKitContainerID
                )
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        } else {
            container = NSPersistentContainer(name: "StudyInk", managedObjectModel: Self.model)
        }
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error {
                // A corrupt local store should not take the whole app down; surface and continue in-memory.
                assertionFailure("Core Data store failed to load: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.undoManager = nil
    }

    func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    // MARK: - Programmatic model

    static let model: NSManagedObjectModel = {
        let subject = NSEntityDescription(name: "Subject", class: Subject.self)
        subject.properties = [
            attr("id", .uuid),
            attr("name", .string),
            attr("colorHex", .string),
            attr("kind", .string, default: "folder"),   // "folder" | "divider"
            attr("sortIndex", .integer32, default: 0),
            attr("createdAt", .date),
        ]

        let note = NSEntityDescription(name: "Note", class: Note.self)
        note.properties = [
            attr("id", .uuid),
            attr("title", .string),
            attr("createdAt", .date),
            attr("modifiedAt", .date),
            attr("searchableText", .string),            // typed text + OCR cache for library search
            attr("subjectContext", .string),            // AI tutor subject: calculus1 | discrete1 | custom
            attr("isFavorite", .boolean, default: false),
            attr("deletedAt", .date),                   // soft delete — purged 30 days later
        ]

        let page = NSEntityDescription(name: "Page", class: Page.self)
        page.properties = [
            attr("id", .uuid),
            attr("index", .integer32, default: 0),
            attr("drawingData", .binaryData, external: true),
            attr("templateID", .string, default: "blank"),
            attr("templateSpacing", .double, default: 1.0),
            attr("pageSizeID", .string, default: "letter"),
            // Per-page exact dimensions (points); 0 = fall back to pageSizeID.
            // Imported PDF pages use these to match the note width + PDF aspect.
            attr("pageWidth", .double, default: 0),
            attr("pageHeight", .double, default: 0),
            attr("customTemplatePDF", .binaryData, external: true),
            attr("textBoxesData", .binaryData),         // JSON [TextBoxModel]
            attr("mediaItemsData", .binaryData),        // JSON [MediaItemModel] (phase 2)
            attr("pinnedBubblesData", .binaryData),     // JSON [AIBubbleModel] (phase 5)
            attr("ocrText", .string),
        ]

        let recording = NSEntityDescription(name: "Recording", class: Recording.self)
        recording.properties = [
            attr("id", .uuid),
            attr("createdAt", .date),
            attr("fileName", .string),
            attr("duration", .double, default: 0),
            attr("strokeTimelineData", .binaryData),    // JSON [StrokeTimestamp] (phase 8)
        ]

        // Relationships (with inverses).
        let subjectParent = rel("parent", to: subject, toMany: false)
        let subjectChildren = rel("children", to: subject, toMany: true)
        subjectParent.inverseRelationship = subjectChildren
        subjectChildren.inverseRelationship = subjectParent

        let noteSubject = rel("subject", to: subject, toMany: false)
        let subjectNotes = rel("notes", to: note, toMany: true)
        noteSubject.inverseRelationship = subjectNotes
        subjectNotes.inverseRelationship = noteSubject

        let pageNote = rel("note", to: note, toMany: false)
        let notePages = rel("pages", to: page, toMany: true, cascade: true)
        pageNote.inverseRelationship = notePages
        notePages.inverseRelationship = pageNote

        let recordingNote = rel("note", to: note, toMany: false)
        let noteRecordings = rel("recordings", to: recording, toMany: true, cascade: true)
        recordingNote.inverseRelationship = noteRecordings
        noteRecordings.inverseRelationship = recordingNote

        subject.properties += [subjectParent, subjectChildren, subjectNotes]
        note.properties += [noteSubject, notePages, noteRecordings]
        page.properties += [pageNote]
        recording.properties += [recordingNote]

        let model = NSManagedObjectModel()
        model.entities = [subject, note, page, recording]
        return model
    }()

    private static func attr(
        _ name: String,
        _ type: NSAttributeDescription.AttributeType,
        default defaultValue: Any? = nil,
        external: Bool = false
    ) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.type = type
        a.isOptional = true
        a.defaultValue = defaultValue
        a.allowsExternalBinaryDataStorage = external
        return a
    }

    private static func rel(
        _ name: String,
        to destination: NSEntityDescription,
        toMany: Bool,
        cascade: Bool = false
    ) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = destination
        r.isOptional = true
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        r.deleteRule = cascade ? .cascadeDeleteRule : .nullifyDeleteRule
        return r
    }
}

private extension NSEntityDescription {
    convenience init(name: String, class cls: AnyClass) {
        self.init()
        self.name = name
        managedObjectClassName = NSStringFromClass(cls)
    }
}
