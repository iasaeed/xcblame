# Homebrew formula template for the prebuilt macOS binary. Do not fill the four placeholders (version, url, sha256 and
# homepage, written between double underscores) by hand: `make formula` (Scripts/make-formula.sh) fills them from a
# built release tarball and writes the result to dist/xcblame.rb, which goes into the tap as Formula/xcblame.rb.
class Xcblame < Formula
  desc "Xcode build-time analyzer and fixer"
  homepage "__HOMEPAGE__"
  version "__VERSION__"
  url "__URL__"
  sha256 "__SHA256__"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "xcblame"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/xcblame --version")
  end
end
