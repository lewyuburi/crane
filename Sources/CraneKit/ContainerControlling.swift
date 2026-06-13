import Foundation

/// The surface of `ContainerCLI` that `AppModel` depends on. Extracting it as a protocol lets the
/// orchestration logic be unit-tested against a fake, instead of shelling out to the real binary.
public protocol ContainerControlling: Sendable {
    var isInstalled: Bool { get async }
    func isSystemRunning() async -> Bool
    func systemStart() async throws

    func listContainers() async throws -> [Container]
    func runContainer(_ spec: RunSpec) async throws
    func start(id: String) async throws
    func stop(id: String) async throws
    func delete(id: String) async throws
    func runDetached(arguments: [String]) async throws
    func createStopped(arguments: [String]) async throws
    @discardableResult func exec(id: String, command: [String]) async throws -> Data

    func listImages() async throws -> [ContainerImage]
    func deleteImages(references: [String]) async throws
    func pruneImages() async throws
    func pruneContainers() async throws

    func createNetworkIfNeeded(_ name: String) async
    func createVolumeIfNeeded(_ name: String) async
    func buildImage(_ build: ComposeBuild, tag: String) async throws
    func configuredDNSDomain() async -> String?

    func listVolumes() async throws -> [Volume]
    func createVolume(name: String, size: String?) async throws
    func deleteVolume(name: String) async throws
    func pruneVolumes() async throws

    func listNetworks() async throws -> [Network]
    func createNetwork(name: String, subnet: String?) async throws
    func deleteNetwork(name: String) async throws

    func diskUsage() async -> DiskUsage?
}

extension ContainerCLI: ContainerControlling {}
