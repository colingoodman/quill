import Foundation
import Testing

@testable import quill

private func seg(_ speaker: String, _ text: String, _ start: Int, _ end: Int)
    -> Transcript.Segment
{
    Transcript.Segment(speaker: speaker, start_ms: start, end_ms: end, text: text)
}

/// A transcript shaped like a real one: short segments, because
/// `ParakeetEngine` cuts at every sentence-ending token, arriving in runs,
/// because a person says several sentences before the other side replies.
/// `runLength: 1` is the pathological case where speakers strictly alternate.
private func syntheticSegments(turns: Int, runLength: Int = 3) -> [Transcript.Segment] {
    (0..<turns).map { i in
        seg(
            (i / max(1, runLength)).isMultiple(of: 2) ? "me" : "them",
            "This is sentence number \(i) and it runs about this long in practice.",
            i * 4_000,
            i * 4_000 + 3_500
        )
    }
}

/// What `Transcript.rendered` writes to transcript.md, for comparison.
private func markdownRendering(_ segments: [Transcript.Segment]) -> String {
    segments.map {
        "**[\(TranscriptCompactor.clock($0.start_ms))] \($0.speaker):** \($0.text)\n"
    }.joined(separator: "\n")
}

@Suite("compact rendering")
struct CompactTests {
    @Test("labels a speaker only when the speaker changes")
    func collapsesRuns() {
        let text = TranscriptCompactor.compact([
            seg("me", "One.", 0, 1000),
            seg("me", "Two.", 1000, 2000),
            seg("them", "Three.", 2000, 3000),
        ])
        #expect(text == "me: One. Two.\nthem: Three.")
    }

    @Test("emits no timestamps at all")
    func noTimestamps() {
        let text = TranscriptCompactor.compact(syntheticSegments(turns: 20))
        #expect(!text.contains("["))
        #expect(!text.contains(":0"))
    }

    @Test("drops blank and whitespace-only segments")
    func dropsEmpties() {
        let text = TranscriptCompactor.compact([
            seg("me", "Kept.", 0, 1000),
            seg("me", "   ", 1000, 2000),
            seg("me", "", 2000, 3000),
        ])
        #expect(text == "me: Kept.")
    }

    @Test("is empty for no input")
    func empty() {
        #expect(TranscriptCompactor.compact([]) == "")
    }

    /// The premise of the whole design: transcript.md is prefix-heavy enough
    /// that feeding it directly would waste a large share of a 4,096-token
    /// window on scaffolding.
    /// Measures ~18% on this shape. The threshold sits below that as a
    /// regression guard, not as an aspiration — as a share of total characters
    /// the saving is modest, because the spoken words dominate. See
    /// `scaffoldingOverhead` for the number the design actually rests on.
    @Test("saves a sixth of the characters versus the markdown rendering")
    func beatsMarkdownRendering() {
        let segments = syntheticSegments(turns: 200)
        let compact = TranscriptCompactor.compact(segments)
        let saved = 1 - Double(compact.count) / Double(markdownRendering(segments).count)
        #expect(saved > 0.15, "expected >15% saving, got \(Int(saved * 100))%")
    }

    /// Strict alternation is the floor: every segment needs its own label, so
    /// collapsing runs saves nothing and only the timestamp prefix goes. Worth
    /// pinning, because it is the number a debate-heavy meeting actually gets.
    @Test("still saves over a tenth when speakers strictly alternate")
    func worstCaseAlternation() {
        let segments = syntheticSegments(turns: 200, runLength: 1)
        let compact = TranscriptCompactor.compact(segments)
        let saved = 1 - Double(compact.count) / Double(markdownRendering(segments).count)
        #expect(saved > 0.10, "expected >10% saving, got \(Int(saved * 100))%")
    }

    /// The saving that matters is measured against scaffolding, not against
    /// total text — the words dominate either way. An hour of meeting is ~700
    /// segments, and this is what the prefixes alone cost.
    @Test("removes most of the per-segment scaffolding")
    func scaffoldingOverhead() {
        let segments = syntheticSegments(turns: 700)
        let words = segments.reduce(0) { $0 + $1.text.count }
        let markdownOverhead = markdownRendering(segments).count - words
        let compactOverhead = TranscriptCompactor.compact(segments).count - words

        #expect(markdownOverhead > 12_000)
        #expect(Double(compactOverhead) < Double(markdownOverhead) * 0.25)
        // At ~3.5 chars/token that is thousands of tokens against a 4,096 window.
        let savedTokens = TranscriptCompactor.estimateTokens(
            String(repeating: "x", count: markdownOverhead - compactOverhead),
            charsPerToken: TranscriptCompactor.defaultCharsPerToken
        )
        #expect(savedTokens > 2_500, "only \(savedTokens) tokens saved")
    }
}

@Suite("chunking")
struct ChunkTests {
    let ratio = TranscriptCompactor.defaultCharsPerToken

    @Test("no chunks for no segments")
    func empty() {
        #expect(TranscriptCompactor.chunk([], budget: 1000).isEmpty)
    }

