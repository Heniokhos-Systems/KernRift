# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.8.31"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "3ba6b5af109821ca7230cc02a4fe2c8b676c249b47beb136ffc6be900dc1a477"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "270c420755e2dcd6b826c237aa9a23bf015634173c48f2cbb11c570efe7f2f89"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "379598a17a8254f71962eb1dd4e82c9e88b313fc81d420841401449e4bc30880"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "5d531147cdd4ae42c605d90f7e458a6a1d6e077cd9cae3d829d0844bad658ff6"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "9461d3a926339a822aad1e9ca2411cb592a425fb076321acf66433e5a54fda00"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "f0b01566767fe2f5299ffe744a0735fd81fd95af00c4d6d7f0e4b6766c307549"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "380eaac52c6e7243417e58817eeff22cc1136dd3300e44e62b5933ae78b42e73"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "25c5458631b80ecb7d7d45909a50ab87c6fb79f9e6c1dcf2a3382ad3c90e1368"
      end
    end
  end

  def install
    # The stable download IS the krc binary.
    bin.install stable.url.split("/").last => "krc"

    # kr runner (checksum-verified via the resource above).
    resource("kr").stage { bin.install Dir["*"].first => "kr" }

    # Standard library. krc searches Homebrew's prefix (share/kernrift) as of
    # v2.8.30, so installing here needs no wrapper or KR_STDLIB.
    std = share/"kernrift/std"
    std.mkpath
    %w[
      alloc string io math math_float fmt mem memfast vec map
      color fb fixedpoint font widget time log net sha256
    ].each do |m|
      system "curl", "-fsSL", "-o", std/"#{m}.kr", "#{RAW}/std/#{m}.kr"
    end
  end

  test do
    # Importing a stdlib module is the real test: it only compiles if the
    # formula installed std/ where krc searches (the Homebrew prefix — the
    # reason v2.8.30 added that path). A builtin-only program would pass even
    # with the stdlib missing, so it must import.
    (testpath/"t.kr").write <<~KR
      import "std/io.kr"
      fn main() -> uint64 {
          return 0
      }
    KR
    system bin/"krc", "t.kr", "-o", "t.krbo"
    assert_predicate testpath/"t.krbo", :exist?
    assert_match "2.8.31", shell_output("#{bin}/krc --version")
  end
end
