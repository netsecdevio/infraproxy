cask "infravibe" do
  version "2.7.0"
  sha256 "eb1bacca882f709f26506a1237e693e5cb0d7b80640b4008204924798b3c2f6a"

  url "https://github.com/netsecdevio/infravibe/releases/download/v#{version}/InfraProxy-#{version}.dmg"
  name "infravibe"
  desc "Infrastructure connections and remote browser terminals"
  homepage "https://github.com/netsecdevio/infravibe"

  auto_updates true
  depends_on macos: :sequoia

  app "InfraProxy.app"

  caveats do
    <<~EOS
      infravibe requires macOS 15.5 or later.
      Provider tools and tmux are optional and installed separately.
      Use the in-app updater, or brew upgrade --cask --greedy infravibe.
    EOS
  end
end
