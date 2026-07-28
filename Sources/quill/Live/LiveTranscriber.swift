@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Hands exclusive ownership of an audio buffer across an isolation boundary.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and rightly so — but these buffers are
/// freshly copied by `copyingFrames()` and never touched again by the producer,
/// so the transfer really is exclusive. The wrapper states that intent rather
/// than weakening the type globally.
private struct SentBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Best-effort transcription while the meeting is still happening.
///
/// Deliberately ephemeral. The canonical transcript is still produced by the
/// offline pass after recording stops, which sees whole files, aligns both
/// tracks on one clock, and is more accurate. This exists so you can watch the
/// thing work and confirm the mic is live — not to replace that.
///
/// One `SlidingWindowAsrManager` per track, so `mic.caf` → "me" and
/// `system.caf` → "them" exactly as the offline pass labels them. Sliding-window
/// mode reuses the Parakeet models quill already downloads; no second model and
/// no extra dependency.
actor LiveTranscriber {
    enum Track: String, Sendable, CaseIterable {
        case me, them

        var source: AudioSource { self == .me ? .microphone : .system }
    }

    /// One line of live transcript. Confirmed lines are final for the live view;
    /// a volatile line is the current in-flight guess and will be replaced.
    struct Line: Identifiable, Sendable, Equatable {
        let id = UUID()
        let speaker: String
        let text: String
        let isConfirmed: Bool
    }

    private var managers: [Track: SlidingWindowAsrManager] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var running = false

    /// Load models and begin. Slow enough (CoreML load) that the caller should
    /// not wait on it before starting to record — buffers arriving before this
    /// finishes are dropped, which costs a second of live text and nothing else.
    func start(onLine: @escaping @Sendable (Line) -> Void) async throws {
        guard !running else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)

        for track in Track.allCases {
            let manager = SlidingWindowAsrManager(config: .streaming)
            try await manager.loadModels(models)

            // Take the update stream before streaming starts: the property
            // installs the continuation, and anything emitted before it exists
            // is lost.
            let updates = await manager.transcriptionUpdates
            try await manager.startStreaming(source: track.source)
            managers[track] = manager

            pumps.append(
                Task { [weak self] in
                    for await update in updates {
                        guard let self else { return }
                        await self.forward(update, from: track, to: onLine)
                    }
                }
            )
        }
        running = true
    }

    /// Feed captured audio. Called from the audio tap, so it must not block:
    /// the buffer is copied and handed off, and everything else happens later.
    nonisolated func append(_ buffer: AVAudioPCMBuffer, from track: Track) {
        guard let copy = buffer.copyingFrames() else { return }
        let sent = SentBuffer(buffer: copy)
        Task { await self.deliver(sent, to: track) }
    }

    func stop() async {
        running = false
        for pump in pumps { pump.cancel() }
        pumps = []
        for manager in managers.values {
            // finish() flushes the tail; we discard it because the offline pass
            // produces the transcript that gets kept.
            _ = try? await manager.finish()
            await manager.cleanup()
        }
        managers = [:]
    }

    // MARK: -

    private func deliver(_ sent: SentBuffer, to track: Track) async {
        guard let manager = managers[track] else { return }
        await manager.streamAudio(sent.buffer)
    }

    private func forward(
        _ update: SlidingWindowTranscriptionUpdate,
        from track: Track,
        to onLine: @escaping @Sendable (Line) -> Void
    ) async {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onLine(Line(speaker: track.rawValue, text: text, isConfirmed: update.isConfirmed))
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy that outlives the audio callback.
    ///
    /// Tap buffers are only valid for the duration of the callback, and the
    /// system tap's are built with `bufferListNoCopy` over memory Core Audio
    /// owns. Copying via the buffer list keeps this format-agnostic — the mic is
    /// mono float32 while the tap can be interleaved multichannel.
    func copyingFrames() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else {
                return nil
            }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }
}
