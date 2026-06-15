import SwiftUI

/// Compact audio strip shown above the page strip: record/stop, the note's
/// recordings, playback scrubber, and a hint that tapping ink jumps the audio.
struct AudioBar: View {
    @ObservedObject var audio: AudioSyncController
    @ObservedObject var note: Note

    private var recordings: [Recording] {
        (note.recordings ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                audio.isRecording ? audio.stopRecording() : audio.startRecording()
            } label: {
                Image(systemName: audio.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(audio.isRecording ? Color("errorRed") : Color.accentColor)
                    .symbolEffect(.pulse, isActive: audio.isRecording)
            }
            .accessibilityLabel(Text(audio.isRecording ? "audio.stop" : "audio.record"))

            if audio.isRecording {
                Text("audio.recording")
                    .font(.caption)
                    .foregroundStyle(Color("errorRed"))
            } else if let active = audio.activeRecording, audio.isPlaying {
                Button {
                    audio.stopPlayback()
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.title3)
                }
                .accessibilityLabel(Text("audio.pause"))
                Slider(
                    value: Binding(
                        get: { audio.playbackTime },
                        set: { audio.seek(to: $0) }
                    ),
                    in: 0...max(active.duration, 1)
                )
                .frame(maxWidth: 180)
                Text(timeString(audio.playbackTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("audio.tapHint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !recordings.isEmpty {
                Menu {
                    ForEach(recordings, id: \.objectID) { recording in
                        Button {
                            audio.play(recording)
                        } label: {
                            Label(
                                (recording.createdAt ?? .now).formatted(date: .abbreviated, time: .shortened)
                                    + " · " + timeString(recording.duration),
                                systemImage: "play.circle"
                            )
                        }
                    }
                } label: {
                    Label("audio.recordings \(recordings.count)", systemImage: "waveform")
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .studyGlassCapsule()
        .accessibilityElement(children: .contain)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
