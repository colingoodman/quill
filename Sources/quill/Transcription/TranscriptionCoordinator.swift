import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case summarizing(session: String)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var summarizer: SummarizationEngine?
    /// Set when the model reports itself unavailable, so a queue of ten
    /// sessions does not produce ten identical failures in one drain.
    private var engineDown = false
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions with work outstanding: no
    /// transcript, or a transcript with no notes. Folder names sort
    /// chronologically, so oldest-first is a name sort.
    ///
    /// This is also the retry path for a rate-limited summarization — a
    /// background process on battery gets deferred, and the deferral resolves
    /// itself on the next drain or the next launch without any bookkeeping
    /// beyond what is already on disk.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter { dir in
                guard fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else {
                    return false
                }
                if !fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                    return true
                }
                return Self.needsSummary(dir)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) unfinished session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// Summaries are pending when the transcript exists, the notes do not, and
    /// no permanent failure was recorded. The marker is what stops a session
    /// that can never succeed — an unsupported language, a tripped guardrail —
    /// from being retried on every launch forever.
    private static func needsSummary(_ dir: URL) -> Bool {
        guard Config.summarizationEnabled() else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
            && !fm.fileExists(atPath: dir.appendingPathComponent("summary.json").path)
            && !fm.fileExists(atPath: dir.appendingPathComponent("summary.failed").path)
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        // A new drain re-checks availability: the user may have switched Apple
        // Intelligence on since the last one gave up.
        engineDown = false
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let hasTranscript = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("transcript.json").path
            )

            // A session resumed only for its notes must not be transcribed
            // again — that would spend minutes of model time reproducing a
            // transcript that is already on disk.
            if !hasTranscript {
                publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
                do {
                    try await transcribe(dir)
                    notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                } catch {
                    log(dir, "transcription failed: \(error)")
                    lastFailure = dir.lastPathComponent
                    notifyUser(
                        title: "quill — transcription failed",
                        body: "\(dir.lastPathComponent) — see transcribe.log"
                    )
                    continue
                }
            }

            if !engineDown, Self.needsSummary(dir) {
                publish(.summarizing(session: dir.lastPathComponent))
                await summarize(dir)
            }
            runHook(for: dir)
        }
        await engine?.release()
        engine = nil
        await summarizer?.release()
        summarizer = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Summarize one session. Failures never propagate: a missing summary is a
    /// degraded session, not a lost one, and the transcript is already safe on
    /// disk. Retryable failures leave nothing behind so the next drain retries;
    /// permanent ones write summary.failed so it does not retry forever.
    private func summarize(_ dir: URL) async {
        let template = Template.load(named: Config.summarizationTemplate())
        do {
            let engine = try await preparedSummarizer()
            let transcript = try Transcript.read(from: dir)
            guard !transcript.segments.isEmpty else {
                summaryLog(dir, "no segments to summarize")
                markSummaryFailed(dir, "transcript is empty")
                return
            }
            summaryLog(dir, "summarizing with \(engine.name) · template \(template.name)")
            var notes = try await engine.summarize(
                segments: transcript.segments,
                template: template,
                log: { [dir] message in Self.append(message, toSummaryLogIn: dir) }
            )
            if let calendarTitle = await Self.calendarTitle(for: dir) {
                notes = notes.withTitle(calendarTitle)
            }
            try notes.write(to: dir)
            summaryLog(dir, "done — \(notes.sections.count) section(s), "
                + "\(notes.decisions.count) decision(s), "
                + "\(notes.action_items.count) action(s)")
            notifyUser(title: "quill — notes ready", body: notes.title)
        } catch let error as SummarizationError {
            summaryLog(dir, "\(error)")
            if error.isEngineDown {
                engineDown = true
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
            if error.isRetryable {
                // Leave no marker: resumePending picks this up again.
                summarizer = nil
            } else {
                markSummaryFailed(dir, "\(error)")
                notifyUser(
                    title: "quill — notes skipped",
                    body: "\(dir.lastPathComponent) — see summarize.log"
                )
            }
        } catch {
            summaryLog(dir, "summarization failed: \(error)")
            markSummaryFailed(dir, "\(error)")
        }
    }

    private func preparedSummarizer() async throws -> SummarizationEngine {
        if let summarizer { return summarizer }
        guard #available(macOS 26.0, *) else {
            throw SummarizationError.unavailable("summarization needs macOS 26 or later")
        }
        let engine = AppleFoundationEngine()
        try await engine.prepare()
        summarizer = engine
        return engine
    }

    /// The calendar's name for this meeting, when the user has opted in. Reads
    /// the session's own start and end from meta.json — no calendar lookup
    /// happens at all unless the feature is switched on.
    nonisolated private static func calendarTitle(for dir: URL) async -> String? {
        guard Config.calendarTitles() else { return nil }
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let startedText = json["started"] as? String,
            let endedText = json["ended"] as? String
        else { return nil }

        let iso = ISO8601DateFormatter()
        guard let started = iso.date(from: startedText), let ended = iso.date(from: endedText) else {
            return nil
        }
        return await CalendarContext.title(from: started, to: ended) { message in
            append(message, toSummaryLogIn: dir)
        }
    }

    private func markSummaryFailed(_ dir: URL, _ reason: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(reason)\n"
        try? Data(line.utf8).write(to: dir.appendingPathComponent("summary.failed"))
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        Self.append(message, to: dir.appendingPathComponent("transcribe.log"))
    }

    private func summaryLog(_ dir: URL, _ message: String) {
        Self.append(message, toSummaryLogIn: dir)
    }

    /// Kept static and nonisolated so the engine can be handed a plain logging
    /// closure without capturing the actor.
    nonisolated private static func append(_ message: String, toSummaryLogIn dir: URL) {
        append(message, to: dir.appendingPathComponent("summarize.log"))
    }

    nonisolated private static func append(_ message: String, to url: URL) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. Internal rather than private because the
/// summarization pass reads it back.
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Read back a written transcript. The summarization pass reads
    /// transcript.json rather than transcript.md — the markdown spends a large
    /// fraction of its tokens on per-segment speaker and timestamp prefixes.
    static func read(from dir: URL) throws -> Transcript {
        let url = dir.appendingPathComponent("transcript.json")
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
