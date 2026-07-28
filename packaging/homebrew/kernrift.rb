# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.8.33"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "6fa4d9ed35db3d4c4731680619650fb57db0c15d398870b9aff7fa3f02b76f5e"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "4c455f5574d4352dad720c1f70e1f3f90456564798f9b944b531242bcb15483f"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "42f891ca0ae1c13443fabaf6dd1421b5f21215bf3943465911e2f25fde0e7f42"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "42850b007bbd71ceddc6c9f44223f0fe3f07cfb4ba715ec2b6cae87269efcd13"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "223ea947f1f573206d5252b699a6464aec86ea2505b327cf90aaa80cba704ad1"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "721971a8fb4996a04da3a04a6d6b6c03dfec33631c5e35b94fff44d1c178aa05"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "cefff58ca3390b9220e916603314d4b4fa816899783c98c6abc7f39eabc83998"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "060c075367b92482badd20598d752ac439c11e0d73b266de4d49e8d7d1919d96"
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
    assert_match "2.8.33", shell_output("#{bin}/krc --version")
  end
end
