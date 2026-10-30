cask "quietbar" do
  version "1.3.0"
  sha256 "ce6af5728f390d4d998ee1726aacd84bc97bf54abdf8794a49d42665082f2a4f"

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
