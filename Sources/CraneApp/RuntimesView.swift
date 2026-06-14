import SwiftUI
import CraneKit

/// Manage `container` runtimes: see what's installed, switch the active version,
/// and download/remove Crane-managed versions.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Installed") {
                if model.runtimes.isEmpty {
                    Text("No runtimes found. Install one below or install Apple's `.pkg` system-wide.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.runtimes) { runtime in
                        RuntimeRow(runtime: runtime, isActive: runtime.binaryPath == model.activeRuntimePath)
                    }
                }
            }

            Section("Command-line tool") {
                CLISection()
            }

            Section("Available to download") {
                if model.availableReleases.isEmpty {
                    Button("Load releases from GitHub") {
                        Task { await model.loadAvailableReleases() }
                    }
                } else {
                    ForEach(model.availableReleases) { release in
                        ReleaseRow(release: release)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Runtimes")
        .navigationSubtitle(model.runtimes.isEmpty ? "" : "\(model.runtimes.count) installed")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshRuntimes() } } label: {
                    Label("Rescan installed runtimes", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await model.refreshRuntimes() }
    }
}

/// Install/remove the bundled `crane` CLI on the user's PATH.
private struct CLISection: View {
    @State private var status = CLIInstaller.status
    @State private var working = false
    @State private var error: String?

    var body: some View {
        if status == .unavailable {
            Text("Run the packaged Crane.app to install the `crane` command.")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("`crane` command-line tool").fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else if status == .installed {
                    Button("Reinstall") { run(CLIInstaller.install) }
                    Button(role: .destructive) { run(CLIInstaller.uninstall) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).help("Remove crane from PATH")
                } else {
                    Button("Install") { run(CLIInstaller.install) }.buttonStyle(.borderedProminent)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var subtitle: String {
        switch status {
        case .installed: return "Installed at \(CLIInstaller.symlinkPath)"
        case .notInstalled: return "Adds `crane` to your PATH (\(CLIInstaller.symlinkPath))."
        case .conflict(let path): return "A different `crane` is already on PATH: \(path)"
        case .unavailable: return ""
        }
    }

    private func run(_ action: @escaping @Sendable () throws -> Void) {
        working = true; error = nil
        Task {
            do { try await Task.detached { try action() }.value }
            catch { self.error = error.localizedDescription }
            status = CLIInstaller.status
            working = false
        }
    }
}

private struct RuntimeRow: View {
    @Environment(AppModel.self) private var model
    let runtime: Runtime
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.version ?? "unknown version")
                    .fontWeight(isActive ? .semibold : .regular)
                Text("\(runtime.source.rawValue) · \(runtime.binaryPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Use") { Task { await model.setActiveRuntime(runtime) } }
            }
            if runtime.source == .managed {
                Button(role: .destructive) {
                    Task { await model.removeRuntime(runtime) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this managed runtime")
            }
        }
    }
}

private struct ReleaseRow: View {
    @Environment(AppModel.self) private var model
    let release: RemoteRelease

    private var isInstalling: Bool { model.installingVersion == release.version }
    private var isInstalled: Bool {
        model.runtimes.contains { $0.source == .managed && $0.version == release.version }
    }

    var body: some View {
        HStack {
            Text(release.version)
            if release.isPrerelease {
                Text("pre-release")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            Spacer()
            if isInstalled {
                Text("Installed").foregroundStyle(.secondary)
            } else if isInstalling {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { Task { await model.installRuntime(version: release.version) } }
                    .disabled(model.installingVersion != nil)
            }
        }
    }
}
