# Homebrew tap template for zs3.
#
# A tap is a separate repository named `homebrew-zs3`. To publish:
#
#   1. Tag a release (e.g. v0.2.0) — .github/workflows/release.yml attaches
#      the `zs3-aarch64-macos` binary to the GitHub release.
#   2. Create repo `homebrew-zs3` with this file at `Formula/zs3.rb`,
#      filling in `url`, `sha256`, and `version` from the release asset.
#   3. Users install with:
#        brew tap <you>/zs3
#        brew install zs3
#
# Get the sha256 with: shasum -a 256 zs3-aarch64-macos

class Zs3 < Formula
  desc "Local, dev, and edge S3 storage in a static binary"
  homepage "https://github.com/Lulzx/zs3"
  url "https://github.com/Lulzx/zs3/releases/download/v0.3.0/zs3-aarch64-macos"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  version "0.3.0"
  license "WTFPL"

  # macOS ARM64 binary; Intel Macs can build from source (requires Zig 0.16.0):
  #   brew install zig && zig build -Doptimize=ReleaseSmall
  def install
    bin.install "zs3-aarch64-macos" => "zs3"
  end

  service do
    run [opt_bin / "zs3"]
    keep_alive true
    log_path var / "log/zs3.log"
    error_log_path var / "log/zs3.log"
  end

  test do
    system bin / "zs3", "--help"
  end
end
