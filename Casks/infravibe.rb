cask "infravibe" do
  version "2.9.0"
  sha256 "ef2a3ed08793944e81732d15f1a2c25c933f9a580ddc0721a1117d3834a1fa21"

  url "https://github.com/netsecdevio/infravibe/releases/download/v#{version}/InfraProxy-#{version}.dmg"
  name "infravibe"
  desc "Infrastructure, remote terminals, and DevOps monitoring"
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
