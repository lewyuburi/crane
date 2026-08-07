import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A minimal HTTP server on a UNIX socket, standing in for the daemon.
///
/// It exists so the transport is exercised for real — the `http+unix://` URL shape, streaming
/// bodies, and error mapping are the kind of thing that either works against a socket or doesn't,
/// and no amount of pure unit testing would tell us which.
final class FakeDaemon: Sendable {
    /// What to answer for a given path.
    struct Route: Sendable {
        let status: HTTPResponseStatus
        let body: String
        /// Sent line by line with a pause between, to prove chunked/streaming decoding.
        let streamed: Bool

        init(status: HTTPResponseStatus = .ok, body: String, streamed: Bool = false) {
            self.status = status
            self.body = body
            self.streamed = streamed
        }
    }

    let socketPath: String
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    init(routes: [String: Route]) async throws {
        socketPath = FileManager.default.temporaryDirectory
            .appending(path: "crane-fake-\(UUID().uuidString.prefix(8)).sock", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Handler(routes: routes))
                }
            }
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true)
            .get()
    }

    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let routes: [String: Route]

        init(routes: [String: Route]) {
            self.routes = routes
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case let .head(head) = unwrapInboundIn(data) else { return }
            let path = String(head.uri.prefix { $0 != "?" })
            let route = routes[path] ?? Route(status: .notFound, body: #"{"message":"no such endpoint"}"#)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            // Without a Content-Length, NIO frames the body as chunked — which is how the daemon
            // actually streams `/events`, and it leaves the connection reusable afterwards.
            if !route.streamed {
                headers.add(name: "Content-Length", value: String(route.body.utf8.count))
            }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(
                version: head.version, status: route.status, headers: headers))), promise: nil)

            if route.streamed {
                // One line per flush, so the client has to reassemble across chunks.
                for line in route.body.split(separator: "\n", omittingEmptySubsequences: false) {
                    var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 1)
                    buffer.writeString(String(line) + "\n")
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else {
                var buffer = context.channel.allocator.buffer(capacity: route.body.utf8.count)
                buffer.writeString(route.body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
