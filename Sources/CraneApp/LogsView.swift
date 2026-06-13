import SwiftUI
import CraneKit

/// Streaming log console for a container, embeddable in the detail pane's Logs tab.
struct LogConsoleView: View {
    let container: Container
    @State private var stream: LogStream

    init(container: Container) {
        self.container = container
        _stream = State(initialValue: LogStream(containerID: container.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(stream.text.isEmpty ? "No output yet…" : stream.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("logTail")
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .onChange(of: stream.text) {
                withAnimation { proxy.scrollTo("logTail", anchor: .bottom) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let error = stream.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .onAppear { stream.start() }
        .onDisappear { stream.stop() }
        .id(container.id)
    }
}
