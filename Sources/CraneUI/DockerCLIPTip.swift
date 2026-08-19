import SwiftUI
import TipKit

/// One-time offer to install the official Docker CLI when the engine is up and PATH has no `docker`.
struct DockerCLIPTip: Tip {
    var title: Text {
        Text("Docker CLI isn’t on this Mac")
    }

    var message: Text {
        Text("Install the official CLI and Compose to use docker in Terminal. You’ll need a new terminal window after that.")
    }

    var image: Image {
        Image(systemName: "apple.terminal")
    }

    var actions: [Action] {
        [
            Action(id: "install", title: "Install"),
            Action(id: "later", title: "Not now"),
        ]
    }
}
