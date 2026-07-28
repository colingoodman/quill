import Foundation

/// Granola-style notes for one session. Property names are the JSON schema —
/// this struct exists to be serialized, like `Transcript`.
///
/// Deliberately not `@Generable`: the model produces narrative fields and
/// extraction drafts, while ownership, deduplication, ordering and timestamps
/// are assembled in Swift. A small model is good at extracting from a passage
/// and bad at bookkeeping across a whole meeting, so the bookkeeping stays
/// here where it is deterministic and testable.
struct MeetingNotes: Codable, Equatable {
    struct Section: Codable, Equatable {
        let heading: String
        let bullets: [String]
    }

    /// `at_ms` is the start of the chunk the item was extracted from, never a
    /// figure the model produced. It is nil only for items that survived a
    /// merge with no positional evidence.
    struct Decision: Codable, Equatable {
        let text: String
        let at_ms: Int?
    }

    struct ActionItem: Codable, Equatable {
        let text: String
        /// "me", "them", or "unassigned" — attribution is filesystem-based, so
        /// every remote participant collapses into a single "them".
        let owner: String
        let at_ms: Int?
    }

    let engine: String
    let model: String
    let template: String
    let created_at: String
    let title: String
    let tldr: String
    let sections: [Section]
    let decisions: [Decision]
    let action_items: [ActionItem]
    let open_questions: [String]

    /// Replace the model's title, for when the calendar knows the meeting's
    /// real name.
    func withTitle(_ replacement: String) -> MeetingNotes {
        MeetingNotes(
            engine: engine, model: model, template: template, created_at: created_at,
            title: replacement, tldr: tldr, sections: sections, decisions: decisions,
            action_items: action_items, open_questions: open_questions
        )
    }

    /// Write summary.json and render summary.md. Both atomic, so a partially
    /// written summary never exists on disk — the queue treats the presence of
    /// summary.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
        try Data(rendered().utf8)
            .write(to: dir.appendingPathComponent("summary.md"), options: .atomic)
    }

    func rendered() -> String {
        var lines = ["# \(title)", ""]
        if !tldr.isEmpty {
            lines += [tldr, ""]
        }

        for section in sections where !section.bullets.isEmpty {
            lines.append("## \(section.heading)")
            lines.append("")
            lines += section.bullets.map { "- \($0)" }
            lines.append("")
        }

        if !decisions.isEmpty {
            lines += ["## Decisions", ""]
            lines += decisions.map { decision in
                decision.at_ms.map { "- [\(TranscriptCompactor.clock($0))] \(decision.text)" }
                    ?? "- \(decision.text)"
            }
            lines.append("")
        }

        if !action_items.isEmpty {
            lines += ["## Action items", ""]
            lines += action_items.map { item in
                let stamp = item.at_ms.map { " · \(TranscriptCompactor.clock($0))" } ?? ""
                return "- [ ] **\(item.owner)** — \(item.text)\(stamp)"
            }
            lines.append("")
        }

        if !open_questions.isEmpty {
            lines += ["## Open questions", ""]
            lines += open_questions.map { "- \($0)" }
            lines.append("")
        }

        lines += ["---", "", "notes: \(engine) (\(model)) · template: \(template)"]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Why a summarization attempt stopped, and whether trying again could help.
///
/// The distinction drives the queue: a retryable failure leaves the session
/// pending so the next drain picks it up, which is how the rate limit that
/// applies to background processes on battery resolves itself. A permanent
/// failure writes a marker so the session is not retried forever.
enum SummarizationError: Error, CustomStringConvertible {
    /// The model cannot be reached at all — Apple Intelligence switched off,
    /// assets still downloading, OS too old. Retryable, because every cause is
    /// something that can change without the transcript changing: writing a
    /// permanent marker here would mean sessions recorded before the user
    /// enabled Apple Intelligence could never be backfilled.
    case unavailable(String)
    /// This attempt failed but the next may not — rate limiting, contention.
    case retryable(String)
    /// This transcript will never summarize: guardrail, unsupported language,
    /// undecodable output.
    case permanent(String)

    var isRetryable: Bool {
        switch self {
        case .unavailable, .retryable: return true
        case .permanent: return false
        }
    }

    /// True when the whole engine is down, so the rest of the queue should stop
    /// trying this drain instead of failing once per session.
    var isEngineDown: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .unavailable(let s): return "summarization unavailable: \(s)"
        case .retryable(let s): return "summarization deferred: \(s)"
        case .permanent(let s): return "summarization failed: \(s)"
        }
    }
}

/// A local model that turns a transcript into notes. Mirrors
/// `TranscriptionEngine`: prepared lazily when the queue has work, released
/// when it drains, so quill never idles holding a model session.
///
/// The engine takes segments rather than pre-made chunks because only it knows
/// the context budget and owns the tokenizer.
protocol SummarizationEngine: Sendable {
    var name: String { get }
    var model: String { get }
    func prepare() async throws
    func summarize(
        segments: [Transcript.Segment],
        template: Template,
        log: @Sendable (String) -> Void
    ) async throws -> MeetingNotes
    func release() async
}

/// Cross-chunk bookkeeping: deduplicate what overlapping chunks found twice,
/// keep the earliest evidence, and order by time.
///
/// Pure and synchronous — this is the half of the pipeline that must not be
/// left to a 3B model, and the half that can be tested without one.
enum NotesMerger {
    /// Comparison key: case- and punctuation-insensitive, whitespace collapsed.
    static func normalize(_ text: String) -> String {
        let folded = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(folded).split(separator: " ").joined(separator: " ")
    }

    /// True when one string says the same thing as the other: equal after
    /// normalization, or one contains the other and they are close enough in
    /// length that the shorter is a restatement rather than a separate point.
    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard long.contains(short) else { return false }
        return Double(short.count) / Double(long.count) > 0.6
    }

    /// Collapse duplicates, preferring the longest phrasing but the earliest
    /// timestamp — chunk overlap means the same point legitimately appears in
    /// two adjacent chunks, and the earlier one is where it was actually said.
    static func merge<T>(
        _ items: [T],
        text: (T) -> String,
        at: (T) -> Int?,
        rebuild: (String, Int?) -> T
    ) -> [T] {
        var kept: [(text: String, at: Int?)] = []
        for item in items {
            let candidate = text(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            if let index = kept.firstIndex(where: { isDuplicate($0.text, candidate) }) {
                let existing = kept[index]
                kept[index] = (
                    text: existing.text.count >= candidate.count ? existing.text : candidate,
                    at: [existing.at, at(item)].compactMap { $0 }.min()
                )
            } else {
                kept.append((text: candidate, at: at(item)))
            }
        }
        return kept
            .sorted { ($0.at ?? Int.max, $0.text) < ($1.at ?? Int.max, $1.text) }
            .map { rebuild($0.text, $0.at) }
    }

    static func mergeStrings(_ items: [(String, Int?)]) -> [String] {
        merge(items, text: \.0, at: \.1, rebuild: { ($0, $1) }).map(\.0)
    }
}
