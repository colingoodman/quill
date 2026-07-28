import Foundation

/// One unit of transcript sized to fit a model context window, carrying the
/// wall-clock range of the segments that composed it.
///
/// The range is the reason this type exists. A small model asked to reproduce
/// timestamps invents them, and citation back into the audio is the thing
/// quill has that a generic summarizer does not. So timestamps are never
/// generated — they travel with the chunk and are re-attached to whatever the
/// model extracts from it.
struct TranscriptChunk: Sendable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
    /// Position in the sequence, for prompts that benefit from knowing where
    /// in the meeting they are ("early", "final") without being told the time.
    let index: Int
    let total: Int
}

/// Turns a canonical transcript into model-sized chunks.
///
/// Everything here is pure and synchronous so it can be tested without a
/// model. Token counting is approximated from a characters-per-token ratio the
/// caller supplies; the engine calibrates that ratio against the real
/// tokenizer once per transcript and verifies the assembled chunks, which
/// costs a handful of calls instead of one per candidate string.
enum TranscriptCompactor {
    /// Fallback ratio for English conversational text before calibration.
    /// Deliberately conservative — underestimating chars-per-token yields
    /// chunks that are too small, which is harmless, where overestimating
    /// throws `exceededContextWindowSize`.
    static let defaultCharsPerToken = 3.5

    /// Render segments compactly: a speaker label only when the speaker
    /// changes, no per-segment timestamps.
    ///
    /// `transcript.md` spends roughly `**[12:34] them:** ` on every segment,
    /// and `ParakeetEngine` cuts a segment at every sentence-ending token — so
    /// an hour of meeting carries thousands of tokens of pure scaffolding. This
    /// rendering drops all of it.
    static func compact(_ segments: [Transcript.Segment]) -> String {
        var lines: [String] = []
        var current: (speaker: String, parts: [String])?

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var open = current, open.speaker == segment.speaker {
                open.parts.append(text)
                current = open
            } else {
                if let open = current {
                    lines.append("\(open.speaker): \(open.parts.joined(separator: " "))")
                }
                current = (segment.speaker, [text])
            }
        }
        if let open = current {
            lines.append("\(open.speaker): \(open.parts.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    static func estimateTokens(_ text: String, charsPerToken: Double) -> Int {
        guard charsPerToken > 0 else { return text.count }
        return Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    /// Split segments into chunks that each fit `budget` tokens.
    ///
    /// `overlapFraction` re-includes a tail of the previous chunk so a boundary
    /// never severs an exchange — a question landing at the end of one chunk
    /// and its answer at the start of the next would otherwise both lose their
    /// meaning. Overlap is always strictly smaller than the chunk it follows,
    /// so the walk cannot stall.
    static func chunk(
        _ segments: [Transcript.Segment],
        budget: Int,
        charsPerToken: Double = defaultCharsPerToken,
        overlapFraction: Double = 0.1
    ) -> [TranscriptChunk] {
        let usable = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty, budget > 0 else { return [] }

        let budgetChars = Double(budget) * charsPerToken
        let overlapChars = budgetChars * max(0, min(overlapFraction, 0.5))

        var groups: [[Transcript.Segment]] = []
        var buffer: [Transcript.Segment] = []
        var bufferChars = 0.0

        /// Cost of appending a segment: its text, a separator, and the speaker
        /// label when the speaker changes. Mirrors what `compact` renders, so
        /// packing decisions track the real output without re-rendering.
        func cost(of segment: Transcript.Segment, following previous: Transcript.Segment?) -> Double {
            var chars = segment.text.count + 1
            if previous?.speaker != segment.speaker {
                chars += segment.speaker.count + 2
            }
            return Double(chars)
        }

        for segment in usable {
            let next = cost(of: segment, following: buffer.last)
            if !buffer.isEmpty, bufferChars + next > budgetChars {
                groups.append(buffer)
                // Seed the next buffer with a tail of this one, never the whole
                // thing, so progress is guaranteed even when a single segment
                // approaches the budget on its own.
                var tail: [Transcript.Segment] = []
                var tailChars = 0.0
                for candidate in buffer.reversed() {
                    let candidateChars = Double(candidate.text.count + candidate.speaker.count + 3)
                    if tailChars + candidateChars > overlapChars { break }
                    if tail.count >= buffer.count - 1 { break }
                    tail.insert(candidate, at: 0)
                    tailChars += candidateChars
                }
                buffer = tail
                bufferChars = tailChars
            }
            buffer.append(segment)
            bufferChars += next
        }
        if !buffer.isEmpty { groups.append(buffer) }

        return groups.enumerated().map { index, group in
            TranscriptChunk(
                text: compact(group),
                startMs: group.map(\.start_ms).min() ?? 0,
                endMs: group.map(\.end_ms).max() ?? 0,
                index: index,
                total: groups.count
            )
        }
    }

    /// Format a millisecond offset as the clock quill uses elsewhere.
    static func clock(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
