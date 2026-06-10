import SwiftUI
import UIKit

/// Circle & Ask: the student lassos a region (armed by holding the Apple Pencil
/// still for ~1s, or via the toolbar), then asks about exactly that content.
/// The drawn loop is screen-space; the resolved region is page-space.
struct AskLassoOverlay: View {
    @Binding var isActive: Bool
    let transform: CanvasTransform
    var onRegionSelected: (CGRect) -> Void   // page-space rect

    @State private var points: [CGPoint] = []

    var body: some View {
        if isActive {
            ZStack {
                Color.black.opacity(0.04).ignoresSafeArea()

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(
                    SemanticColor.accentBlue,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5])
                )

                VStack {
                    Text("ai.circleAsk.hint")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 70)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { points.append($0.location) }
                    .onEnded { _ in finish() }
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    points = []
                    isActive = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                .accessibilityLabel(Text("action.cancel"))
            }
            .transition(.opacity)
        }
    }

    private func finish() {
        defer { points = []; isActive = false }
        guard points.count > 4 else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let screenRect = CGRect(
            x: xs.min()!, y: ys.min()!,
            width: max(xs.max()! - xs.min()!, 20),
            height: max(ys.max()! - ys.min()!, 20)
        )
        let origin = transform.toPage(screenRect.origin)
        let pageRect = CGRect(
            x: origin.x, y: origin.y,
            width: screenRect.width / transform.zoomScale,
            height: screenRect.height / transform.zoomScale
        )
        onRegionSelected(pageRect)
    }
}

/// Question popover shown after circling: free text plus quick suggestion chips.
struct CircleAskSheet: View {
    let region: CGRect
    var onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var focused: Bool

    private let suggestionKeys: [LocalizedStringKey] = [
        "ai.suggestion.checkThis",
        "ai.suggestion.explainThis",
        "ai.suggestion.nextStep",
        "ai.suggestion.similarExample",
    ]
    private let suggestionStrings = [
        "ai.suggestion.checkThis",
        "ai.suggestion.explainThis",
        "ai.suggestion.nextStep",
        "ai.suggestion.similarExample",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("ai.askPlaceholder", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .focused($focused)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(suggestionKeys.enumerated()), id: \.offset) { index, key in
                            Button {
                                ask(String(localized: String.LocalizationValue(suggestionStrings[index])))
                            } label: {
                                Text(key)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(SemanticColor.aiMessageBubble, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    ask(question)
                } label: {
                    Label("ai.ask", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(20)
            .navigationTitle(Text("ai.circleAsk.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(260)])
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        onAsk(trimmed)
    }
}
