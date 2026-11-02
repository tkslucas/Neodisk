cask "neodisk@nightly" do
  version :latest
  sha256 :no_check

  url "https://github.com/tkslucas/Neodisk/releases/download/nightly/Neodisk-Nightly.dmg"
  name "Neodisk Nightly"
  desc "Disk space visualizer (nightly build)"
  homepage "https://github.com/tkslucas/Neodisk"

  depends_on macos: :sonoma

  app "Neodisk Nightly.app"
end
