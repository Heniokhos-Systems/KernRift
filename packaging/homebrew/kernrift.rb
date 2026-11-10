# typed: false
# frozen_string_literal: true

# Homebrew formula for KernRift. Lives in the tap Heniokhos-Systems/homebrew-kernrift
# as Formula/kernrift.rb, so users run:
#   brew install heniokhos-systems/kernrift/kernrift
class Kernrift < Formula
  desc "Self-hosted systems language compiler for kernel and bare-metal development"
  homepage "https://kernrift.org"
  version "2.11.0"
  license "Apache-2.0"

  REL = "https://github.com/Heniokhos-Systems/KernRift/releases/download/v#{version}".freeze
  RAW = "https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/v#{version}".freeze

  on_macos do
    on_arm do
      url "#{REL}/krc-macos-arm64"
      sha256 "8479943083f126ab81414fd852e7b757fed358a84c768dc0578f14f1cf31db71"
      resource "kr" do
        url "#{REL}/kr-macos-arm64"
        sha256 "955dd20cafb554d56a9236bfb5c186dd5c0cee50ddf5caa292c4a6dc7126e31b"
      end
    end
    on_intel do
      url "#{REL}/krc-macos-x86_64"
      sha256 "bcc8d0bbbfc972d10f2cf5bdc8a42aa1794fe12146d168e79bd8509361d79a1c"
      resource "kr" do
        url "#{REL}/kr-macos-x86_64"
        sha256 "c55bac153bd110878d9fbf1beca6a7863ede1d9509ef0852f78142fe3f5e739b"
      end
    end
  end

  on_linux do
    on_arm do
      url "#{REL}/krc-linux-arm64"
      sha256 "455f4f04fefd023368135038bf871684d4f74bf8c97430e26335f4bd34c87d6e"
      resource "kr" do
        url "#{REL}/kr-linux-arm64"
        sha256 "be44a6ff5c5f2cda44f0b8112936673e7a889e37838bea7041592f0558e24961"
      end
    end
    on_intel do
      url "#{REL}/krc-linux-x86_64"
      sha256 "c745db1d65264f8b71345e209909a8187807d8121485f53e565668fe2156b676"
      resource "kr" do
        url "#{REL}/kr-linux-x86_64"
        sha256 "c22cb18d95782b7c9f053438189879d20d697689d41b332af112d85a22f25bea"
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
      alloc apexrift args color console cstr fb fixedpoint fmt font
      fw_cfg fw_cfg_mmio gc_init gmc gmc_constants gpu_activate
      gpu_cp_load gpu_imu_load gpu_mes_load gpu_mes_queue gpu_navi32
      gpu_pm4 gpu_portable gpu_queue gpu_rlc_load gzip heap_bump idt io
      log map math math_float mem memfast mouse net pci pci_core
      pci_ecam pci_port ps2 ramfb serial sha256 string sys time
      uart_16550 uart_pl011 vec vga_text widget win32 x86
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
    assert_match "2.11.0", shell_output("#{bin}/krc --version")
  end
end
