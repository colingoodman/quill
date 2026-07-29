import AppKit
import SwiftUI

/// Hosts `LiveTranscriptView` in a plain `NSWindow`.
///
/// quill stays an `.accessory` app — no Dock icon, no app-switcher entry — so
/// there is no SwiftUI `App` lifecycle and no window restoration. The window is
/// created on first request and reused; closing it does not stop recording, it
/// just puts the view away.
@MainActor
final class TranscriptWindow {
    private var window: NSWindow?
    private let state: LiveTranscriptState
    private let onToggle: () -> Void
    private let onReveal: () -> Void

    init(
        state: LiveTranscriptState,
        onToggle: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) {
        self.state = state
        self.onToggle = onToggle
        self.onReveal = onReveal
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        // An accessory app has to activate explicitly or the window opens
        // behind whatever the user is currently in.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Reported because a window that silently fails to appear is otherwise
        // indistinguishable from one hidden behind another app.
        FileHandle.standardError.write(Data(
            "window: visible=\(window.isVisible) frame=\(window.frame.size)\n".utf8
        ))
    }

    func toggle() {
        if isVisible {
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "quill"
        window.contentView = NSHostingView(
            rootView: LiveTranscriptView(
                state: state,
                onToggle: onToggle,
                onReveal: onReveal
            )
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("quill.transcript")
        return window
    }
}
