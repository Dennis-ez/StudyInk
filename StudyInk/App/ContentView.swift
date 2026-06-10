import SwiftUI

/// Phase 0 placeholder — replaced by the library + note editor in later phases.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 56))
            Text("StudyInk")
                .font(.largeTitle.bold())
            Text("Scaffold ready — phases 1–8 land here.")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
