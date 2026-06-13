import SwiftUI
import CraneKit
import AppKit

/// Entry point for creating something new from the "Run a container" button: a one-click
/// app gallery (parametrized Compose templates) plus the manual `container run` form.
struct RunContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .gallery
    @State private var selected: AppTemplate?

    enum Mode: String, CaseIterable, Identifiable { case gallery = "App Gallery", custom = "Custom"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 680, minHeight: 640)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            if selected != nil {
                Button { selected = nil } label: { Label("Gallery", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
            } else {
                Label("Run a container", systemImage: "plus.app").font(.headline)
            }
            Spacer()
            if selected == nil {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer()
            Button("Cancel") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if let template = selected {
            DeployTemplateForm(template: template, onDeployed: { dismiss() })
                .id(template.id)
        } else {
            switch mode {
            case .gallery: TemplateGallery(onSelect: { selected = $0 })
            case .custom: CustomRunForm(onRan: { dismiss() })
            }
        }
    }
}

// MARK: - Gallery

private struct TemplateGallery: View {
    let onSelect: (AppTemplate) -> Void
    @State private var query = ""
    @State private var selectedTag: String?

    /// Distinct tags across the catalog, most-common first (like Dokploy's tag filters).
    private var allTags: [String] {
        let counts = AppCatalog.all.flatMap(\.tags).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    private func matches(_ app: AppTemplate) -> Bool {
        let q = query.lowercased()
        let textOK = q.isEmpty
            || app.name.lowercased().contains(q)
            || app.tagline.lowercased().contains(q)
            || app.tags.contains { $0.contains(q) }
        let tagOK = selectedTag == nil || app.tags.contains(selectedTag!)
        return textOK && tagOK
    }

    private var groups: [(category: AppTemplate.Category, apps: [AppTemplate])] {
        AppCatalog.byCategory.compactMap { group in
            let apps = group.apps.filter(matches)
            return apps.isEmpty ? nil : (group.category, apps)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps…", text: $query).textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                Picker("Tag", selection: $selectedTag) {
                    Text("All tags").tag(String?.none)
                    Divider()
                    ForEach(allTags, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding([.horizontal, .top])

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.category.rawValue).font(.headline).foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.apps) { app in
                                    AppCard(app: app).onTapGesture { onSelect(app) }
                                }
                            }
                        }
                    }
                    if groups.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    }
                }
                .padding()
            }
        }
    }
}

private struct AppCard: View {
    let app: AppTemplate
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            TemplateLogo(app: app, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.semibold))
                Text(app.tagline).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
    }
}

private struct TemplateLogo: View {
    let app: AppTemplate
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let url = app.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    default: fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    private var fallback: some View {
        Image(systemName: app.symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// MARK: - Deploy a template

private struct DeployTemplateForm: View {
    @Environment(AppModel.self) private var model
    let template: AppTemplate
    let onDeployed: () -> Void

    @State private var instanceName: String
    @State private var values: [String: String]
    @State private var isDeploying = false

    init(template: AppTemplate, onDeployed: @escaping () -> Void) {
        self.template = template
        self.onDeployed = onDeployed
        _instanceName = State(initialValue: template.id)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues:
            template.variables.map { ($0.key, $0.initialValue()) }))
    }

    /// The services this template would create (parsed from its compose), so the user sees
    /// e.g. that WordPress brings up both an `app` and a `db` container.
    private var services: [(name: String, image: String)] {
        guard let project = try? ComposeParsing.parse(
            yaml: template.compose, baseDir: URL(fileURLWithPath: NSTemporaryDirectory())) else { return [] }
        return project.services
            .map { ($0.name, $0.image ?? "(built image)") }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                TemplateLogo(app: template, size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(template.name).font(.title2.bold())
                    Text(template.tagline).font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(template.tags, id: \.self) { tag in
                            Text(tag).font(.caption2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        ForEach(template.links) { link in
                            Link(destination: link.url) {
                                Label(link.label.capitalized, systemImage: "arrow.up.right.square")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding()
            Divider()

            if template.tags.contains("stack") {
                HStack(spacing: 8) {
                    Image(systemName: "flask.fill").foregroundStyle(.orange)
                    Text("Experimental multi-service stack. Relies on Apple container's internal DNS, which is currently flaky — Crane runs it on the default network and auto-retries failed services.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12))
            }

            Form {
                Section("Instance") {
                    TextField("Name", text: $instanceName)
                        .help("Used as the project name and shown as a group in Containers.")
                }
                Section(services.count > 1 ? "Services (\(services.count))" : "Service") {
                    ForEach(services, id: \.name) { svc in
                        LabeledContent {
                            Text(svc.image).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Label(svc.name, systemImage: "shippingbox")
                        }
                    }
                }
                Section("Configuration") {
                    ForEach(template.variables) { v in
                        LabeledContent(v.label) {
                            HStack(spacing: 6) {
                                TextField("", text: binding(for: v.key))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(1)
                                    .font(v.secret ? .system(.body, design: .monospaced) : .body)
                                if v.generator.isGenerated {
                                    Button { values[v.key] = v.generator.value() } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless).help("Generate a new value")
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Deploys as a Compose project you can manage in Containers.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    isDeploying = true
                    Task {
                        let ref = await model.deployTemplate(template, instanceName: instanceName, values: values)
                        isDeploying = false
                        if ref != nil {
                            if let key = template.primaryPortKey, let port = values[key], !port.isEmpty,
                               let url = URL(string: "http://localhost:\(port)") {
                                NSWorkspace.shared.open(url)
                            }
                            onDeployed()
                        }
                    }
                } label: {
                    if isDeploying {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Deploying…") }
                    } else {
                        Label("Deploy", systemImage: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isDeploying || instanceName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

// MARK: - Custom container form (manual `container run`)

private struct CustomRunForm: View {
    @Environment(AppModel.self) private var model
    let onRan: () -> Void

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
        RunSpec(image: image, name: name, command: command, detach: detach, removeOnExit: removeOnExit,
                env: lines(envText), ports: lines(portsText), volumes: lines(volumesText),
                cpus: cpus, memory: memory)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        if ok { onRan() }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!spec.isValid || isRunning)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
