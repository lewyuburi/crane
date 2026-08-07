import AppKit
import CraneCore
import SwiftUI

/// An append-only console backed by `NSTextView`.
///
/// SwiftUI's `Text` re-lays out everything it holds on each change, which a followed log makes
/// unbearable within seconds. AppKit lets Crane append to the storage and trim the head, so a
/// container that has printed a million lines still scrolls at full frame rate and the memory
/// stays flat.
struct LogConsole: NSViewRepresentable {
    /// Roughly a few thousand lines; older output scrolls out of existence rather than out of memory.
    static let characterLimit = 400_000

    let session: LogSession
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        session.start { [weak coordinator = context.coordinator] chunk in
            coordinator?.append(chunk)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.textView?.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?

        func append(_ chunk: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Only follow the tail if the user is already there; scrolling up to read must not
            // be yanked back by new output.
            let wasAtBottom = isScrolledToBottom
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            storage.append(NSAttributedString(string: chunk, attributes: attributes))

            let overflow = storage.length - LogConsole.characterLimit
            if overflow > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: overflow))
            }
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        }

        func clear() {
            textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        }

        var text: String { textView?.string ?? "" }

        private var isScrolledToBottom: Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= documentView.bounds.maxY - 2
        }
    }
}

/// The Logs tab: the console plus the controls that make a live tail usable.
struct LogsTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var session: LogSession?
    @State private var fontSize: CGFloat = 12

    var body: some View {
        Group {
            if let session {
                LogConsole(session: session, fontSize: fontSize)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .topTrailing) {
            if let session, let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.red).padding(Metric.snug)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session {
                    Toggle(isOn: Binding(get: { session.isFollowing },
                                         set: { session.isFollowing = $0 })) {
                        Label("Follow", systemImage: session.isFollowing ? "play.fill" : "pause.fill")
                    }
                    .toggleStyle(.button)
                    .help(session.isFollowing ? "Pause the tail" : "Resume following")
                }
                Button {
                    fontSize = max(9, fontSize - 1)
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                Button {
                    fontSize = min(20, fontSize + 1)
                } label: {
                    Label("Bigger", systemImage: "textformat.size.larger")
                }
            }
        }
        .task(id: container.id) {
            let session = LogSession(client: model.client, containerID: container.id)
            self.session = session
            // The session is stopped when the view goes away or the container changes.
            defer { session.stop() }
            // Keep the task alive so `defer` runs on cancellation.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