    @Test("no chunks for a non-positive budget")
    func zeroBudget() {
        #expect(TranscriptCompactor.chunk(syntheticSegments(turns: 5), budget: 0).isEmpty)
    }

    @Test("a short transcript stays a single chunk")
    func singleChunk() {
        let chunks = TranscriptCompactor.chunk(syntheticSegments(turns: 4), budget: 3_000)
        #expect(chunks.count == 1)
        #expect(chunks[0].index == 0)
        #expect(chunks[0].total == 1)
    }

    @Test("a long transcript splits into several chunks")
    func splits() {
        let chunks = TranscriptCompactor.chunk(syntheticSegments(turns: 400), budget: 3_000)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.total == chunks.count)
        }
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
    }

    @Test("every chunk fits the budget")
    func respectsBudget() {
        let budget = 800
        let chunks = TranscriptCompactor.chunk(
            syntheticSegments(turns: 400), budget: budget, charsPerToken: ratio
        )
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            let estimate = TranscriptCompactor.estimateTokens(chunk.text, charsPerToken: ratio)
            #expect(estimate <= budget, "chunk \(chunk.index) estimated \(estimate) > \(budget)")
        }
    }

    @Test("consecutive chunks overlap so a boundary never severs an exchange")
    func overlaps() {
        let chunks = TranscriptCompactor.chunk(
            syntheticSegments(turns: 300), budget: 900, overlapFraction: 0.1
        )
        #expect(chunks.count > 2)
        // An overlapping tail means the next chunk starts at or before the
        // previous chunk's end.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.startMs <= previous.endMs)
        }
    }

    @Test("no segment text is lost")
    func losesNothing() {
        let segments = syntheticSegments(turns: 120)
        let chunks = TranscriptCompactor.chunk(segments, budget: 700)
        let combined = chunks.map(\.text).joined(separator: "\n")
        for segment in segments {
            #expect(combined.contains(segment.text), "lost: \(segment.text)")
        }
    }

    @Test("time ranges follow the segments that composed each chunk")
    func ranges() {
        let segments = syntheticSegments(turns: 200)
        let chunks = TranscriptCompactor.chunk(segments, budget: 700)
        #expect(chunks.first?.startMs == segments.first?.start_ms)
        #expect(chunks.last?.endMs == segments.last?.end_ms)
        for chunk in chunks {
            #expect(chunk.startMs <= chunk.endMs)
        }
    }

    /// A single segment larger than the whole budget must still terminate and
    /// still be emitted rather than dropped silently.
    @Test("a single oversized segment is emitted alone and does not stall")
    func oversizedSegment() {
        let huge = String(repeating: "word ", count: 4_000)
        let chunks = TranscriptCompactor.chunk(
            [
                seg("me", "Before.", 0, 1_000),
                seg("them", huge, 1_000, 60_000),
                seg("me", "After.", 60_000, 61_000),
            ],
            budget: 200
        )
        #expect(chunks.count >= 2)
        #expect(chunks.contains { $0.text.contains("Before.") })
        #expect(chunks.contains { $0.text.contains("After.") })
        #expect(chunks.contains { $0.text.count > 1_000 })
    }

    @Test("an hour-scale transcript produces a handful of chunks, not dozens")
    func realisticShape() {
        // ~8,500 words is roughly an hour of conversational speech.
        let segments = (0..<700).map { i in
            seg(
                i.isMultiple(of: 2) ? "me" : "them",
                "Roughly twelve words of ordinary meeting speech in this particular segment here.",
                i * 5_000,
                i * 5_000 + 4_500
            )
        }
        // Budget after instructions and reserved output on a 4,096 window.
        let chunks = TranscriptCompactor.chunk(segments, budget: 3_000)
        #expect(chunks.count >= 2)
        #expect(chunks.count <= 12, "got \(chunks.count) chunks; reduce step expects a handful")
    }
}

@Suite("token estimation")
struct EstimateTests {
    @Test("scales with length and rounds up")
    func scales() {
        #expect(TranscriptCompactor.estimateTokens("", charsPerToken: 3.5) == 0)
        #expect(TranscriptCompactor.estimateTokens("abc", charsPerToken: 3.5) == 1)
        #expect(TranscriptCompactor.estimateTokens(String(repeating: "a", count: 350),
                                                  charsPerToken: 3.5) == 100)
    }

    @Test("degrades to character count for a nonsense ratio")
    func guardsZero() {
        #expect(TranscriptCompactor.estimateTokens("abcd", charsPerToken: 0) == 4)
    }
}

@Suite("clock formatting")
struct ClockTests {
    @Test("matches the format used elsewhere in quill")
    func formats() {
        #expect(TranscriptCompactor.clock(0) == "0:00")
        #expect(TranscriptCompactor.clock(61_000) == "1:01")
        #expect(TranscriptCompactor.clock(3_661_000) == "1:01:01")
        #expect(TranscriptCompactor.clock(-5) == "0:00")
    }
}
