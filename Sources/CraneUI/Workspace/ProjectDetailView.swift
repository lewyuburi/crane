import CraneCore
import SwiftUI

/// Overview of a Compose project: status, services and published ports.
struct ProjectDetailView: View {
    @Environment(EngineModel.self) private var model
    let project: Project
    @Binding var selection: WorkspaceItem?

    var body: some View {
        Form {
            Section {
                HStack(spacing: Metric.regular) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(project.isFullyUp ? Color.accentColor : .secondary)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.title2.weight(.semibold))
                        Text(project.statusLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                DetailRow("State", project.statusLabel)
                DetailRow("Services", "\(project.runningCount) of \(project.containers.count) running")
            }

            Section("Services") {
                ForEach(project.containers) { container in
                    Button {
                        selection = .container(container.id)
                    } label: {
                        DetailRow(container.service ?? container.name, container.state.label)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !project.publishedPorts.isEmpty {
                Section("Ports") {
                    ForEach(Array(project.publishedPorts.enumerated()), id: \.offset) { _, port in
                        if let host = port.hostPort {
                            DetailRow("localhost:\(host)", "\(port.containerPort)/\(port.proto)",
                                      monospaced: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .navigationSubtitle(project.statusLabel)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let port = project.publishedPorts.first?.hostPort,
                   let url = URL(string: "http://localhost:\(port)") {
                    Button("Open", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .help("Open localhost:\(port)")
                }
                if !project.isFullyStopped {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.workspace.stop(project.containers) }
                    }
                }
                if !project.isFullyUp {
                    Button("Start", systemImage: "play.fill") {
                        Task { await model.workspace.start(project.containers) }
                    }
                }
            }
        }
    }
}

#Preview("Stack detail") {
    let model = CranePreview.model()
    let project = model.workspace.grouping.projects.first { $0.name == "shop" }!
    return NavigationStack {
        ProjectDetailView(project: project, selection: .constant(.project("shop")))
    }
    .environment(model)
    .frame(width: 520, height: 640)
}
