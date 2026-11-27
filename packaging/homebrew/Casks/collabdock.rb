cask "collabdock" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_MAKE_DMG"

  url "https://github.com/boris-w/collabdock/releases/download/v#{version}/CollabDock-#{version}.dmg"
  name "CollabDock"
  desc "macOS menu bar collaboration dock for local AI agents (Claude Code, Codex, Antigravity, Lody)"
  homepage "https://github.com/boris-w/collabdock"

  depends_on macos: ">= :sonoma"

  app "CollabDock.app"

  zap trash: [
    "~/Library/Application Support/CollabDock",
    "~/Library/Caches/CollabDock",
    "~/Library/Preferences/dev.collabdock.app.plist",
  ]
end
