import Foundation
import Testing

@testable import DockerAPI

@Suite("Socket URLs")
struct DockerSocketTests {
    let socket = DockerSocket(path: "/Users/dev/.socktainer/container.sock")

    @Test("The socket path becomes the percent-encoded host")
    func encodesPathAsHost() {
        #expect(socket.url("/v1.51/version")
            == "http+unix://%2FUsers%2Fdev%2F.socktainer%2Fcontainer.sock/v1.51/version")
    }

    @Test("A path without a leading slash still produces a valid URL")
    func addsMissingSlash() {
        #expect(socket.url("_ping").hasSuffix(".sock/_ping"))
    }

    @Test("Query items are appended and encoded")
    func encodesQuery() {
        let url = socket.url("/v1.51/events", query: [
            URLQueryItem(name: "since", value: "1700000000"),
            URLQueryItem(name: "filters", value: #"{"type":["container"]}"#),
        ])
        #expect(url.contains("?since=1700000000&filters="))
        #expect(url.contains("%7B%22type%22"))
        #expect(!url.contains("{"))
    }

    @Test("A literal plus in a value survives encoding")
    func encodesPlus() {
        let url = socket.url("/v1.51/events", query: [URLQueryItem(name: "q", value: "a+b")])
        #expect(url.hasSuffix("?q=a%2Bb"))
    }

    @Test("Endpoints get the API version prefix, except pre-prefixed ones")
    func prefixesVersion() {
        #expect(DockerClient.prefixed("/info") == "/v1.51/info")
        #expect(DockerClient.prefixed("/v1.51/info") == "/v1.51/info")
    }
}
