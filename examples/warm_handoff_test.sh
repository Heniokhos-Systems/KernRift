#!/usr/bin/env bash
# Warm-handoff state-survival experiment. amdgpu boots the dGPU (warms it),
# then we hand it to mlrift_pci and read the warm markers via our driver.
# Run as root. dGPU is not the primary display (iGPU is), so this is safe.
#
# Prereqs (build first):
#   MLRift:  ./build/mlrc --arch=x86_64 --target=linux --emit=elfexe \
#              examples/warm_handoff_explore.mlr -o /tmp/warm_handoff_explore
#   KernRift: ./build/krc2 --emit=lkm --arch=x86_64 --target=linux \
#              examples/mlrift_pci.kr -o /tmp/mlrift_pci.ko
set -u
BDF=${1:-0000:03:00.0}
say() { printf '\n=== %s ===\n' "$*"; }
ovr=/sys/bus/pci/devices/$BDF/driver_override
BDF_RE="${BDF//./\\.}"

say "1) take dGPU off vfio-pci, bind amdgpu to warm it"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
echo amdgpu | sudo tee "$ovr"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/amdgpu/bind

say "2) wait for amdgpu to finish init (poll dmesg, up to 30s)"
matched=0
for i in $(seq 1 30); do
  if sudo dmesg | grep -qE "amdgpu $BDF_RE.*(ring .* test|initialized|GPU init|amdgpu_device_ip_init)"; then matched=1; break; fi
  sleep 1
done
[ "$matched" -eq 0 ] && echo "WARNING: amdgpu init not confirmed in 30s — proceeding anyway (check dmesg)"
sudo dmesg | grep -E "amdgpu $BDF_RE" | tail -5
lspci -nnks "$BDF"   # expect: Kernel driver in use: amdgpu

say "3) hand off: unbind amdgpu, bind mlrift_pci (probe claims the WARM card)"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/amdgpu/unbind
echo mlrift_pci | sudo tee "$ovr"
sudo insmod /tmp/mlrift_pci.ko 2>/dev/null || lsmod | grep -q mlrift_pci || { echo "insmod FAILED and module not loaded — aborting"; exit 1; }
sudo chmod 666 /dev/mlrift_pci
echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/bind
lspci -nnks "$BDF"   # expect: Kernel driver in use: mlrift_pci

say "4) read warm markers via mlrift_pci"
sudo /tmp/warm_handoff_explore

say "5) restore: unbind mlrift_pci, rmmod, back to vfio-pci"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/unbind
echo vfio-pci | sudo tee "$ovr"   # leave pinned to vfio-pci — MLRift's default driver for this dGPU
sudo rmmod mlrift_pci
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnks "$BDF"   # expect: Kernel driver in use: vfio-pci

say "dmesg tail"
sudo dmesg | grep -E "mlrift_pci|amdgpu $BDF_RE" | tail -20
