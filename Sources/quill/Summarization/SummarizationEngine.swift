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

/// How much of a context window is left for transcript once the instructions
/// and the model's own answer are accounted for.
///
/// Pure integer arithmetic, deliberately outside the macOS 26 gate: it has
/// nothing to do with FoundationModels and everything to do with whether a
/// chunk will fit.
enum SummarizationBudget {
    /// Reserved for the model's answer. Guided generation keeps output small,
    /// but the window is input *plus* output.
    static let reservedOutputTokens = 900
    /// Headroom for the schema the framework injects, and for drift between the
    /// calibration sample and the real chunk.
    static let safetyTokens = 200
    /// Smallest transcript slice worth asking about. Below this, chunks are too
    /// small to carry an exchange and the map step degenerates.
    static let minimumTokens = 400

    static func resolve(contextSize: Int, instructionTokens: Int) throws -> Int {
        let overhead = reservedOutputTokens + safetyTokens + instructionTokens
        let budget = contextSize - overhead
        guard budget > minimumTokens else {
            throw SummarizationError.permanent(
                "context window \(contextSize) too small after \(overhead) tokens of overhead"
            )
        }
        return budget
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

    /// Words too common to identify an utterance.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "for", "with",
        "at", "by", "from", "is", "are", "was", "were", "be", "been", "will", "would",
        "can", "could", "should", "that", "this", "it", "they", "we", "i", "you", "he",
        "she", "do", "does", "did", "have", "has", "had", "not", "no", "so", "if",
        "then", "than", "as", "about", "into", "up", "out", "s", "t", "our", "their",
        "them", "me", "my", "your", "there", "here", "what", "when", "who", "how",
    ]

