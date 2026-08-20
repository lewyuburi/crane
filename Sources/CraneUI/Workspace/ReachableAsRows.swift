import CraneCore
import SwiftUI

/// Rows for **Reachable as**: host ports, peer DNS names, networks, optional collision copy.
struct ReachableAsRows: View {
    let names: ReachableNames
    var showCollision: Bool = true

    var body: some View {
        ForEach(Array(names.host.enumerated()), id: \.offset) { _, host in
            DetailRow("This Mac", host, monospaced: true)
        }
        ForEach(Array(names.peers.enumerated()), id: \.offset) { _, peer in
            DetailRow("Other containers", peer, monospaced: true)
        }
        ForEach(Array(names.networks.enumerated()), id: \.offset) { _, network in
            DetailRow("Network", network, monospaced: true)
        }
        if showCollision, let warning = names.collisionWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}
