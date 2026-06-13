import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var containers: [Container] = []
    var images: [ContainerImage] = []

    var isInstalled = false
    var isSystemRunning = false
    var isStartingSystem = false
    var isLoading = false
    var errorMessage: String?

    /// IDs of containers with an in-flight action (start/stop/delete), to disable buttons.
    var busyContainerIDs: Set<String> = []

    // Volumes / Networks / Storage
    var volumes: [Volume] = []
    var networks: [Network] = []
    var diskUsage: DiskUsage?

    // Machines
    var machines: [Machine] = []
    var busyMachineIDs: Set<String> = []
    var isCreatingMachine = false

    // Runtime management
    var runtimes: [Runtime] = []
    var activeRuntimePath: String?
    var availableReleases: [RemoteRelease] = []
    var installingVersion: String?

    private let cli = ContainerCLI.shared
    private let runtimeManager = RuntimeManager.shared

    func refreshInstallState() async {
        isInstalled = await cli.isInstalled
    }

    /// Eagerly load every section's data once at launch so switching the sidebar is
    /// instant instead of showing an empty view until each tab's own `.task` fires.
    func bootstrap() async {
        loadComposeProjects()
        await refreshContainers()        // also resolves isInstalled / isSystemRunning
        await refreshRuntimes()
        guard isInstalled, isSystemRunning else { return }
        // Independent CLI queries — run concurrently; the heavy work is off the main actor.
        async let images: Void = refreshImages()
        async let volumes: Void = refreshVolumes()
        async let networks: Void = refreshNetworks()
        async let disk: Void = refreshDiskUsage()
        _ = await (images, volumes, networks, disk)
    }

    func refreshContainers() async {
        await refreshInstallState()
        guard isInstalled else { containers = []; isSystemRunning = false; return }
        isSystemRunning = await cli.isSystemRunning()
        guard isSystemRunning else { containers = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            containers = try await cli.listContainers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshImages() async {
        await refreshInstallState()
        guard isInstalled else { images = []; return }
        do {
            images = try await cli.listImages()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Lightweight, silent refresh for periodic polling (no spinner, no install/system
    /// re-checks). Keeps container status current so a container that fails/exits after
    /// launch stops showing as "running".
    func pollContainers() async {
        guard isInstalled, isSystemRunning else { return }
        if let list = try? await cli.listContainers() { containers = list }
    }

    func deleteImages(references: [String]) async {
        do { try await cli.deleteImages(references: references); await refreshImages() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Creates and runs a container. Returns true on success so the form can dismiss.
    func runContainer(_ spec: RunSpec) async -> Bool {
        do {
            try await cli.runContainer(spec)
            await refreshContainers()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Container actions

    /// Recreate a container with new resource limits. Apple `container` fixes memory/cpus
    /// at creation, so changing them means stop → delete → run with the same config plus the
    /// new limits (env, ports, mounts, network and compose labels are preserved).
    func setResources(_ container: Container, memory: String?, cpus: Int?) async {
        busyContainerIDs.insert(container.id)
        defer { busyContainerIDs.remove(container.id) }
        let args = container.recreateArguments(memory: memory, cpus: cpus)
        do {
            try? await cli.stop(id: container.id)
            try await cli.delete(id: container.id)
            try await cli.runDetached(arguments: args)
            await refreshContainers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await refreshContainers()
        }
    }

    func start(_ container: Container) async { await perform(container) { try await self.cli.start(id: $0) } }
    func stop(_ container: Container) async { await perform(container) { try await self.cli.stop(id: $0) } }
    func delete(_ container: Container) async { await perform(container) { try await self.cli.delete(id: $0) } }

    /// Containers belonging to a compose project, in stable order.
    func containers(inProject project: String) -> [Container] {
        containers.filter { $0.composeProject == project }.sorted { $0.id < $1.id }
    }

    func stopProject(_ project: String) async { await bulkStop(containers(inProject: project).map(\.id)) }
    func deleteProject(_ project: String) async { await bulkDelete(containers(inProject: project).map(\.id)) }

    func bulkStart(_ ids: [String]) async { await bulk(ids) { try await self.cli.start(id: $0) } }
    func bulkStop(_ ids: [String]) async { await bulk(ids) { try await self.cli.stop(id: $0) } }
    func bulkDelete(_ ids: [String]) async { await bulk(ids) { try await self.cli.delete(id: $0) } }

    private func bulk(_ ids: [String], _ action: @escaping (String) async throws -> Void) async {
        busyContainerIDs.formUnion(ids)
        defer { busyContainerIDs.subtract(ids) }
        for id in ids {
            do { try await action(id) } catch { errorMessage = error.localizedDescription }
        }
        await refreshContainers()
    }

    private func perform(_ container: Container, _ action: @escaping (String) async throws -> Void) async {
        busyContainerIDs.insert(container.id)
        defer { busyContainerIDs.remove(container.id) }
        do {
            try await action(container.id)
            await refreshContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSystem() async {
        isStartingSystem = true
        defer { isStartingSystem = false }
        do {
            try await cli.systemStart()
            await refreshContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Compose

    /// Compose files the user added — shown as groups in the containers list
    /// (persisted across launches). `parsed` is the latest parse of each, keyed by
    /// the sanitized project name (which is also the compose label/network name).
    var composeProjects: [ComposeProjectRef] = []
    var composeParsed: [String: ComposeProject] = [:]
    var busyComposeProjects = Set<String>()
    private let composeProjectsKey = "crane.composeProjects"

    func loadComposeProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: composeProjectsKey) ?? []
        composeProjects = paths.compactMap(makeComposeRef)
        for ref in composeProjects { reparse(ref) }
    }

    @discardableResult
    func addComposeProject(url: URL) -> ComposeProjectRef? {
        guard let ref = makeComposeRef(path: url.path) else {
            errorMessage = "Couldn't parse \(url.lastPathComponent) as a compose file."
            return nil
        }
        if !composeProjects.contains(where: { $0.path == ref.path }) {
            composeProjects.append(ref)
            UserDefaults.standard.set(composeProjects.map(\.path), forKey: composeProjectsKey)
        }
        reparse(ref)
        return ref
    }

    func removeComposeProject(_ ref: ComposeProjectRef) {
        composeProjects.removeAll { $0.id == ref.id }
        composeParsed[ref.projectName] = nil
        UserDefaults.standard.set(composeProjects.map(\.path), forKey: composeProjectsKey)
    }

    private func makeComposeRef(path: String) -> ComposeProjectRef? {
        guard let proj = parse(path: path) else { return nil }
        return ComposeProjectRef(path: path, displayName: proj.name, projectName: proj.name)
    }

    private func parse(path: String) -> ComposeProject? {
        let url = URL(fileURLWithPath: path)
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? ComposeParsing.parse(yaml: yaml, baseDir: url.deletingLastPathComponent())
    }

    private func reparse(_ ref: ComposeProjectRef) {
        if let proj = parse(path: ref.path) { composeParsed[ref.projectName] = proj }
    }

    /// Services defined for a project (from the parsed file), in startup order.
    func services(forProject name: String) -> [ComposeService] {
        composeParsed[name]?.startupOrder ?? []
    }

    /// Streaming log of the most recent compose up, shown in a sheet.
    var composeLog = ""
    private func composeLogLine(_ s: String) { composeLog += s + "\n" }

    func composeUp(_ ref: ComposeProjectRef) async {
        reparse(ref)
        guard let project = composeParsed[ref.projectName] else { return }
        busyComposeProjects.insert(ref.projectName)
        defer { busyComposeProjects.remove(ref.projectName) }
        composeLog = ""
        composeLogLine("▸ Network \(project.name)")
        await cli.createNetworkIfNeeded(project.name)
        for vol in project.namedVolumes {
            composeLogLine("▸ Volume \(vol)")
            await cli.createVolumeIfNeeded(vol)
        }
        for service in project.startupOrder {
            composeLogLine("▸ \(service.name): starting…")
            do {
                try await startComposeService(service, project: project)
                composeLogLine("  ✓ \(service.containerName(project: project.name))")
            } catch {
                composeLogLine("  ✗ \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        composeLogLine("Done.")
        await refreshContainers()
    }

    /// Create & start a single compose service (like `docker compose up <service>`).
    func composeUpService(project projectName: String, service serviceName: String) async {
        guard let project = composeParsed[projectName],
              let service = project.services.first(where: { $0.name == serviceName }) else { return }
        busyComposeProjects.insert(projectName)
        defer { busyComposeProjects.remove(projectName) }
        composeLog = ""
        composeLogLine("▸ Network \(project.name)")
        await cli.createNetworkIfNeeded(project.name)
        composeLogLine("▸ \(service.name): starting…")
        do {
            try await startComposeService(service, project: project)
            composeLogLine("  ✓ \(service.containerName(project: project.name))")
        } catch {
            composeLogLine("  ✗ \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        composeLogLine("Done.")
        await refreshContainers()
    }

    /// Recreate-and-run one service: remove any existing container with its name
    /// (compose-style up), pre-create bind dirs, build if needed, then run detached.
    private func startComposeService(_ service: ComposeService, project: ComposeProject) async throws {
        let name = service.containerName(project: project.name)
        // Recreate: a previous (possibly stopped/failed) container blocks `run --name`.
        try? await cli.stop(id: name)
        try? await cli.delete(id: name)
        for path in service.hostBindPaths where !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if let build = service.build, let tag = service.runImage(project: project.name) {
            composeLogLine("  building \(tag)…")
            try await cli.buildImage(build, tag: tag)
        }
        try await cli.runDetached(arguments: service.runArguments(project: project.name))
    }

    func composeDown(_ projectName: String) async {
        busyComposeProjects.insert(projectName)
        defer { busyComposeProjects.remove(projectName) }
        await bulkDelete(containers(inProject: projectName).map(\.id))
    }

    // MARK: - Volumes / Networks / Storage

    private func systemReady() async -> Bool {
        await refreshInstallState()
        guard isInstalled else { return false }
        return await cli.isSystemRunning()
    }

    func refreshVolumes() async {
        guard await systemReady() else { volumes = []; return }
        do { volumes = try await cli.listVolumes(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func createVolume(name: String, size: String?) async -> Bool {
        do { try await cli.createVolume(name: name, size: size); await refreshVolumes(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func deleteVolume(_ volume: Volume) async {
        do { try await cli.deleteVolume(name: volume.name); await refreshVolumes() }
        catch { errorMessage = error.localizedDescription }
    }

    func pruneVolumes() async {
        do { try await cli.pruneVolumes(); await refreshVolumes(); await refreshDiskUsage() }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshNetworks() async {
        guard await systemReady() else { networks = []; return }
        do { networks = try await cli.listNetworks(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func createNetwork(name: String, subnet: String?) async -> Bool {
        do { try await cli.createNetwork(name: name, subnet: subnet); await refreshNetworks(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func deleteNetwork(_ network: Network) async {
        do { try await cli.deleteNetwork(name: network.name); await refreshNetworks() }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshDiskUsage() async {
        guard await systemReady() else { diskUsage = nil; return }
        diskUsage = await cli.diskUsage()
    }

    func pruneImages() async {
        do { try await cli.pruneImages(); await refreshDiskUsage() }
        catch { errorMessage = error.localizedDescription }
    }

    func pruneContainers() async {
        do { try await cli.pruneContainers(); await refreshContainers(); await refreshDiskUsage() }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Machines

    func refreshMachines() async {
        await refreshInstallState()
        guard isInstalled, await cli.isSystemRunning() else { machines = []; return }
        do {
            machines = try await cli.listMachines()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createMachine(image: String, name: String) async -> Bool {
        isCreatingMachine = true
        defer { isCreatingMachine = false }
        do {
            try await cli.machineCreate(image: image, name: name)
            await refreshMachines()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func bootMachine(_ machine: Machine) async { await performMachine(machine) { try await self.cli.machineBoot(name: $0) } }
    func stopMachine(_ machine: Machine) async { await performMachine(machine) { try await self.cli.machineStop(name: $0) } }
    func deleteMachine(_ machine: Machine) async { await performMachine(machine) { try await self.cli.machineDelete(name: $0) } }
    func setDefaultMachine(_ machine: Machine) async { await performMachine(machine) { try await self.cli.machineSetDefault(name: $0) } }

    private func performMachine(_ machine: Machine, _ action: @escaping (String) async throws -> Void) async {
        busyMachineIDs.insert(machine.id)
        defer { busyMachineIDs.remove(machine.id) }
        do {
            try await action(machine.id)
            await refreshMachines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Runtimes

    func refreshRuntimes() async {
        runtimes = await runtimeManager.discover()
        activeRuntimePath = await runtimeManager.activeRuntime()?.binaryPath
    }

    func loadAvailableReleases() async {
        do {
            availableReleases = try await runtimeManager.availableReleases()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setActiveRuntime(_ runtime: Runtime) async {
        await runtimeManager.setActive(runtime)
        await refreshRuntimes()
        await refreshContainers()
    }

    func installRuntime(version: String) async {
        installingVersion = version
        defer { installingVersion = nil }
        do {
            let installed = try await runtimeManager.install(version: version)
            await runtimeManager.setActive(installed)
            await refreshRuntimes()
            await refreshContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeRuntime(_ runtime: Runtime) async {
        do {
            try await runtimeManager.remove(runtime)
            await refreshRuntimes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
