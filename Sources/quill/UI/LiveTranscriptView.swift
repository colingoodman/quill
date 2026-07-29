import SwiftUI

/// What the window renders. Owned by `AppController`, mutated only on the main
/// actor, observed by SwiftUI.
@MainActor
@Observable
final class LiveTranscriptState {
    var isRecording = false
    var elapsed = "0:00"
    /// Lines the recognizer has committed to, oldest first.
    var lines: [LiveTranscriber.Line] = []
    /// The in-flight guess per speaker, replaced as it firms up.
    var pending: [String: String] = [:]
    /// Shown under the controls: model loading, transcription progress, errors.
    var status: String?

    func reset() {
        lines = []
        pending = [:]
    }

    func apply(_ line: LiveTranscriber.Line) {
        if line.isConfirmed {
            lines.append(line)
            pending[line.speaker] = nil
            // A long meeting would otherwise grow without bound; the full
            // transcript is on disk, this is only the live view.
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        } else {
            pending[line.speaker] = line.text
        }
    }
}

struct LiveTranscriptView: View {
    var state: LiveTranscriptState
    var onToggle: () -> Void
    var onReveal: () -> Void

    private var pendingLines: [(speaker: String, text: String)] {
        state.pending
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (speaker: $0.key, text: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            Text(state.isRecording ? "Recording" : "Idle")
                .font(.system(size: 13, weight: .medium))
            if state.isRecording {
                Text(state.elapsed)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let status = state.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(state.isRecording ? "Stop" : "Start", action: onToggle)
                .keyboardShortcut("r", modifiers: .command)
            Button("Open Folder", action: onReveal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.lines.isEmpty && pendingLines.isEmpty {
                        Text(state.isRecording
                            ? "Listening…"
                            : "Start recording to see a live transcript.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(state.lines) { line in
                        row(speaker: line.speaker, text: line.text, settled: true)
                    }
                    ForEach(pendingLines, id: \.speaker) { line in
                        row(speaker: line.speaker, text: line.text, settled: false)
                    }
                    // Scroll anchor: the transcript should stay pinned to the
                    // newest line the way a terminal does.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(14)
            }
            .onChange(of: state.lines.count) { scrollToBottom(proxy) }
            .onChange(of: state.pending) { scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// `me` and `them` are the same labels the canonical transcript uses, so the
    /// live view reads the same way the file does.
    private func row(speaker: String, text: String, settled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(speaker)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(speaker == "me" ? Color.accentColor : Color.orange)
                .frame(width: 38, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                // Unsettled text is dimmed rather than hidden: it is useful to
                // read and honest about being provisional.
                .foregroundStyle(settled ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