    static func contentTokens(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter {
            $0.count > 2 && !stopwords.contains($0)
        })
    }

    /// Find when a claim was actually said, by matching its content words back
    /// against the transcript.
    ///
    /// The model paraphrases, so this is overlap scoring rather than search.
    /// Returns nil when nothing matches well enough — the renderer then omits
    /// the timestamp, which is the honest outcome. Stamping an item with the
    /// start of the chunk it came from looked precise and was not: a chunk is
    /// ~13 minutes of speech, so a short meeting is one chunk and every item
    /// claimed to happen at 0:00.
    static func locate(
        _ text: String,
        in segments: [Transcript.Segment],
        between startMs: Int,
        and endMs: Int,
        minimumOverlap: Double = 0.34,
        minimumShared: Int = 2
    ) -> Int? {
        let needle = contentTokens(text)
        // Below two content words there is nothing distinctive to match on.
        guard needle.count >= 2 else { return nil }

        var best: (score: Double, at: Int)?
        for segment in segments where segment.start_ms >= startMs && segment.start_ms <= endMs {
            let candidate = contentTokens(segment.text)
            guard !candidate.isEmpty else { continue }
            let shared = needle.intersection(candidate).count
            // A ratio alone is too weak for a short claim: three words sharing
            // one generic one ("Agreed on a new supplier") would clear 0.33.
            guard shared >= minimumShared else { continue }
            let score = Double(shared) / Double(needle.count)
            guard score >= minimumOverlap else { continue }
            // Ties go to the earliest utterance: a point restated later was
            // first made where it was first made.
            if best == nil || score > best!.score {
                best = (score, segment.start_ms)
            }
        }
        return best?.at
    }

    /// Whether a claim is traceable to something actually said.
    ///
    /// The narrative pass fabricates when given thin input — asked to fill a
    /// section from two extracted points it produced five bullets, four of them
    /// invented corporate filler ("agreed to continue to monitor the migration
    /// process"). Prompting for traceability did not stop it, so support is
    /// checked here instead.
    ///
    /// The cost is a bias toward extractive output: a bullet that correctly
    /// synthesises across three separate utterances may not overlap any single
    /// one enough to survive. That is the right trade at this model size, where
    /// synthesis is the weakest thing it does.
    /// Stricter than timestamp matching: a mislocated timestamp is a small
    /// error, while an unsupported bullet is a fabricated claim.
    static func isSupported(
        _ text: String,
        by segments: [Transcript.Segment],
        minimumOverlap: Double = 0.5
    ) -> Bool {
        locate(
            text, in: segments, between: 0, and: .max,
            minimumOverlap: minimumOverlap, minimumShared: 2
        ) != nil
    }

    /// Remove anything the model also filed as social.
    ///
    /// The model is asked to *sort* social talk into its own bucket rather than
    /// to omit it — a 3B model reliably files and unreliably suppresses. This is
    /// the second half of that bargain: whatever landed in the bucket is removed
    /// from everywhere else, so a topic leaking into both places still goes.
    static func removingSocial<T>(
        _ items: [T],
        smallTalk: [String],
        text: (T) -> String
    ) -> (kept: [T], dropped: [String]) {
        guard !smallTalk.isEmpty else { return (items, []) }
        var kept: [T] = []
        var dropped: [String] = []
        for item in items {
            let candidate = text(item)
            if smallTalk.contains(where: { isDuplicate($0, candidate) }) {
                dropped.append(candidate)
            } else {
                kept.append(item)
            }
        }
        return (kept, dropped)
    }

    /// Reject a "title" that is really a pile of keywords.
    ///
    /// Asked for a title, the model has produced things like
    /// "Panama-Colombia-Skydive-RF-Deader-Surface-Defect-Contracts-2027-Tickets":
    /// every topic in the meeting welded together with hyphens, led by whatever
    /// was said first. That is worse than a dull title, so it is checked here
    /// rather than asked for in the prompt.
    static func looksLikeKeywordDump(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.filter({ $0 == "-" }).count >= 3 { return true }
        if trimmed.split(separator: " ").count > 12 { return true }
        // A single hyphen-welded token with no spaces at all.
        if !trimmed.contains(" "), trimmed.contains("-") { return true }
        return false
    }

    /// A title we are willing to put at the top of the file.
    ///
    /// The model has produced every topic in the meeting welded together with
    /// hyphens and led by the first thing anyone said. The first usable section
    /// heading beats that; a dull constant beats both.
    static func usableTitle(
        _ candidate: String,
        sections: [MeetingNotes.Section],
        log: @Sendable (String) -> Void
    ) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !NotesMerger.looksLikeKeywordDump(trimmed) { return trimmed }
        log("reduce: rejected title \"\(trimmed.prefix(60))\" as a keyword dump")
        if let heading = sections.map(\.heading)
            .first(where: { !NotesMerger.looksLikeKeywordDump($0) })
        {
            return heading
        }
        return "Meeting notes"
    }

    /// Whether a line is actually a question. The model happily returns
    /// statements when asked for open questions, and "Ignored previous
    /// instructions." is not an open question.
    /// Longest a genuine open question runs before it is really a quotation.
    static let maximumQuestionWords = 20

    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // An interrogative opener is not enough on its own. The model has emitted
        // thirty-word verbatim transcript fragments that happen to begin with
        // "What", which sailed through the old check: "What one of the
        // optimization suggestions is that you can set an optimal number of
        // batches, and then kind of no matter what you receive…".
        guard trimmed.split(separator: " ").count <= maximumQuestionWords else { return false }
        // More than one sentence means it is prose, not a question.
        let body = trimmed.hasSuffix("?") || trimmed.hasSuffix(".")
            ? String(trimmed.dropLast())
            : trimmed
        guard !body.contains(". "), !body.contains("? ") else { return false }

        // Spoken questions arrive with the disfluency attached: "I mean, how many
        // do you and do you kind of like a range of things?" is a transcript
        // artefact, not something worth carrying into notes.
        let lowered = normalize(trimmed)
        for filler in ["i mean", "you know", "kind of", "sort of", "or whatever"] {
            if lowered.contains(filler) { return false }
        }

        if trimmed.hasSuffix("?") { return true }
        let opener = lowered.split(separator: " ").first.map(String.init) ?? ""
        return [
            "who", "what", "when", "where", "why", "how", "which", "whether",
            "will", "can", "should", "could", "does", "do", "is", "are", "if",
        ].contains(opener)
    }

    /// Drop items that restate something already present in `others`.
    ///
    /// The model routinely reports the same commitment as both a decision and an
    /// action item; the action item is the more useful record because it carries
    /// an owner, so decisions lose the tie.
    static func removing<T, U>(
        _ items: [T],
        duplicatedIn others: [U],
        text: (T) -> String,
        otherText: (U) -> String
    ) -> [T] {
        items.filter { item in
            !others.contains { isDuplicate(otherText($0), text(item)) }
        }
    }
}
