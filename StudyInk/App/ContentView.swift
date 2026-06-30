import SwiftUI

struct ContentView: View {
    @State private var showSplash = true

    var body: some View {
        // DEV: launch with INK_PREVIEW=1 to eyeball AI handwriting (no API needed).
        if ProcessInfo.processInfo.environment["INK_PREVIEW"] != nil {
            return AnyView(InkWriterPreview())
        }
        // DEV: launch with CONOTE_GALLERY=1 to eyeball the five tutor surfaces (no API).
        if ProcessInfo.processInfo.environment["CONOTE_GALLERY"] != nil {
            return AnyView(TutorGallery())
        }
        return AnyView(library)
    }

    private var library: some View {
        LibraryView()
            .overlay {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(1.3))
                            withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
                        }
                }
            }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).viewContext)
}
