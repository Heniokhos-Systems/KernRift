# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.8.34"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "9ac17d2e0d3f79f35690d6a1d74ec1f91b1f985d6f9554435f1564aa98173844"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "b19924c2286d6e700ca0a9072e2720eb33b7af1c5e17b84a28f112cd5aaef681"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "9048bbdfc2628ca102b4218d28681229bad66c9f73e72de509407f1ed9683071"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "3c37fb68eb7cb6909ffa23b835de8fb63d98a4e868d96d804dabe43798ef727b"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "d3947044027ea775aa96e584bb0e4faf58c5e1957b283752ae11c1cf0f7d188e"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "75b9817d064d44459b39b547a7d3311a51df0097b3dd60bba4be20e2d683dfbf"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "e6b1699f1d2cb2d0dd0f80dac234bb41abcd5097fa9177c4b41fd302523dcdc0"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "4c3bf4eb2fdbc166d18fa89205395d83a13f8724834998798b9f8b52f728d3f3"
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
    assert_match "2.8.34", shell_output("#{bin}/krc --version")
  end
end
