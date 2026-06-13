import SwiftUI

/// Form to create and run a new container (`container run`).
struct RunContainerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var command = ""
    @State private var detach = true
    @State private var removeOnExit = false
    @State private var envText = ""
    @State private var portsText = ""
    @State private var volumesText = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var isRunning = false

    private var spec: RunSpec {
        RunSpec(
            image: image,
            name: name,
            command: command,
            detach: detach,
            removeOnExit: removeOnExit,
            env: lines(envText),
            ports: lines(portsText),
            volumes: lines(volumesText),
            cpus: cpus,
            memory: memory
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Run a container", systemImage: "plus.app")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Section("Image") {
                    TextField("e.g. docker.io/library/nginx:latest", text: $image)
                    TextField("Name (optional)", text: $name)
                    TextField("Command (optional)", text: $command)
                }
                Section("Options") {
                    Toggle("Run detached (-d)", isOn: $detach)
                    Toggle("Remove on exit (--rm)", isOn: $removeOnExit)
                    TextField("CPUs (optional)", text: $cpus)
                    TextField("Memory, e.g. 512M, 1G (optional)", text: $memory)
                }
                Section("Environment — one KEY=VALUE per line") {
                    TextEditor(text: $envText).frame(minHeight: 50).font(.system(.body, design: .monospaced))
                }
                Section("Ports — one host:container per line") {
                    TextEditor(text: $portsText).frame(minHeight: 50).font(.system(.body, design: .monospaced))
                }
                Section("Volumes — one host:container per line") {
                    TextEditor(text: $volumesText).frame(minHeight: 50).font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Run") {
                    isRunning = true
                    Task {
                        let ok = await model.runContainer(spec)
                        isRunning = false
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!spec.isValid || isRunning)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
