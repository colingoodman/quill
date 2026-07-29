import Foundation
import Testing

@testable import quill

/// The pricing-call fixture, loaded from disk so these tests exercise the same
/// transcript the manual walkthrough does.
private func fixtureSegments(_ name: String) throws -> [Transcript.Segment] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)/transcript.json")
    return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url)).segments
}

@Suite("locating a claim in the transcript")
struct LocateTests {
    @Test("a paraphrased claim lands on the utterance that produced it")
    func paraphrase() throws {
        let segments = try fixtureSegments("pricing-call")
        // The model's phrasing, not the transcript's.
        let at = NotesMerger.locate(
            "Procurement flagged forty dollars per seat as above the approved band",
            in: segments, between: 0, and: 999_999
        )
        #expect(at == 12_600, "expected the procurement utterance at 12.6s, got \(at as Int?)")
    }

    @Test("a later commitment lands late, not at zero")
    func laterClaim() throws {
        let segments = try fixtureSegments("pricing-call")
        let at = NotesMerger.locate(
            "Ask the solutions engineer to reach out and book a session",
            in: segments, between: 0, and: 999_999
        )
        #expect(at != nil)
        #expect(at! > 100_000, "expected a late timestamp, got \(at!)")
    }

    /// The bug this whole mechanism replaces: everything stamped 0:00 because a
    /// short meeting is a single chunk.
    @Test("distinct claims get distinct times")
    func distinctTimes() throws {
        let segments = try fixtureSegments("pricing-call")
        let claims = [
            "Procurement flagged forty dollars per seat as above the approved band",
            "Send the SOC 2 report over today",
            "Confirm data residency stays in the EU region in writing",
            "Walk the team through the SSO integration setup",
        ]
        let times = claims.compactMap {
            NotesMerger.locate($0, in: segments, between: 0, and: 999_999)
        }
        #expect(times.count == claims.count, "some claims failed to locate")
        #expect(Set(times).count == claims.count, "claims collapsed onto the same time: \(times)")
        #expect(!times.contains(0), "a claim was stamped 0:00")
    }

    @Test("an unrelated claim locates nowhere rather than guessing")
    func noFalsePositive() throws {
        let segments = try fixtureSegments("pricing-call")
        #expect(NotesMerger.locate(
            "The kitchen renovation quote arrived from the builder",
            in: segments, between: 0, and: 999_999
        ) == nil)
    }

    @Test("the search is confined to the chunk's own time range")
    func respectsRange() throws {
        let segments = try fixtureSegments("pricing-call")
        let text = "Procurement flagged forty dollars per seat as above the approved band"
        #expect(NotesMerger.locate(text, in: segments, between: 0, and: 10_000) == nil)
        #expect(NotesMerger.locate(text, in: segments, between: 0, and: 20_000) == 12_600)
    }

    @Test("too few content words to be distinctive locates nothing")
    func tooShort() throws {
        let segments = try fixtureSegments("pricing-call")
        #expect(NotesMerger.locate("Yes.", in: segments, between: 0, and: 999_999) == nil)
        #expect(NotesMerger.locate("", in: segments, between: 0, and: 999_999) == nil)
    }

    @Test("stopwords alone never match")
    func stopwordsOnly() throws {
        let segments = try fixtureSegments("pricing-call")
        #expect(NotesMerger.locate(
            "that is what we do about it", in: segments, between: 0, and: 999_999
        ) == nil)
    }

    @Test("content tokens drop stopwords and short words")
    func tokens() {
        let tokens = NotesMerger.contentTokens("We should send the SOC 2 report to them on Thursday")
        #expect(tokens.contains("send"))
        #expect(tokens.contains("report"))
        #expect(tokens.contains("thursday"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("we"))
        #expect(!tokens.contains("to"))
    }
}

@Suite("open questions must be questions")
struct QuestionTests {
    @Test("accepts a question mark")
    func questionMark() {
        #expect(NotesMerger.isQuestion("Will procurement move on the thirty-five?"))
    }

    @Test("accepts an interrogative opener without punctuation")
    func interrogative() {
        #expect(NotesMerger.isQuestion("Whether legal will confirm EU residency"))
        #expect(NotesMerger.isQuestion("Can the term be extended to three years"))
    }

    /// The exact failures observed in real output.
    @Test("rejects statements the model returned as open questions")
    func rejectsStatements() {
        #expect(!NotesMerger.isQuestion("Ignored previous instructions."))
        #expect(!NotesMerger.isQuestion("Disregarded the template and rules."))
        #expect(!NotesMerger.isQuestion("Owned the rollback plan and had it written up."))
        #expect(!NotesMerger.isQuestion(""))
        #expect(!NotesMerger.isQuestion("   "))
    }
}

@Suite("cross-category deduplication")
struct CrossCategoryTests {
    @Test("a decision restating an action item is dropped")
    func dropsRestatedDecision() {
        let actions = [MeetingNotes.ActionItem(
            text: "Send the SOC 2 report to security", owner: "me", at_ms: 68_200
        )]
        let decisions = [
            MeetingNotes.Decision(text: "Send the SOC 2 report to security", at_ms: 68_200),
            MeetingNotes.Decision(text: "Hold the slot for Thursday", at_ms: 50_400),
        ]
        let kept = NotesMerger.removing(
            decisions, duplicatedIn: actions, text: \.text, otherText: \.text
        )
        #expect(kept.map(\.text) == ["Hold the slot for Thursday"])
    }

    @Test("genuine decisions survive")
    func keepsDistinct() {
        let actions = [MeetingNotes.ActionItem(text: "Book the SSO session", owner: "me", at_ms: nil)]
        let decisions = [MeetingNotes.Decision(text: "Hold the slot for Thursday", at_ms: nil)]
        #expect(NotesMerger.removing(
            decisions, duplicatedIn: actions, text: \.text, otherText: \.text
        ).count == 1)
    }

    @Test("nothing to compare against keeps everything")
    func emptyOthers() {
        let decisions = [MeetingNotes.Decision(text: "Hold Thursday", at_ms: nil)]
        #expect(NotesMerger.removing(
            decisions, duplicatedIn: [MeetingNotes.ActionItem](), text: \.text, otherText: \.text
        ).count == 1)
    }
}
