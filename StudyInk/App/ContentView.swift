import SwiftUI

struct ContentView: View {
    @State private var showSplash = true

    var body: some View {
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
