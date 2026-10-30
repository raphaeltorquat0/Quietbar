cask "quietbar" do
  version "1.3.0"
  sha256 "f87296264c7678a1cfa1da324bd633dbb126079db213dbc4dbdf71fc1e274f39"

  url "https://github.com/raphaeltorquat0/Quietbar/releases/download/v#{version}/Quietbar-#{version}.dmg"
  name "Quietbar"
  desc "Menu bar controls for Sony headphones"
  homepage "https://github.com/raphaeltorquat0/Quietbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Quietbar.app"

  uninstall quit: "io.github.raphaeltorquat0.Quietbar"

  zap trash: [
    "~/Library/Application Support/Quietbar",
    "~/Library/Containers/io.github.raphaeltorquat0.Quietbar",
    "~/Library/Containers/io.github.raphaeltorquat0.Quietbar.Controls",
    "~/Library/Preferences/io.github.raphaeltorquat0.Quietbar.plist",
  ]
end
