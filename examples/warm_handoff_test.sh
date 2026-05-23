#!/usr/bin/env bash
# Warm-handoff state-survival experiment — amdgpu-RESIDENT variant.
#
# Precondition: the dGPU boots OWNED BY amdgpu (the vfio reservation is
# disabled). To set that up once:
#   sudo mv /etc/modprobe.d/vfio-dgpu.conf{,.disabled}
#   sudo update-initramfs -u && sudo reboot
# After reboot, `lspci -nnks 03:00.0` must show "Kernel driver in use: amdgpu".
#
# Flow (NO vfio-pci anywhere — this avoids the vfio_pci_core_runtime_suspend
# NULL-deref hard-hang that the old vfio<->amdgpu<->mlrift churn triggered):
#   amdgpu(warm) -> unbind amdgpu -> bind mlrift_pci -> read warm markers
#                -> restore (on ANY exit): unbind mlrift_pci, rmmod, rebind amdgpu
#
# HAZARD: under a LIVE KDE/Wayland session the amdgpu->mlrift unbind hot-removes
# a GPU that KWin enumerated at boot, which MAY crash the compositor and log you
# out. This script only WARNS (you opted to try live). If it logs you out, the
# restore trap still puts the dGPU back on amdgpu; re-run from a text console
# (Ctrl+Alt+F3) after `sudo systemctl stop sddm` for a guaranteed-clean run.
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
cur_drv() { basename "$(readlink -f /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null || echo none; }

# Always put the dGPU back on amdgpu, however we exit (normal, error, or a
# SIGHUP/TERM from a crashing session) — never leave it stranded on mlrift_pci.
restore() {
  trap - EXIT INT TERM HUP
  say "restore: return dGPU to amdgpu"
  echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/unbind >/dev/null 2>&1
  echo ""     | sudo tee "$ovr"                                >/dev/null 2>&1
  sudo rmmod mlrift_pci 2>/dev/null
  echo "$BDF" | sudo tee /sys/bus/pci/drivers/amdgpu/bind      >/dev/null 2>&1
  sleep 1; lspci -nnks "$BDF" | sed -n '1p;/driver in use/p'
}

# Precondition: dGPU must start on amdgpu (warm). Nothing to restore if not.
if [ "$(cur_drv)" != "amdgpu" ]; then
  echo "ABORT: $BDF is bound to '$(cur_drv)', expected 'amdgpu'." >&2
  echo "  The dGPU must boot owned by amdgpu (disable the vfio reservation):" >&2
  echo "    sudo mv /etc/modprobe.d/vfio-dgpu.conf{,.disabled}; sudo update-initramfs -u; sudo reboot" >&2
  exit 1
fi

# Warn (do NOT block) if a compositor is live — see HAZARD note above.
if systemctl is-active --quiet display-manager 2>/dev/null; then
  echo "WARNING: a display manager is active. The amdgpu->mlrift unbind may crash"
  echo "  your KDE session. If it does, the restore trap still rebinds amdgpu;"
  echo "  re-run from a TTY after 'sudo systemctl stop sddm' for a clean run."
  echo "  Continuing in 5s (Ctrl-C to abort)..."
  sleep 5
fi

trap restore EXIT INT TERM HUP

say "1) load mlrift_pci, hand off the WARM card (amdgpu -> mlrift_pci)"
sudo insmod /tmp/mlrift_pci.ko 2>/dev/null || lsmod | grep -q mlrift_pci || { echo "insmod FAILED and module not loaded — aborting"; exit 1; }
sudo chmod 666 /dev/mlrift_pci
echo mlrift_pci | sudo tee "$ovr"                                  # force mlrift_pci to be the only binder
echo "$BDF"     | sudo tee /sys/bus/pci/drivers/amdgpu/unbind
echo "$BDF"     | sudo tee /sys/bus/pci/drivers/mlrift_pci/bind 2>/dev/null || true  # may already be auto-bound via override
lspci -nnks "$BDF"   # expect: Kernel driver in use: mlrift_pci

say "2) read warm markers via mlrift_pci"
sudo /tmp/warm_handoff_explore

say "3) done — restore trap returns the dGPU to amdgpu on exit"
