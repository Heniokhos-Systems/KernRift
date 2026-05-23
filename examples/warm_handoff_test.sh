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
#                -> restore (on ANY exit): release mlrift_pci, return to amdgpu
#
# RESTORE / DEV LOOP: amdgpu can't simply re-bind in-session — its .remove leaks
# a 'mem_info_preempt_used' sysfs attr, so re-probe fails -17 EEXIST. The fix is a
# PCI remove+rescan, which re-probes amdgpu fresh and re-warms the card. But
# rescan re-adds the GPU = a DRM hot-add, only safe with NO compositor running.
# Therefore:
#   * Live desktop: ONE run per boot. restore leaves the dGPU unbound; reboot to
#     get amdgpu back. (The amdgpu->mlrift unbind itself is empirically survivable
#     under KWin, but the rescan restore is not, so we don't attempt it live.)
#   * DEV LOOP (recommended for iterating): `sudo systemctl stop sddm`, switch to
#     a TTY (Ctrl+Alt+F3) or SSH in, then run this script repeatedly — restore
#     auto-recovers via remove+rescan each time, no reboot. `start sddm` when done.
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
  say "restore: release mlrift_pci, return dGPU to amdgpu"
  echo "$BDF" | sudo tee /sys/bus/pci/drivers/mlrift_pci/unbind >/dev/null 2>&1
  echo ""     | sudo tee "$ovr"                                >/dev/null 2>&1
  sudo rmmod mlrift_pci 2>/dev/null
  echo "$BDF" | sudo tee /sys/bus/pci/drivers/amdgpu/bind      >/dev/null 2>&1
  sleep 1
  if [ "$(cur_drv)" = "amdgpu" ]; then
    echo "  dGPU restored to amdgpu (warm)."
    return
  fi
  # amdgpu re-bind is blocked by its leaked 'mem_info_preempt_used' sysfs attr
  # (-17 EEXIST). PCI remove+rescan destroys the leaked node and re-probes amdgpu
  # fresh (re-warms). rescan = a DRM hot-add though, so only auto-recover when no
  # compositor is running (the intended dev-loop mode).
  if systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "  dGPU is now unbound; amdgpu rebind blocked by its -17 sysfs leak."
    echo "  REBOOT to restore amdgpu — OR for an in-session dev loop, run with the"
    echo "  display manager stopped ('sudo systemctl stop sddm') and this script"
    echo "  will auto-recover via PCI remove+rescan (no reboot)."
    return
  fi
  say "restore: clearing amdgpu -17 leak via PCI remove + rescan"
  echo 1 | sudo tee /sys/bus/pci/devices/$BDF/remove >/dev/null 2>&1
  sleep 1
  echo 1 | sudo tee /sys/bus/pci/rescan              >/dev/null 2>&1
  k=0
  while [ "$k" -lt 25 ]; do
    [ "$(cur_drv)" = "amdgpu" ] && break
    sleep 1; k=$((k + 1))
  done
  if [ "$(cur_drv)" = "amdgpu" ]; then
    echo "  dGPU re-warmed by amdgpu via remove+rescan — ready for another run."
  else
    echo "  WARN: dGPU not on amdgpu after remove+rescan (driver='$(cur_drv)')."
    echo "  Check 'sudo dmesg | tail'; reboot if needed."
  fi
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
