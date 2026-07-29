import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Set this before `start()`. Called once on the main queue when the system
    /// tap has gone `SystemAudioRecorder.silenceGrace` seconds without a single
    /// nonzero sample — almost always a missing Screen & System Audio Recording
    /// permission rather than a genuinely quiet call. Surfaced while the meeting
    /// is still young enough to be worth fixing.
    var onSystemSilence: (@Sendable () -> Void)?

    /// Loudest sample captured on each track, available after `stop()`.
    var peakLevels: (mic: Float, system: Float) { (mic.peak, system.peak) }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    ///
    /// `live` receives a copy of every captured buffer for on-the-fly
    /// transcription. It is a tee, never a dependency: recording does not wait
    /// for it, and buffers arriving before its models finish loading are simply
    /// dropped.
    func start(live: LiveTranscriber? = nil) throws {
        // Forwarded rather than wrapped: RecordingSession is not Sendable, so the
        // callback must not capture it.
        system.onProlongedSilence = onSystemSilence
        if let live {
            mic.onBuffer = { buffer in live.append(buffer, from: .me) }
            system.onBuffer = { buffer in live.append(buffer, from: .them) }
        }
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.onBuffer = nil
        system.onBuffer = nil
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        // Recorded so the failure is visible in the session itself, not only in
        // a notification that has already been dismissed.
        var warnings: [String] = []
        if system.peak == 0 {
            warnings.append(
                "system.caf contains only digital silence — the process tap ran but captured "
                    + "nothing. Grant Screen & System Audio Recording to whatever launched quill "
                    + "(the terminal app, if you started it from a shell), or install it as a "
                    + "LaunchAgent so it is attributed to itself."
            )
        }
        if mic.peak == 0 {
            warnings.append("mic.caf contains only digital silence — check Microphone permission.")
        }

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            "peak_level": [
                "mic": mic.peak,
                "system": system.peak,
            ],
        ]
        if !warnings.isEmpty {
            meta["warnings"] = warnings
            for warning in warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
