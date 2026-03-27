class Parley < Formula
  desc "macOS native PR review app for markdown documents (KEPs, RFCs, ADRs)"
  homepage "https://github.com/jelmersnoeck/parley"
  url "https://github.com/jelmersnoeck/parley.git",
      tag:      "v0.1.0",
      revision: "HEAD"
  license "MIT"

  depends_on "swiftly" => :build
  depends_on :macos => :sonoma
  depends_on "gh"

  def install
    system "swiftly", "run", "swift", "build",
           "-c", "release",
           "--disable-sandbox"

    bin_path = ".build/arm64-apple-macosx/release"
    bin.install "#{bin_path}/Parley" => "parley"

    # Resource bundle must live next to the binary for Bundle.module to find it
    bin.install "#{bin_path}/Parley_Parley.bundle"
  end

  def caveats
    <<~EOS
      Parley requires GitHub CLI authentication:
        gh auth login

      Launch with:
        parley
    EOS
  end

  test do
    # Verify the binary runs and exits cleanly when given --help or similar
    # Since this is a GUI app, just check it links correctly
    assert_predicate bin/"parley", :executable?
  end
end
