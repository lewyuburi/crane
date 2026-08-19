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
    /// Whether the view sticks to the tail. Pausing stops the scrolling, never the stream: the
    /// output keeps arriving so scrolling back down shows an unbroken log.
    let follows: Bool

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
        context.coordinator.follows = follows
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var follows = true

        func append(_ chunk: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Follow the tail only when asked to *and* when the user is already there: scrolling
            // up to read must not be yanked back by new output.
            let shouldFollow = follows && isScrolledToBottom
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            storage.append(NSAttributedString(string: chunk, attributes: attributes))

            let overflow = storage.length - LogConsole.characterLimit
            if overflow > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: overflow))
            }
            if shouldFollow { textView.scrollToEndOfDocument(nil) }
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
    let sources: [LogSource]
    @State private var session: LogSession?
    @State private var fontSize: CGFloat = 12
    @State private var follows = true

    init(container: Container) {
        sources = [LogSource(containerID: container.id)]
    }

    init(project: Project) {
        sources = project.containers.map {
            LogSource(containerID: $0.id, label: $0.service ?? $0.name)
        }
    }

    private var sourceKey: String { sources.map(\.containerID).joined(separator: ",") }

    var body: some View {
        Group {
            if sources.isEmpty {
                ContentUnavailableView("No services", systemImage: "text.alignleft",
                                       description: Text("This stack has no containers to tail."))
            } else if let session {
                LogConsole(session: session, fontSize: fontSize, follows: follows)
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
                Toggle(isOn: $follows) {
                    Label("Follow", systemImage: follows ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                .help(follows ? "Stop scrolling to the newest line" : "Scroll with new output again")
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
        .task(id: sourceKey) {
            guard !sources.isEmpty else { return }
            let session = LogSession(client: model.client, sources: sources)
            self.session = session
            defer { session.stop() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
