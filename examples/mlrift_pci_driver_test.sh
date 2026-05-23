#!/usr/bin/env bash
# Phase C live test: bind mlrift_pci (now a real PCI driver) to the dGPU,
# run the device-access tests against the probe-claimed device, unbind,
# and ASSERT that vfio-pci rebinds cleanly — i.e. no more
# "Resources present before probing" / -EBUSY (the bug the PCI-driver
# restructure fixes). Run as root. The dGPU is not the primary display
# (iGPU is), so unbinding it is safe.
#
# Build first (from the KernRift repo dir):
#   ./build/krc2 --emit=lkm --arch=x86_64 --target=linux examples/mlrift_pci.kr -o /tmp/mlrift_pci.ko
#   cc -O2 -o /tmp/mlrift_iommu_test examples/mlrift_iommu_test.c
#   cc -O2 -o /tmp/mlrift_irq_test   examples/mlrift_irq_test.c
set -u
BDF=${1:-0000:03:00.0}
say() { printf '\n=== %s ===\n' "$*"; }

say "load module (registers misc device + PCI driver; no device claimed yet)"
sudo insmod /tmp/mlrift_pci.ko && sudo chmod 666 /dev/mlrift_pci
ls -d /sys/bus/pci/drivers/mlrift_pci 2>/dev/null && echo "PCI driver registered"

say "take the dGPU off vfio-pci and bind it to mlrift_pci (probe claims it)"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
echo mlrift_pci | sudo tee "/sys/bus/pci/devices/$BDF/driver_override"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/bind
lspci -nnks "$BDF"   # expect: Kernel driver in use: mlrift_pci

say "device-access tests against the probe-claimed device"
/tmp/mlrift_iommu_test "$BDF"
/tmp/mlrift_irq_test "$BDF"

say "release: unbind from mlrift_pci (remove() tears down + disables), clear override, rmmod"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/unbind
echo | sudo tee "/sys/bus/pci/devices/$BDF/driver_override"
sudo rmmod mlrift_pci

say "THE REGRESSION ASSERTION: vfio-pci rebinds with no EBUSY, no remove/rescan"
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnks "$BDF"   # expect: Kernel driver in use: vfio-pci

say "dmesg tail"
sudo dmesg | grep -E "mlrift_pci|Resources present" | tail -20
