# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.9.0"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "fcb1f5212b523ec02319ddb84c4ab10ebd8d600b65ba034f7c1b9838e155dc33"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "739cc3faed07e2b99f302f62c4384c501c232b3c19ec2289aabc6ecc9cf113a3"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "f63c4de71dac229656e0334cad6d17a1f1de84cdc55df81a2ac91683c4dd55d6"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "038f4ba591f25e53f3e416b04ce6a5ed4475baad242389fd01468fcfc337684f"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "15578e49f04a2e1f1e3ec8ca4d6b6ff6eee66c4293dfa037ffacae1517418f8c"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "3767aeb4ac34664ee03554d638e0d263b9302cd9981a8fd298bb70e8cb1e3be4"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "d278c07613948c484146e66b36efd66b79739cf54e6fcf2f68d47e82befb1b6e"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "c1066890d90524ed558c9478ae83acc55631df395ab25e31e122e8c3842da3a5"
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
    assert_match "2.9.0", shell_output("#{bin}/krc --version")
  end
end
