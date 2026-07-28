import ArgumentParser
import Foundation

/// Inspect and materialize the summary templates.
///
/// A template's headings are the sections the model is asked to fill, so
/// editing one is how you change the shape of your notes. Writing the builtins
/// out gives you something to copy rather than a format to guess at.
struct Templates: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the summary templates, or write the built-ins out to edit."
    )

    @Flag(name: .long, help: "Write the built-in templates to ~/.config/quill/templates/.")
    var write: Bool = false

    func run() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quill/templates", isDirectory: true)

        guard write else {
            let active = Config.summarizationTemplate()
            for name in Template.builtins.keys.sorted() {
                let template = Template.builtin(name)
                let overridden = FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("\(name).md").path
                )
                let marks = [
                    name == active ? "active" : nil,
                    overridden ? "overridden on disk" : nil,
                ].compactMap { $0 }
                let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                print("\(name)\(suffix)")
                print("    sections: \(template.sections.joined(separator: " · "))")
            }
            print("")
            print("write them out to edit:  quill templates --write")
            return
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0, skipped = 0
        for name in Template.builtins.keys.sorted() {
            let url = dir.appendingPathComponent("\(name).md")
            // Never clobber an edited template — that is the user's work.
            if FileManager.default.fileExists(atPath: url.path) {
                print("· \(name).md exists, left alone")
                skipped += 1
                continue
            }
            try Data(Template.builtin(name).asMarkdown.utf8).write(to: url, options: .atomic)
            print("✓ \(name).md")
            written += 1
        }
        print("")
        print("\(written) written, \(skipped) left alone → \(dir.path)")
    }
}
