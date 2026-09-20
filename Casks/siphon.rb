cask "siphon" do
  version "5.4.5"
  sha256 "9bd6b023bce98eb2ecf72a52f2b78be127dd41bee1dca0eb7883ed9f2b6ef083"

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
