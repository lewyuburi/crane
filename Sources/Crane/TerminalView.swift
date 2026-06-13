import SwiftUI
import SwiftTerm

/// A live PTY terminal for a `container exec` invocation (a shell into a container).
struct PTYTerminalView: NSViewRepresentable {
    let makeInvocation: () async throws -> ContainerCLI.ExecInvocation
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        applyTheme(to: term)
        Task { @MainActor in
            do {
                let inv = try await makeInvocation()
                term.startProcess(
                    executable: inv.executable,
                    args: inv.args,
                    environment: inv.environment
                )
            } catch {
                term.feed(text: "\r\n[crane] failed to start: \(error.localizedDescription)\r\n")
            }
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyTheme(to: nsView)
    }

    /// Transparent background (so the inspector material shows through) and a
    /// foreground color that follows the system light/dark appearance.
    private func applyTheme(to term: LocalProcessTerminalView) {
        term.nativeBackgroundColor = .clear
        term.nativeForegroundColor = colorScheme == .dark ? .white : .black
        term.wantsLayer = true
        term.layer?.backgroundColor = NSColor.clear.cgColor
        term.layer?.isOpaque = false
    }
}

/// Sheet hosting an interactive terminal.
struct TerminalSheet: View {
    let title: String
    let makeInvocation: () async throws -> ContainerCLI.ExecInvocation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            PTYTerminalView(makeInvocation: makeInvocation)
                .frame(minWidth: 680, minHeight: 420)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}
