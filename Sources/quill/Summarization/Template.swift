import Foundation

/// The skeleton the notes are hung on.
///
/// Granola's mechanic is that the sparse notes you type during a call guide the
/// model — your shorthand is the structure, the transcript supplies evidence.
/// Quill has no note-taking surface (the whole UI is one status item), so the
/// template takes that role: its headings are the sections the model is asked
/// to fill from the transcript.
///
/// A template is a markdown file in ~/.config/quill/templates/<name>.md.
/// `## Heading` lines become sections; every other non-empty line is guidance
/// passed to the model as instructions.
struct Template: Sendable, Equatable {
    let name: String
    let sections: [String]
    let guidance: String

    static let fallbackName = "default"

    static func parse(name: String, markdown: String) -> Template {
        var sections: [String] = []
        var guidance: [String] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("##") {
                let heading = line.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { sections.append(heading) }
            } else if line.hasPrefix("#") {
                continue  // a title line; the model generates its own title
            } else if !line.isEmpty {
                guidance.append(line)
            }
        }
        return Template(
            name: name,
            sections: sections.isEmpty ? builtin(fallbackName).sections : sections,
            guidance: guidance.joined(separator: " ")
        )
    }

    /// Load `name` from ~/.config/quill/templates/, falling back to the builtin
    /// of the same name, then to `default`. A named template that resolves to
    /// nothing is reported rather than silently swapped.
    static func load(named name: String) -> Template {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quill/templates/\(name).md")
        if let markdown = try? String(contentsOf: url, encoding: .utf8) {
            return parse(name: name, markdown: markdown)
        }
        if let builtin = builtins[name] { return builtin }
        FileHandle.standardError.write(Data(
            "warning: unknown summary template \"\(name)\" — using \(fallbackName)\n".utf8
        ))
        return builtin(fallbackName)
    }

    static func builtin(_ name: String) -> Template {
        builtins[name] ?? builtins[fallbackName]!
    }

    static let builtins: [String: Template] = [
        "default": Template(
            name: "default",
            sections: ["Discussion", "Context"],
            guidance: "Group the discussion by topic. Prefer what was actually said "
                + "over generalities. Omit pleasantries, scheduling chatter, and "
                + "small talk entirely."
        ),
        "standup": Template(
            name: "standup",
            sections: ["Progress", "Blockers", "Next"],
            guidance: "This is a status meeting. Keep every bullet to one line. "
                + "Attribute work to whoever reported it. A blocker is only a "
                + "blocker if someone said they were stuck."
        ),
        "one-on-one": Template(
            name: "one-on-one",
            sections: ["Topics", "Feedback", "Follow-ups"],
            guidance: "This is a private one-on-one. Record commitments and "
                + "feedback in the words used. Do not soften or editorialise "
                + "criticism, and do not invent sentiment that was not expressed."
        ),
        "interview": Template(
            name: "interview",
            sections: ["Background", "Signals", "Concerns"],
            guidance: "This is a candidate interview. Separate what the candidate "
                + "claimed from what they demonstrated. Quote specifics. Do not "
                + "render an overall hire recommendation."
        ),
        "sales": Template(
            name: "sales",
            sections: ["Needs", "Objections", "Next steps"],
            guidance: "This is a customer call. Capture requirements and objections "
                + "in the customer's own framing, including budget and timeline "
                + "figures exactly as stated."
        ),
    ]

    /// Written to ~/.config/quill/templates/ on demand so there is something to
    /// copy when authoring a new one.
    var asMarkdown: String {
        var lines = ["# \(name)", ""]
        if !guidance.isEmpty { lines += [guidance, ""] }
        lines += sections.flatMap { ["## \($0)", ""] }
        return lines.joined(separator: "\n")
    }
}
