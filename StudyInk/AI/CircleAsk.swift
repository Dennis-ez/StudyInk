import SwiftUI
import UIKit

/// Circle & Ask: the student lassos a region (armed by holding the Apple Pencil
/// still for ~1s, or via the toolbar), then asks about exactly that content.
/// The drawn loop is screen-space; the resolved region is page-space.
struct AskLassoOverlay: View {
    @Binding var isActive: Bool
    let transform: CanvasTransform
    var onRegionSelected: (CGRect) -> Void   // SCREEN-space rect (page resolved by the caller)

    @State private var points: [CGPoint] = []
    @Environment(\.aiAccent) private var aiAccent

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
                    aiAccent,
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
            // A plain tap (no loop drawn) cancels — e.g. tapping the UI or off
            // the page to back out of Circle & Ask.
            .onTapGesture { points = []; isActive = false }
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
        // Hand back the SCREEN rect — which page it lands on (and the page-space
        // crop) is resolved by the caller, so circling a non-centered page still
        // targets the right one.
        onRegionSelected(screenRect)
    }
}

/// Question popover shown after circling: free text plus quick suggestion chips.
struct CircleAskSheet: View {
    let region: CGRect
    var onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.aiAccent) private var aiAccent
    @State private var question = ""
    @FocusState private var focused: Bool

    private struct Suggestion: Identifiable {
        let id = UUID()
        let key: LocalizedStringKey
        let raw: String
        let icon: String
    }
    private let suggestions: [Suggestion] = [
        .init(key: "ai.suggestion.checkThis", raw: "ai.suggestion.checkThis", icon: "checkmark.seal"),
        .init(key: "ai.suggestion.explainThis", raw: "ai.suggestion.explainThis", icon: "text.book.closed"),
        .init(key: "ai.suggestion.nextStep", raw: "ai.suggestion.nextStep", icon: "arrow.turn.down.right"),
        .init(key: "ai.suggestion.similarExample", raw: "ai.suggestion.similarExample", icon: "doc.on.doc"),
    ]

    var body: some View {
        NavigationStack {
            // Scrollable so a floating/split keyboard can't clip the field or
            // suggestions on a short sheet.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                // The prompt field, styled as a prominent rounded capsule with
                // a sparkles cue and inline send.
                HStack(alignment: .bottom, spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(aiAccent)
                        .padding(.bottom, 7)
                    TextField("ai.askPlaceholder", text: $question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { ask(question) }
                    Button {
                        ask(question)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(question.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : aiAccent)
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(Text("ai.ask"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(SemanticColor.aiMessageBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SemanticColor.toolbarBorder, lineWidth: 0.5))

                // Quick-ask suggestions, two-up with icons.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            ask(String(localized: String.LocalizationValue(suggestion.raw)))
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: suggestion.icon)
                                    .font(.caption)
                                    .foregroundStyle(aiAccent)
                                Text(suggestion.key)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SemanticColor.aiMessageBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(Text("ai.circleAsk.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(320), .medium])
        .presentationDragIndicator(.visible)
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        onAsk(trimmed)
    }
}
