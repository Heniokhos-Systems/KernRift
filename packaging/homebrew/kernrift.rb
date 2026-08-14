# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.10.0"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "a29bc4bbefa5befdc53642ea4471aeb429d4e7bee6fef7af84b0166a0ad4d954"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "3bb41c94389e5b2b0ea0cd016e0e88b54ec44cd205f3ee589a2df05ea500cbdc"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "b6e5720566d6ca4ce2362a082c284fd5ff0e78a168273ed0518f8feb2a54b8b8"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "29e4a6b7e298b36e97f1efa443e62798c9d29a83dfd4a7c17b888840bdf01213"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "d8005c5c8038c63961492f9deb006650c54cf19708473bf59216e28bddcc2100"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "d715600aefe61832ea5088a96a8f3e1183bd76041bbd95f9aaec4c3f61677184"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "987354c9bfcfbad36d3c433cbdd9b11870de78cb6010b7668a7806e681a6b003"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "67a79330f7ce43454f8f7d8094c0b02df5808394aea7d0335240205cb157370f"
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
      alloc color console cstr fb fixedpoint fmt font fw_cfg fw_cfg_mmio
      gzip heap_bump idt io log map math math_float mem memfast mouse
      net pci ps2 ramfb serial sha256 string time uart_16550 uart_pl011
      vec vga_text widget x86
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
    assert_match "2.10.0", shell_output("#{bin}/krc --version")
  end
end
