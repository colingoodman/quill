import Foundation
import Testing

@testable import quill

/// Cases taken from a real standup whose notes led with a colleague's holiday.
/// The model is asked to *file* social talk into its own bucket rather than to
/// omit it — filing is something a 3B model does reliably, suppressing is not —
/// and this is the half that acts on the label.
@Suite("social content filtering")
struct SmallTalkTests {
    private let smallTalk = [
        "How's Latin America?",
        "Colleague travelled to Panama and Colombia and went skydiving",
        "Are there any plans for the weekend?",
        "What's the weather like?",
    ]

    @Test("a social question is removed from open questions")
    func dropsSocialQuestion() {
        let result = NotesMerger.removingSocial(
            ["How's Latin America?", "What is the embedding model cost?"],
            smallTalk: smallTalk, text: { $0 }
        )
        #expect(result.kept == ["What is the embedding model cost?"])
        #expect(result.dropped == ["How's Latin America?"])
    }

    @Test("work content is untouched")
    func keepsWork() {
        let work = [
            "What is the embedding model cost?",
            "How will the real-world trials be conducted?",
            "How many products should be sampled?",
        ]
        #expect(NotesMerger.removingSocial(work, smallTalk: smallTalk, text: { $0 }).kept == work)
    }

    @Test("a social topic leaking into two places still goes")
    func catchesLeakage() {
        // The trip appeared as a key point AND as an open question; filing it once
        // as social has to remove both.
        let points = [
            "The colleague travelled to Panama and Colombia and went skydiving",
            "The visual editor for YAML files is in progress",
        ]
        let kept = NotesMerger.removingSocial(points, smallTalk: smallTalk, text: { $0 }).kept
        #expect(kept.count == 1)
        #expect(kept[0].contains("YAML"))
    }

    @Test("an empty bucket changes nothing")
    func noBucket() {
        let items = ["Anything at all", "And another"]
        let result = NotesMerger.removingSocial(items, smallTalk: [], text: { $0 })
        #expect(result.kept == items)
        #expect(result.dropped.isEmpty)
    }

    @Test("filtering works over typed items, not just strings")
    func typedItems() {
        let actions = [
            MeetingNotes.ActionItem(text: "Send holiday photos round", owner: "them", at_ms: nil),
            MeetingNotes.ActionItem(text: "Fix the surface defect backtest", owner: "me", at_ms: nil),
        ]
        let kept = NotesMerger.removingSocial(
            actions, smallTalk: ["Send holiday photos round"], text: \.text
        ).kept
        #expect(kept.count == 1)
        #expect(kept[0].owner == "me")
    }
}

@Suite("keyword-dump rejection")
struct KeywordDumpTests {
    /// The actual title the model produced for a 26-minute standup.
    private let observed =
        "Panama-Colombia-Skydive-RF-Deader-Skydive-Agidean-Surface-Defect-Contracts-2027-Tickets-Self-Contained-Images-Backtests-Visual-Editor-YAML-File"

    @Test("the observed hyphen chain is rejected")
    func rejectsObserved() {
        #expect(NotesMerger.looksLikeKeywordDump(observed))
    }

    @Test("real titles are accepted")
    func acceptsReal() {
        for title in [
            "Pricing for the Acme renewal",
            "Staging cutover timeline",
            "Daily standup",
            "Q3 roadmap and hiring",
            "One-on-one: career growth",
        ] {
            #expect(!NotesMerger.looksLikeKeywordDump(title), "rejected a good title: \(title)")
        }
    }

    @Test("a single hyphenated word is fine, three hyphens is a dump")
    func hyphenThreshold() {
        #expect(!NotesMerger.looksLikeKeywordDump("Real-world trial results"))
        #expect(NotesMerger.looksLikeKeywordDump("Alpha-Beta-Gamma-Delta"))
    }

    @Test("empty and overlong are both rejected")
    func edges() {
        #expect(NotesMerger.looksLikeKeywordDump(""))
        #expect(NotesMerger.looksLikeKeywordDump("   "))
        #expect(NotesMerger.looksLikeKeywordDump(
            String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        ))
    }

    @Test("falls back to a section heading rather than shipping a dump")
    func titleFallback() {
        let sections = [
            MeetingNotes.Section(heading: "Technical Debt", bullets: ["a"]),
            MeetingNotes.Section(heading: "Bug Fixes", bullets: ["b"]),
        ]
        #expect(NotesMerger.usableTitle(observed, sections: sections, log: { _ in })
            == "Technical Debt")
    }

    @Test("falls back to a constant when every heading is also a dump")
    func lastResort() {
        let sections = [MeetingNotes.Section(heading: "A-B-C-D-E", bullets: ["x"])]
        #expect(NotesMerger.usableTitle("Q-W-E-R-T", sections: sections, log: { _ in })
            == "Meeting notes")
    }

    @Test("a good title passes through untouched")
    func passthrough() {
        #expect(NotesMerger.usableTitle(
            "  Pricing for the Acme renewal  ", sections: [], log: { _ in }
        ) == "Pricing for the Acme renewal")
    }
}

@Suite("open questions must really be questions")
struct QuestionTighteningTests {
    /// Both of these reached the notes because they begin with "What".
    @Test("a long verbatim fragment beginning with an interrogative is rejected")
    func rejectsTranscriptBlobs() {
        let blobs = [
            "What one of the optimization suggestions is that you can set an optimal number of batches, and then kind of no matter what you receive, if you receive seven, it just pads it.",
            "What I've been pulling out is a visual editor for these YAML files. So, a big thing with the reports that I've been generating is all YAML-based.",
        ]
        for blob in blobs {
            #expect(!NotesMerger.isQuestion(blob), "let through: \(blob.prefix(40))…")
        }
    }

    @Test("genuine questions still pass")
    func keepsReal() {
        for question in [
            "What is the embedding model cost?",
            "How will the real-world trials be conducted?",
            "How many products should be sampled?",
            "Whether legal will confirm EU residency",
        ] {
            #expect(NotesMerger.isQuestion(question), "rejected: \(question)")
        }
    }

    /// Observed in a real standup: spoken questions carry their disfluency.
    @Test("a disfluent spoken fragment is rejected")
    func rejectsDisfluency() {
        #expect(!NotesMerger.isQuestion(
            "I mean, how many do you and do you kind of like a range of things?"
        ))
        #expect(!NotesMerger.isQuestion("So how many, you know, batches?"))
        // But a clean question containing none of those markers survives.
        #expect(NotesMerger.isQuestion("How many batches should be used?"))
    }

    @Test("multi-sentence prose is rejected even when short")
    func rejectsMultiSentence() {
        #expect(!NotesMerger.isQuestion("What is this. It is a thing."))
    }

    @Test("a question at exactly the word limit is kept")
    func boundary() {
        let words = Array(repeating: "word", count: NotesMerger.maximumQuestionWords - 1)
        #expect(NotesMerger.isQuestion("What " + words.joined(separator: " ") + "?"))
    }
}
