# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.8.30"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "a4c9931a57b2dd4e6cb7f729bdd3c54b02bee4a20a8636da441bff441a87bb79"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "2c0bb7bfa2b2c014a99516feda882dfe065d4ce5e7ee0eb7dc94309e55b6e158"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "abef51c610278dc46d1d81aca6ac36bedb55c44e9efd75e46120b1e8e90248ce"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "e5ab76558ddf87a3ba2d96014f7a2132def3629798754c6a472252ca5ddf924e"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "699f684a3eeb2f6012718a6c6cc9a7a612db65ab232f6484a87eb9c31242fbef"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "d8754af21370633aaa9b736c3cb8d0ce174239f5eb092c65f2baa5478171b8b1"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "daecd6dc975546662a8cad4a25081f220caa03b01620afa38ca12e640dd0d9d5"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "4e0407be30bf0eb6416109d49e2c1fbc2ec536b873c00006ca2ab832aadb5b1a"
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
    assert_match "2.8.30", shell_output("#{bin}/krc --version")
  end
end
