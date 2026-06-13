# Homebrew cask template. This file belongs in your tap repo (`lewyuburi/homebrew-tap`)
# under `Casks/crane.rb`. The Release workflow prints the SHA-256 to paste below.
cask "crane" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/lewyuburi/crane/releases/download/v#{version}/Crane-#{version}-arm64.dmg"
  name "Crane"
  desc "Native macOS GUI for Apple's container tool"
  homepage "https://github.com/lewyuburi/crane"

  depends_on macos: :tahoe # macOS 26+
  depends_on arch: :arm64  # Apple container is Apple Silicon only

  app "Crane.app"

  # Ad-hoc-signed builds carry a quarantine flag; strip it so the app launches without the
  # "damaged / can't be opened" prompt. REMOVE this once the release is Developer-ID notarized.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Crane.app"]
  end

  zap trash: [
    "~/Library/Application Support/Crane",
    "~/Library/Preferences/dev.crane.Crane.plist",
  ]
end
