# This formula exists in two places, byte-for-byte identical: the main repo at
# homebrew/s1-mini-engine.rb and the tap at nub235/homebrew-tap, Formula/s1-mini-engine.rb.
# release.sh rewrites the url and sha256 below on every release, so do not
# hand-edit those two lines — cut a release, then copy this file to the other side.
class S1MiniEngine < Formula
  desc "Engine for running Superwhisper S1-mini to normalize ASR transcripts"
  homepage "https://github.com/nub235/s1-mini-engine"
  url "https://github.com/nub235/s1-mini-engine/releases/download/v1.1.0/s1-mini-engine-v1.1.0-macos-arm64.tar.gz"
  sha256 "0131ae7f08ec86144ce88d70d1de9d17fb07d574ad671542cf8c7b0a946e1cf5"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    # The executable links llama.framework from @loader_path, so the framework has
    # to sit in the same directory as the binary. Both go under libexec; only the
    # binary is exposed on PATH, via a symlink that the loader resolves correctly.
    libexec.install "s1-mini-engine", "llama.framework", "LICENSE"
    bin.install_symlink libexec/"s1-mini-engine"
    doc.install "README.md"
  end

  def caveats
    <<~EOS
      The model weights are not bundled with the engine. Fetch them once with:
        s1-mini-engine pull
    EOS
  end

  test do
    assert_match "s1-mini-engine #{version}", shell_output("#{bin}/s1-mini-engine --version")
  end
end
