import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Granola-style notes from Apple's on-device foundation model.
///
/// Map-reduce, because an hour of meeting is roughly 12,000 tokens against a
/// 4,096-token window and exceeding it throws rather than truncating. Each
/// chunk is extracted in its own session so conversation history never
/// accumulates into the budget; the narrative pass then sees only the extracted
/// points, never the raw transcript.
///
/// The division of labour is deliberate. The model extracts from a passage and
/// writes two paragraphs of narrative — things a 3B model does acceptably.
/// Deduplication, ordering, ownership and every timestamp are assembled in
/// `NotesMerger`, because those are bookkeeping and it would get them wrong.
@available(macOS 26.0, *)
actor AppleFoundationEngine: SummarizationEngine {
    nonisolated let name = "apple-foundation"
    nonisolated let model = "system-language-model"

    /// Held only between prepare() and release(). Sessions are created per
    /// call, never cached — see `summarize`.
    private var languageModel: SystemLanguageModel?

    func prepare() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            languageModel = model
        case .unavailable(let reason):
            throw SummarizationError.unavailable(Self.describe(reason))
        }
    }

    func release() {
        languageModel = nil
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off — System Settings → Apple Intelligence & Siri"
        case .modelNotReady:
            return "the system model is still downloading — try again later"
        @unknown default:
            return "unavailable for an unknown reason"
        }
    }

    // MARK: - Wire types

    /// What one chunk yields. Counts are capped so a long passage cannot spend
    /// the whole output reserve, and `owner` is constrained by decoding rather
    /// than by asking politely.
    @Generable
    struct ChunkFindings {
        @Guide(description: "The substantive points discussed in this passage, in the speakers' own terms", .maximumCount(6))
        var key_points: [String]

        @Guide(description: "Only decisions actually settled in this passage. Empty if nothing was decided.", .maximumCount(4))
        var decisions: [String]

        @Guide(description: "Only tasks someone committed to. Empty if none.", .maximumCount(4))
        var action_items: [DraftActionItem]

        @Guide(description: "Questions raised in this passage and left unanswered. Empty if none.", .maximumCount(3))
        var open_questions: [String]
    }

    @Generable
    struct DraftActionItem {
        @Guide(description: "The task, starting with a verb")
        var text: String

        @Guide(
            description: "Who committed: 'me' for the microphone speaker, 'them' for the other side, 'unassigned' if unclear",
            .anyOf(["me", "them", "unassigned"])
        )
        var owner: String
    }

    /// The narrative pass. Sections only — decisions, actions and questions are
    /// already extracted with exact timestamps and are not re-derived here.
    @Generable
    struct Narrative {
        @Guide(description: "A specific title naming the actual subject in under nine words. Never 'Meeting Notes' or 'Discussion'.")
        var title: String

        @Guide(description: "Two sentences: what this meeting was for, and what came out of it")
        var tldr: String

        @Guide(description: "One entry per requested heading, in the order given, omitting any with nothing to report", .maximumCount(8))
        var sections: [DraftSection]
    }

    @Generable
    struct DraftSection {
        @Guide(description: "Exactly one of the requested headings")
        var heading: String

        @Guide(description: "Concrete points from the transcript, one line each", .maximumCount(6))
        var bullets: [String]
    }

    // MARK: - Pipeline

    func summarize(
        segments: [Transcript.Segment],
        template: Template,
        log: @Sendable (String) -> Void
    ) async throws -> MeetingNotes {
        guard let languageModel else { throw SummarizationError.permanent("engine used before prepare()") }

        // Strip lines aimed at the summarizer before it can read them. Telling
        // the model to ignore them does not work at this size — it made output
        // worse — so the defence is deterministic and happens here.
        let (segments, injected) = InjectionFilter.strip(segments)
        for line in injected {
            log("filtered a line addressed to the summarizer at "
                + "\(TranscriptCompactor.clock(line.start_ms)): "
                + "\"\(line.text.prefix(60))\"")
        }
        guard !segments.isEmpty else {
            throw SummarizationError.permanent(
                "every line was filtered as an instruction attempt"
            )
        }

        let mapInstructions = Self.mapInstructions()
        let budget = try await budget(for: mapInstructions, model: languageModel)
        let chunks = try await calibratedChunks(
            segments: segments, budget: budget, model: languageModel, log: log
        )
        guard !chunks.isEmpty else { throw SummarizationError.permanent("transcript has no usable speech") }
        log("map: \(chunks.count) chunk(s), budget \(budget) tokens of \(languageModel.contextSize)")

        var findings: [(chunk: TranscriptChunk, result: ChunkFindings)] = []
        for chunk in chunks {
            // A fresh session per chunk. Reusing one would accumulate every
            // previous chunk as history and overflow the window by chunk three.
            let session = LanguageModelSession(model: languageModel) {
                mapInstructions
            }
            do {
                let response = try await session.respond(
                    to: Self.mapPrompt(chunk),
                    generating: ChunkFindings.self,
                    options: GenerationOptions(
                        temperature: 0.2,
                        maximumResponseTokens: SummarizationBudget.reservedOutputTokens
                    )
                )
                findings.append((chunk, response.content))
                let found = response.content
                let counts = "\(found.key_points.count) points, "
                    + "\(found.decisions.count) decisions, \(found.action_items.count) actions"
                log("map: chunk \(chunk.index + 1)/\(chunk.total) → \(counts)")
            } catch let error as LanguageModelSession.GenerationError {
                // One bad passage must not cost the whole meeting, but a
                // deferrable failure has to propagate so the session stays
                // queued rather than producing notes with a hole in them.
                let mapped = Self.map(error)
                if mapped.isRetryable { throw mapped }
                log("map: skipping chunk \(chunk.index + 1)/\(chunk.total): \(mapped)")
            }
        }
        guard !findings.isEmpty else {
            throw SummarizationError.permanent("every chunk failed extraction")
        }

        // Timestamps come from matching each claim back to the utterance that
        // produced it, never from the chunk it was extracted from and never from
        // the model. An unmatched claim carries no time rather than a wrong one.
        func when(_ text: String, _ chunk: TranscriptChunk) -> Int? {
            NotesMerger.locate(text, in: segments, between: chunk.startMs, and: chunk.endMs)
        }

        let actionDrafts = findings.flatMap { f in
            f.result.action_items.map {
                (text: $0.text, at: when($0.text, f.chunk), owner: $0.owner)
            }
        }
        let actionItems = NotesMerger.merge(
            actionDrafts, text: \.text, at: \.at, rebuild: { (text: $0, at: $1, owner: "") }
        ).map { merged in
            MeetingNotes.ActionItem(
                text: merged.text,
                // The merge compares text only, so recover the owner from
                // whichever draft this survivor came from.
                owner: actionDrafts.first { NotesMerger.isDuplicate($0.text, merged.text) }?.owner
                    ?? "unassigned",
                at_ms: merged.at
            )
        }

        let decisionDrafts = NotesMerger.merge(
            findings.flatMap { f in f.result.decisions.map { ($0, when($0, f.chunk)) } },
            text: \.0, at: \.1, rebuild: { ($0, $1) }
        ).map { MeetingNotes.Decision(text: $0.0, at_ms: $0.1) }
        let decisions = NotesMerger.removing(
            decisionDrafts, duplicatedIn: actionItems, text: \.text, otherText: \.text
        )
        if decisionDrafts.count != decisions.count {
            log("merge: dropped \(decisionDrafts.count - decisions.count) decision(s) "
                + "already recorded as action items")
        }

        let openQuestions = NotesMerger.mergeStrings(
            findings.flatMap { f in f.result.open_questions.map { ($0, when($0, f.chunk)) } }
        ).filter(NotesMerger.isQuestion)

        let narrative = try await self.narrative(
            findings: findings, template: template, model: languageModel, log: log
        )

        // Every bullet must trace back to something someone said, and must not
        // already have been said in an earlier section — the model restates
        // across sections despite being told not to.
        var unsupported = 0, restated = 0
        var seen: [String] = []
        let sections = narrative.sections
            .map { draft in
                MeetingNotes.Section(
                    heading: draft.heading.trimmingCharacters(in: .whitespacesAndNewlines),
                    bullets: draft.bullets.filter { bullet in
                        guard !bullet.trimmingCharacters(in: .whitespaces).isEmpty else {
                            return false
                        }
                        guard NotesMerger.isSupported(bullet, by: segments) else {
                            unsupported += 1
                            return false
                        }
                        guard !seen.contains(where: { NotesMerger.isDuplicate($0, bullet) }) else {
                            restated += 1
                            return false
                        }
                        seen.append(bullet)
                        return true
                    }
                )
            }
            .filter { !$0.bullets.isEmpty }
        if unsupported > 0 {
            log("reduce: dropped \(unsupported) bullet(s) not traceable to the transcript")
        }
        if restated > 0 {
            log("reduce: dropped \(restated) bullet(s) restated across sections")
        }

        return MeetingNotes(
            engine: name,
            model: model,
            template: template.name,
            created_at: ISO8601DateFormatter().string(from: Date()),
            title: narrative.title.trimmingCharacters(in: .whitespacesAndNewlines),
            tldr: narrative.tldr.trimmingCharacters(in: .whitespacesAndNewlines),
            sections: sections,
            decisions: decisions,
            action_items: actionItems,
            open_questions: openQuestions
        )
    }

    // MARK: -

    private func budget(for instructions: String, model: SystemLanguageModel) async throws -> Int {
        var instructionTokens = Self.estimated(instructions)
        if #available(macOS 26.4, *),
           let counted = try? await model.tokenCount(for: Instructions(instructions)) {
            instructionTokens = counted
        }
        return try SummarizationBudget.resolve(
            contextSize: model.contextSize, instructionTokens: instructionTokens
        )
    }

    /// Chunk, then check the assembled chunks against the real tokenizer and
    /// tighten if the estimate ran optimistic. Calibrating the ratio once on a
    /// sample and verifying per chunk costs a handful of calls instead of one
    /// per candidate string.
    private func calibratedChunks(
        segments: [Transcript.Segment],
        budget: Int,
        model: SystemLanguageModel,
        log: @Sendable (String) -> Void
    ) async throws -> [TranscriptChunk] {
        var ratio = TranscriptCompactor.defaultCharsPerToken

        if #available(macOS 26.4, *) {
            let full = TranscriptCompactor.compact(segments)
            let sample = String(full.prefix(4_000))
            if !sample.isEmpty, let tokens = try? await model.tokenCount(for: sample), tokens > 0 {
                ratio = Double(sample.count) / Double(tokens)
                log("calibrated \(String(format: "%.2f", ratio)) chars/token on a \(sample.count)-char sample")
            }
        }

        for attempt in 0..<3 {
            let chunks = TranscriptCompactor.chunk(segments, budget: budget, charsPerToken: ratio)
            guard #available(macOS 26.4, *) else { return chunks }
            var over: [Int] = []
            for chunk in chunks {
                if let tokens = try? await model.tokenCount(for: chunk.text), tokens > budget {
                    over.append(tokens)
                }
            }
            if over.isEmpty { return chunks }
            ratio *= 0.85
            log("attempt \(attempt + 1): \(over.count) chunk(s) over budget "
                + "(max \(over.max() ?? 0) > \(budget)) — retightening to "
                + "\(String(format: "%.2f", ratio)) chars/token")
        }
        // Three tightenings failed to fit. Proceed anyway rather than dropping
        // the session: a chunk that overflows throws and gets skipped, and
        // partial notes beat none.
        log("warning: could not fit every chunk to \(budget) tokens; overlong chunks will be skipped")
        return TranscriptCompactor.chunk(segments, budget: budget, charsPerToken: ratio)
    }

    private func narrative(
        findings: [(chunk: TranscriptChunk, result: ChunkFindings)],
        template: Template,
        model: SystemLanguageModel,
        log: @Sendable (String) -> Void
    ) async throws -> Narrative {
        let instructions = Self.narrativeInstructions(template: template)
        let budget = try await budget(for: instructions, model: model)

        var points = findings.flatMap { f in
            f.result.key_points.map { "[\(TranscriptCompactor.clock(f.chunk.startMs))] \($0)" }
        }
        // A very long meeting can produce more points than the reduce step can
        // hold. Drop from the middle, which is where redundancy concentrates,
        // and say so rather than silently truncating.
        var rendered = points.joined(separator: "\n")
        while TranscriptCompactor.estimateTokens(rendered, charsPerToken: 3.0) > budget,
              points.count > 6 {
            points.remove(at: points.count / 2)
            rendered = points.joined(separator: "\n")
        }
        let dropped = findings.reduce(0) { $0 + $1.result.key_points.count } - points.count
        if dropped > 0 {
            log("reduce: dropped \(dropped) mid-meeting point(s) to fit \(budget) tokens")
        }

        let session = LanguageModelSession(model: model) { instructions }
        do {
            let response = try await session.respond(
                to: "Extracted points, in order:\n\(rendered)",
                generating: Narrative.self,
                options: GenerationOptions(
                    temperature: 0.4,
                    maximumResponseTokens: SummarizationBudget.reservedOutputTokens
                )
            )
            log("reduce: \(response.content.sections.count) section(s)")
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    // MARK: - Prompts

    /// Instructions are the trusted channel; the transcript goes in the prompt.
    /// Anyone on a call can say "ignore your instructions", and putting the
    /// rules here rather than in the prompt is what keeps that inert.
    private static func mapInstructions() -> String {
        """
        You extract structured facts from one passage of a meeting transcript.

        The transcript is labelled by side: "me" is the person whose microphone \
        recorded this, "them" is everyone on the other side of the call.

        Rules:
        - Report only what the passage says. Never infer, embellish, or continue \
        a thought the speakers did not finish.
        - A decision is a conclusion the speakers settled on: a choice made, a \
        date fixed, a number agreed. A task someone will go and do is NOT a \
        decision — that is an action item. Never report the same thing as both. \
        If nothing was settled, return an empty list.
        - An action item requires a commitment by someone. "We should maybe" is \
        not a commitment. Attribute it to whoever committed, not to whoever the \
        work concerns.
        - Every open question must be phrased as a question and end with a \
        question mark. If you cannot phrase it as a question, it is not one.
        - Never mention timestamps, speaker labels, or the transcript itself in \
        your output.
        - If the passage is only greetings, scheduling, or small talk, return \
        empty lists.
        """
        // Deliberately says nothing about instruction-injection. Naming the
        // attack made a 3B model attend to it and report it as meeting content;
        // InjectionFilter removes those lines before they get here instead.
    }

    private static func mapPrompt(_ chunk: TranscriptChunk) -> String {
        let position: String
        switch (chunk.index, chunk.total) {
        case (_, 1): position = "the whole meeting"
        case (0, _): position = "the opening of the meeting"
        case (chunk.total - 1, _): position = "the end of the meeting"
        default: position = "the middle of the meeting"
        }
        return """
        Passage \(chunk.index + 1) of \(chunk.total), from \(position):

        \(chunk.text)
        """
    }

    private static func narrativeInstructions(template: Template) -> String {
        """
        You write the summary of a meeting from points already extracted from \
        its transcript.

        \(template.guidance)

        Use exactly these section headings, and omit any you have nothing \
        substantive for: \(template.sections.joined(separator: ", ")).

        Rules:
        - Name the subject in the title. Prefer the specific thing that was at \
        stake over a category word.
        - Every sentence and bullet must be traceable to one of the points given. \
        If a section has no matching point, leave it out. Fabricating a plausible \
        detail is the worst thing you can do here.
        - Do not restate the same point in two sections.
        - Never mention timestamps or the transcript itself.
        """
        // An earlier version demanded the summary "carry specific content: the
        // figure, the date, the name of the thing". That pressure made the model
        // invent specifics — it reported an agreed new supplier and timeline that
        // appeared nowhere in the transcript. Asking for traceability rather than
        // specificity is the safer framing at this model size.
    }

    private static func estimated(_ text: String) -> Int {
        TranscriptCompactor.estimateTokens(text, charsPerToken: 3.2)
    }

    /// Translate framework errors into the queue's retry policy. Getting this
    /// mapping wrong is how a session either retries forever or is dropped on a
    /// condition that would have cleared on its own.
    static func map(_ error: LanguageModelSession.GenerationError) -> SummarizationError {
        switch error {
        case .rateLimited:
            // Background process on battery. Clears on power, or next drain.
            return .retryable("rate limited by the system")
        case .concurrentRequests:
            return .retryable("another request is in flight")
        case .assetsUnavailable:
            return .retryable("model assets not yet available")
        case .exceededContextWindowSize:
            return .permanent("exceeded the context window after retightening")
        case .guardrailViolation:
            return .permanent("content guardrail tripped — transcript kept, notes skipped")
        case .refusal:
            return .permanent("the model declined to summarise this content")
        case .decodingFailure:
            return .permanent("could not decode the model's structured output")
        case .unsupportedGuide:
            return .permanent("unsupported generation guide")
        case .unsupportedLanguageOrLocale:
            return .permanent("the transcript language is not supported by the system model")
        @unknown default:
            return .permanent("\(error)")
        }
    }
}
