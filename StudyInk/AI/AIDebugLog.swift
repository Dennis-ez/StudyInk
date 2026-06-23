import SwiftUI

/// Captures recent AI round-trips — the system prompt, the text we actually sent
/// (including the OCR the context builder produced), how many page images rode
/// along, and the raw model response. In-memory only; viewable from Settings →
/// "AI debug log" and echoed to the console. The point is to diagnose grading /
/// accuracy problems from REAL data instead of guessing at the prompts.
@MainActor
final class AIDebugLog: ObservableObject {
    static let shared = AIDebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        var system: String
        var user: String
        var images: Int
        var response: String
        var failed: Bool
        var ms: Int

        /// One block of copyable plain text — what you'd paste to share an issue.
        var transcript: String {
            """
            [\(time.formatted(date: .omitted, time: .standard))] \(failed ? "ERROR" : "OK") · \(ms)ms · \(images) image(s)

            ===== SYSTEM PROMPT =====
            \(system)

            ===== SENT (text + OCR) =====
            \(user)

            ===== RESPONSE =====
            \(response)
            """
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let cap = 40

    /// All captured round-trips as one blob, for "Copy all".
    var allTranscripts: String {
        entries.map(\.transcript).joined(separator: "\n\n════════════════════════\n\n")
    }

    func record(system: String, user: String, images: Int, response: String, failed: Bool, ms: Int) {
        let entry = Entry(system: system, user: user, images: images, response: response, failed: failed, ms: ms)
        entries.insert(entry, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        // Echo a compact version to the console (shareable from Console.app).
        print("""
        ──────── AI \(failed ? "ERROR" : "OK") · \(ms)ms · \(images) img ────────
        SYSTEM: \(system.prefix(300))…
        SENT:   \(user.prefix(1400))
        REPLY:  \(response.prefix(1400))
        ─────────────────────────────────────────────
        """)
    }

    func clear() { entries.removeAll() }
}

/// Settings → AI debug log. Each row is one round-trip; tap for the full,
/// copyable transcript (system prompt + sent text/OCR + response) to share.
struct AIDebugView: View {
    @ObservedObject private var log = AIDebugLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView(
                    "No AI calls yet", systemImage: "ladybug",
                    description: Text(verbatim: "Run Check my work or ask the tutor, then come back."))
            } else {
                ForEach(log.entries) { entry in
                    NavigationLink {
                        AIDebugDetail(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: entry.failed ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                    .foregroundStyle(entry.failed ? .red : .green)
                                Text(entry.time, style: .time).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(verbatim: "\(entry.ms)ms · \(entry.images) img").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(verbatim: String(entry.response.prefix(100)))
                                .font(.caption).lineLimit(2).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: "AI debug log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("action.done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = log.allTranscripts
                    } label: { Label(title: { Text(verbatim: "Copy all") }, icon: { Image(systemName: "doc.on.doc") }) }
                    Button(role: .destructive) { log.clear() } label: {
                        Label(title: { Text(verbatim: "Clear") }, icon: { Image(systemName: "trash") })
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(log.entries.isEmpty)
            }
        }
    }
}

private struct AIDebugDetail: View {
    let entry: AIDebugLog.Entry

    var body: some View {
        ScrollView {
            Text(verbatim: entry.transcript)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: "Transcript"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { UIPasteboard.general.string = entry.transcript } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }
}
