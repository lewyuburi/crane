# Source copy of the Homebrew cask. The tap (`lewyuburi/homebrew-tap`) is what `brew`
# actually reads; a tagged release copies this file over and fills in sha256.
cask "crane" do
  version "2.0.2"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/lewyuburi/crane/releases/download/v#{version}/Crane-#{version}-arm64.dmg"
  name "Crane"
  desc "Native macOS GUI for Apple's container runtime"
  homepage "https://github.com/lewyuburi/crane"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :tahoe # macOS 26+
  depends_on arch: :arm64  # Apple container is Apple Silicon only

  app "Crane.app"

  # Ad-hoc-signed builds carry a quarantine flag; strip it so the app launches without the
  # "damaged / can't be opened" prompt. REMOVE this once the release is Developer-ID notarized.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Crane.app"]
  end

  uninstall_preflight do
    uid = Process.euid
    %w[dev.crane.runtime dev.crane.socktainer].each do |label|
      system_command "/bin/launchctl",
                     args: ["bootout", "gui/#{uid}/#{label}"],
                     must_succeed: false
    end
  end

  zap trash: [
    "~/Library/Application Support/Crane",
    "~/Library/LaunchAgents/dev.crane.runtime.plist",
    "~/Library/LaunchAgents/dev.crane.socktainer.plist",
    "~/Library/Preferences/dev.crane.Crane.plist",
    "~/.socktainer",
  ]

  caveats <<~EOS
    Open Crane once to install the engine. Leave “Install Docker CLI and Compose”
    checked if you don’t already have `docker` on PATH — that’s what makes
    `docker compose up -d` work from a project folder.

    Update with:
      brew upgrade --cask crane
  EOS
end
