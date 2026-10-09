cask "infravibe" do
  version "2.8.0"
  sha256 "5c3b7067ec0093593408b6ad8ba588df6797d178c2698f7ddf83d1407708b0d0"

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
