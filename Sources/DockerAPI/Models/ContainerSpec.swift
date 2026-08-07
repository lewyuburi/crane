import Foundation

/// What to create a container from.
///
/// A narrow subset of Docker's create body: the options Apple's runtime can actually honor.
/// Anything it can't (privileged mode, static IPs, CPU shares) is deliberately absent rather
/// than accepted and ignored.
public struct ContainerSpec: Sendable, Equatable {
    public var image: String
    /// Overrides the image's command.
    public var command: [String]
    /// `KEY=VALUE` entries.
    public var environment: [String]
    public var labels: [String: String]
    /// Host port → container port, as `8080:80` style pairs.
    public var publishedPorts: [PortMapping]
    /// `source:target[:ro]` binds, or named volumes.
    public var binds: [String]
    public var workingDirectory: String?
    public var user: String?
    public var restartPolicy: String?
    public var network: String?

    public struct PortMapping: Sendable, Equatable {
        public let hostPort: Int
        public let containerPort: Int
        public let proto: String

        public init(hostPort: Int, containerPort: Int, proto: String = "tcp") {
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.proto = proto
        }

        var key: String { "\(containerPort)/\(proto)" }
    }

    public init(image: String, command: [String] = [], environment: [String] = [],
                labels: [String: String] = [:], publishedPorts: [PortMapping] = [],
                binds: [String] = [], workingDirectory: String? = nil, user: String? = nil,
                restartPolicy: String? = nil, network: String? = nil) {
        self.image = image
        self.command = command
        self.environment = environment
        self.labels = labels
        self.publishedPorts = publishedPorts
        self.binds = binds
        self.workingDirectory = workingDirectory
        self.user = user
        self.restartPolicy = restartPolicy
        self.network = network
    }

    /// The `POST /containers/create` body. Built as JSON objects rather than Codable because
    /// Docker's shape is nested and sparse — omitted keys mean "default", and an encoder that
    /// writes nulls changes behaviour.
    public func createBody() -> [String: Any] {
        var payload: [String: Any] = ["Image": image]
        if !command.isEmpty { payload["Cmd"] = command }
        if !environment.isEmpty { payload["Env"] = environment }
        if !labels.isEmpty { payload["Labels"] = labels }
        if let workingDirectory { payload["WorkingDir"] = workingDirectory }
        if let user { payload["User"] = user }
        if !publishedPorts.isEmpty {
            payload["ExposedPorts"] = Dictionary(uniqueKeysWithValues:
                publishedPorts.map { ($0.key, [String: Any]()) })
        }

        var hostConfig: [String: Any] = [:]
        if !publishedPorts.isEmpty {
            hostConfig["PortBindings"] = Dictionary(publishedPorts.map {
                ($0.key, [["HostPort": String($0.hostPort)]])
            }, uniquingKeysWith: { first, second in first + second })
        }
        if !binds.isEmpty { hostConfig["Binds"] = binds }
        if let restartPolicy { hostConfig["RestartPolicy"] = ["Name": restartPolicy] }
        if let network { hostConfig["NetworkMode"] = network }
        if !hostConfig.isEmpty { payload["HostConfig"] = hostConfig }
        return payload
    }
}

public extension DockerClient {
    /// Creates a container and returns its id. It is not started — `start(_:)` does that, the
    /// same split `docker run` hides behind one command.
    @discardableResult
    func create(_ spec: ContainerSpec, name: String? = nil) async throws -> String {
        struct Created: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }
        let body = try JSONSerialization.data(withJSONObject: spec.createBody())
        let payload = try await data(.POST, "/containers/create",
                                     query: name.map { [URLQueryItem(name: "name", value: $0)] } ?? [],
                                     body: body)
        return try Self.decode(Created.self, from: payload).id
    }

    /// Creates and starts in one call, like `docker run -d`.
    @discardableResult
    func run(_ spec: ContainerSpec, name: String? = nil) async throws -> String {
        let id = try await create(spec, name: name)
        try await start(id)
        return id
    }
}
