import AppleContainer
import CraneCore
import SwiftTerm
import SwiftUI

/// A real shell inside the container, backed by `container exec -it` and a PTY.
struct TerminalTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var invocation: ExecInvocation?
    @State private var failure: String?

    var body: some View {
        Group {
            if let invocation {
                PTYView(invocation: invocation)
                    .id(container.id)
            } else if let failure {
                ContentUnavailableView("No shell", systemImage: "terminal", description: Text(failure))
                    .paneEmptyState()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: container.id) {
            let runtime = model.engine.runtime
            guard runtime.isInstalled else {
                failure = "The container runtime isn't installed."
                return
            }
            invocation = runtime.shellInvocation(containerID: container.runtimeID)
        }
    }
}

/// Hosts SwiftTerm's local-process terminal.
private struct PTYView: NSViewRepresentable {
    let invocation: ExecInvocation

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.startProcess(executable: invocation.executable,
                          args: invocation.arguments,
                          environment: invocation.environment)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
