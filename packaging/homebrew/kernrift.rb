# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.8.32"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "88b18484ad92831c24a10e1110f90806cd4e4021e4dc838c279a1b439e62f38a"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "1c3373c9f40041ae01533af6a9448d7efa731adeccd046509635bbb247b9ced4"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "630bb540b5c3fcbd82c1e808e667aea270027c908580f4b21899fc27c2aeedd8"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "9bc76b74b7a80a793af6d29aba99e08228268f86ded262d3a7360ad884c69454"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "5b2f0b4788af0c7462c681e00e5cce11eee8e20728258cac2cba2ff78ae65552"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "187cac2a4fded623105a7be74cd69075d121f1d6810dcd623c00c77f59c84071"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "ede0a58541966fd67d9de55767a8cdd82361e628011ff0b0103e19e64599e285"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "1d441e0bd2acebe28be9c5d24bf9109015ee746b95a0984391c61b58b0046d0c"
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
    assert_match "2.8.32", shell_output("#{bin}/krc --version")
  end
end
