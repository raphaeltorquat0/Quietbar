cask "quietbar" do
  version "1.3.0"
  sha256 "0fde360e6f13deb9c3814e3d58765dcc4cb0730b50ee56e24d79a82d02164cce"

  url "https://github.com/raphaeltorquat0/Quietbar/releases/download/v#{version}/Quietbar-#{version}.dmg"
  name "Quietbar"
  desc "Menu bar controls for Sony headphones"
  homepage "https://github.com/raphaeltorquat0/Quietbar"

  livecheck do
    url :url
    strategy :github_latest
  end

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
