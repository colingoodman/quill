import ArgumentParser
import Foundation

/// A command failure with a message worth reading. ArgumentParser prints it and
/// exits non-zero, so a script wrapping quill can tell the difference between
/// "no notes because the model is off" and success.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Summarize one session on demand.
///
/// The daemon summarizes automatically, but that is a slow loop to iterate in:
/// you would have to delete summary.json and restart quill to try a different
/// template. This runs the same pipeline against a session that already has a
/// transcript, so notes can be regenerated in seconds — which is also what
/// makes the feature testable by hand without recording a meeting first.
///
/// Deliberately ignores `summarization.enabled`: asking for notes explicitly is
/// consent enough, and requiring a config edit before you can try the feature
/// once would be a silly gate.
struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write notes for a session that already has a transcript."
    )

    @Argument(help: "Session directory containing transcript.json.")
    var directory: String

    @Option(name: .long, help: "Template to use (default: the configured one).")
    var template: String?

    @Flag(name: .long, help: "Print the notes instead of writing summary.json/summary.md.")
    var print: Bool = false

    @Flag(name: .long, help: "Re-summarize even if summary.json already exists.")
    var force: Bool = false

    func run() async throws {
        let dir = URL(
            fileURLWithPath: (directory as NSString).expandingTildeInPath,
            isDirectory: true
        )

        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path
        ) else {
            throw ValidationError("no transcript.json in \(dir.path)")
        }
        let existing = dir.appendingPathComponent("summary.json")
        if !print, !force, FileManager.default.fileExists(atPath: existing.path) {
            throw ValidationError(
                "summary.json already exists in \(dir.path) — pass --force to replace it, "
                    + "or --print to see the result without writing"
            )
        }

        guard #available(macOS 26.0, *) else {
            throw Failure("summarization needs macOS 26 or later")
        }

        let transcript = try Transcript.read(from: dir)
        guard !transcript.segments.isEmpty else {
            throw Failure("\(dir.lastPathComponent) has no transcript segments")
        }
        let chosen = Template.load(named: template ?? Config.summarizationTemplate())

        let words = transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        note("session:  \(dir.lastPathComponent)")
        note("segments: \(transcript.segments.count) (~\(words) words)")
        note("template: \(chosen.name) — \(chosen.sections.joined(separator: " · "))")

        let engine = AppleFoundationEngine()
        do {
            try await engine.prepare()
        } catch let error as SummarizationError {
            // The overwhelmingly common case is that Apple Intelligence is off,
            // so say what to do rather than just what failed.
            throw Failure("\(error)")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let notes: MeetingNotes
        do {
            notes = try await engine.summarize(
                segments: transcript.segments,
                template: chosen,
                log: { message in note(message) }
            )
        } catch let error as SummarizationError {
            throw Failure("\(error)")
        }
        note("elapsed:  \(start.duration(to: clock.now))")
        await engine.release()

        if print {
            Swift.print(notes.rendered())
        } else {
            try notes.write(to: dir)
            note("wrote \(dir.appendingPathComponent("summary.md").lastPathComponent) "
                + "and summary.json")
            Swift.print(notes.rendered())
        }
    }

    /// Progress goes to stderr so `--print` can be piped or redirected cleanly.
    private func note(_ message: String) {
        FileHandle.standardError.write(Data("· \(message)\n".utf8))
    }
}
