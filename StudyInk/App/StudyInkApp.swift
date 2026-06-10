import SwiftUI

@main
struct StudyInkApp: App {
    let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
