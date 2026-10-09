# frozen_string_literal: true

cask "infravibe" do
  version "2.10.0"
  sha256 "a15c54ccd6ac2dfe46c6c5e71b58b992c81af5bc8ffd59528cb587b67f585323"

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
