cask "siphon" do
  version "5.5.0"
  sha256 "a979d8b008ab57b7fb306f164946bc43593cd79806e3e3ee505d2d44c84beae1"

  url "https://github.com/marspater/jolly-hopper/releases/download/v#{version}/Siphon-v#{version}.dmg"
  name "Siphon"
  desc "Media extractor and downloader powered by yt-dlp"
  homepage "https://github.com/marspater/jolly-hopper"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Siphon.app"

  zap trash: [
    "~/Library/Application Support/Siphon",
    "~/Library/Caches/com.marspater.siphon",
    "~/Library/Preferences/com.marspater.siphon.plist",
    "~/Library/Saved Application State/com.marspater.siphon.savedState",
  ]
end
