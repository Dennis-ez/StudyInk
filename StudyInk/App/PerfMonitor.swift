import SwiftUI
import QuartzCore

/// Catches main-thread frame hitches (the cause of "hiccups" / momentary
/// unresponsiveness) and tags each with what the app was doing at the time, so a
/// real, copyable log can be handed over instead of guessing. Off by default —
/// start a capture from Settings → Performance, reproduce the stutter, then copy
/// the log. A CADisplayLink fires every frame; if a frame takes much longer than
/// the display's budget, the main thread stalled — that's a hitch.
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    struct Hitch: Identifiable {
        let id = UUID()
        let time = Date()
        var stallMs: Int
        var activity: String
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var hitches: [Hitch] = []
    @Published private(set) var worstMs = 0
    @Published private(set) var frameCount = 0

    /// What the app is doing right now — set at key moments so hitches name their
    /// trigger (scroll / zoom / page-mount / ai:*). Plain var, written on the main
    /// thread only.
    private(set) var activity = "idle"

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private let cap = 300

    private init() {}

    func setActivity(_ name: String) { activity = name }

    func toggle() { isCapturing ? stop() : start() }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        hitches.removeAll()
        worstMs = 0
        frameCount = 0
        lastTimestamp = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        isCapturing = false
    }

    func clear() {
        hitches.removeAll()
        worstMs = 0
        frameCount = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        frameCount += 1
        guard lastTimestamp != 0 else { return }
        let delta = link.timestamp - lastTimestamp
        // The display's ideal frame duration (handles 60/120Hz/ProMotion).
        let budget = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        // A hitch: the frame took ≥ ~2.5 budgets (and at least ~28ms) to arrive.
        guard delta >= max(budget * 2.5, 0.028) else { return }
        let stall = Int(delta * 1000)
        worstMs = max(worstMs, stall)
        let h = Hitch(stallMs: stall, activity: activity)
        hitches.insert(h, at: 0)
        if hitches.count > cap { hitches.removeLast(hitches.count - cap) }
        print("⚠️ perf hitch \(stall)ms during \(activity)")
    }

    /// Everything captured as one copyable blob, grouped by trigger.
    var transcript: String {
        guard !hitches.isEmpty else { return "No hitches captured." }
        let byActivity = Dictionary(grouping: hitches, by: \.activity)
        let summary = byActivity
            .map { (name, list) in
                "  \(name): \(list.count) hitch(es), worst \(list.map(\.stallMs).max() ?? 0)ms" }
            .sorted()
            .joined(separator: "\n")
        let lines = hitches
            .map { "[\($0.time.formatted(date: .omitted, time: .standard))] \($0.stallMs)ms — \($0.activity)" }
            .joined(separator: "\n")
        return """
        StudyInk performance log
        \(hitches.count) hitch(es) over \(frameCount) frames · worst \(worstMs)ms

        ===== BY TRIGGER =====
        \(summary)

        ===== TIMELINE (newest first) =====
        \(lines)
        """
    }
}

/// Settings → Performance. Start a capture, reproduce the stutter, copy the log.
struct PerfMonitorView: View {
    @ObservedObject private var monitor = PerfMonitor.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    monitor.toggle()
                } label: {
                    Label {
                        Text(verbatim: monitor.isCapturing ? "Stop capture" : "Start capture")
                    } icon: {
                        Image(systemName: monitor.isCapturing ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(monitor.isCapturing ? .red : .accentColor)
                    }
                }
                if monitor.isCapturing {
                    Label {
                        Text(verbatim: "Recording — reproduce the stutter, then stop")
                    } icon: { Image(systemName: "waveform.path.ecg") }
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(verbatim: "Catches main-thread frame hitches and tags each with what the app was doing (scroll / zoom / page-mount / ai:*). Copy the log and send it over.")
            }

            if !monitor.hitches.isEmpty {
                Section {
                    HStack {
                        Text(verbatim: "\(monitor.hitches.count) hitches · worst \(monitor.worstMs)ms")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(monitor.hitches.prefix(60)) { h in
                        HStack {
                            Text(verbatim: "\(h.stallMs)ms")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(h.stallMs > 100 ? .red : .orange)
                                .frame(width: 64, alignment: .leading)
                            Text(verbatim: h.activity).font(.caption)
                            Spacer()
                            Text(h.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: "Performance"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("action.done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = monitor.transcript
                    } label: { Label(title: { Text(verbatim: "Copy log") }, icon: { Image(systemName: "doc.on.doc") }) }
                    Button(role: .destructive) { monitor.clear() } label: {
                        Label(title: { Text(verbatim: "Clear") }, icon: { Image(systemName: "trash") })
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(monitor.hitches.isEmpty)
            }
        }
    }
}
