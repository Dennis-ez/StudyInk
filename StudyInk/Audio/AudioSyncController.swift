import AVFoundation
import SwiftUI

/// One stroke's position on the recording timeline: "this ink appeared at t seconds."
struct StrokeTimestamp: Codable, Equatable {
    var time: Double
    var pageIndex: Int
    var x: Double
    var y: Double
}

/// Notability-style audio: record lectures while writing; every stroke is logged
/// against the recording clock, so tapping near any written mark during playback
/// jumps the audio to the moment it was written.
@MainActor
final class AudioSyncController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published var playbackTime: TimeInterval = 0
    @Published var activeRecording: Recording?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timeline: [StrokeTimestamp] = []
    private var recordingStart: Date?
    private var meterTimer: Timer?
    private weak var note: Note?

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func attach(note: Note) { self.note = note }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, let note else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let fileName = UUID().uuidString + ".m4a"
            let url = Self.directory.appendingPathComponent(fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            timeline = []
            recordingStart = Date()
            isRecording = true

            let recording = Recording(context: note.managedObjectContext ?? PersistenceController.shared.viewContext)
            recording.id = UUID()
            recording.createdAt = Date()
            recording.fileName = fileName
            recording.note = note
            activeRecording = recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
        isRecording = false
        if let recording = activeRecording {
            recording.duration = recorder?.currentTime ?? Date().timeIntervalSince(recordingStart ?? Date())
            recording.strokeTimelineData = try? JSONEncoder().encode(timeline)
            PersistenceController.shared.save()
        }
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Called for every new stroke while recording.
    func logStroke(at point: CGPoint, pageIndex: Int) {
        guard isRecording, let recorder else { return }
        timeline.append(StrokeTimestamp(time: recorder.currentTime, pageIndex: pageIndex, x: point.x, y: point.y))
    }

    // MARK: - Playback

    func play(_ recording: Recording, from time: TimeInterval = 0) {
        guard let fileName = recording.fileName else { return }
        stopPlayback()
        let url = Self.directory.appendingPathComponent(fileName)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.currentTime = time
            player?.play()
            activeRecording = recording
            isPlaying = true
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.playbackTime = self.player?.currentTime ?? 0
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isPlaying = false
        playbackTime = 0
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        playbackTime = time
    }

    /// Tap-a-word-to-jump: finds the stroke logged nearest to `point` on this page
    /// (within a forgiving radius) and returns its moment on the timeline.
    func time(near point: CGPoint, pageIndex: Int, in recording: Recording, radius: CGFloat = 70) -> TimeInterval? {
        guard let data = recording.strokeTimelineData,
              let stamps = try? JSONDecoder().decode([StrokeTimestamp].self, from: data) else { return nil }
        let candidates = stamps.filter { $0.pageIndex == pageIndex }
        let nearest = candidates.min { a, b in
            point.distance(to: CGPoint(x: a.x, y: a.y)) < point.distance(to: CGPoint(x: b.x, y: b.y))
        }
        guard let nearest, point.distance(to: CGPoint(x: nearest.x, y: nearest.y)) <= radius else { return nil }
        return nearest.time
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopPlayback()
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
