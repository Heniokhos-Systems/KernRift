#!/usr/bin/env bash
# GMC walker bring-up — amdgpu-RESIDENT variant.
#
# Precondition: the dGPU boots OWNED BY amdgpu (the vfio reservation is
# disabled). To set that up once:
#   sudo mv /etc/modprobe.d/vfio-dgpu.conf{,.disabled}
#   sudo update-initramfs -u && sudo reboot
# After reboot, `lspci -nnks 03:00.0` must show "Kernel driver in use: amdgpu".
#
# Flow (NO vfio-pci anywhere — this avoids the vfio_pci_core_runtime_suspend
# NULL-deref hard-hang that the old vfio<->amdgpu<->mlrift churn triggered):
#   amdgpu(warm) -> unbind amdgpu -> bind mlrift_pci -> bring up GMC walker
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
#   * DEV LOOP: needs NO compositor running. `systemctl stop sddm` is NOT enough —
#     the desktop session survives in its own logind scope. Get truly headless via
#     EITHER: boot to text mode (`sudo systemctl set-default multi-user.target` +
#     reboot; later `set-default graphical.target` + reboot to get the desktop
#     back), OR from a TTY end the graphical session (`loginctl terminate-session
#     <wayland-id>`). Then run this script repeatedly — restore auto-recovers via
#     remove+rescan, no per-run reboot.
#
# Prereqs (build first):
#   MLRift:  ./build/mlrc --arch=x86_64 --target=linux --emit=elfexe \
#              examples/gmc_walker_bringup.mlr -o /home/pantelis/mlrift_bin/gmc_walker
#   KernRift: ./build/krc2 --emit=lkm --arch=x86_64 --target=linux \
#              examples/mlrift_pci.kr -o /home/pantelis/mlrift_bin/mlrift_pci.ko
set -u
BDF=${1:-0000:03:00.0}
# Log everything to a file (survives a session crash) AND the console, from the
# very start. Override path with LOG=/path before invoking.
LOG=${LOG:-/home/pantelis/mlrift_logs/warm_gmc_$(date +%Y%m%d-%H%M%S).log}
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "logging to $LOG"
say() { printf '\n=== %s ===\n' "$*"; }
ovr=/sys/bus/pci/devices/$BDF/driver_override
cur_drv() { basename "$(readlink -f /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null || echo none; }

# True if a compositor may be holding the dGPU's DRM render node: either the
# display manager is running, OR a graphical (wayland/x11) logind session is
# live. IMPORTANT: `systemctl stop sddm` does NOT end an already-running desktop
# session — it survives in its own logind scope — so checking the DM service
# alone is NOT sufficient; we must inspect session types via loginctl.
compositor_present() {
  systemctl is-active --quiet display-manager 2>/dev/null && return 0
  local s t
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    t=$(loginctl show-session "$s" -p Type --value 2>/dev/null)
    case "$t" in wayland|x11|mir) return 0 ;; esac
  done
  return 1
}

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
  if compositor_present; then
    echo "  dGPU is now unbound; amdgpu rebind blocked by its -17 sysfs leak."
    echo "  Not doing remove+rescan: a compositor is live and the DRM hot-add would"
    echo "  crash it. REBOOT to restore amdgpu. For an in-session dev loop, NO"
    echo "  compositor may run — note 'systemctl stop sddm' is NOT enough (the"
    echo "  desktop session persists). Boot to multi-user.target, or from a TTY:"
    echo "    loginctl terminate-session <your-wayland-session-id>"
    return
  fi
  say "restore: FLR + PCI remove + rescan (GMC reprogrammed MMHUB; FLR resets it so amdgpu IP discovery can re-read)"
  echo 1 | sudo tee /sys/bus/pci/devices/$BDF/reset  >/dev/null 2>&1   # function-level reset toward power-on
  sleep 1
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

# Warn (do NOT block) if a compositor is live — see DEV LOOP note above.
if compositor_present; then
  echo "WARNING: a graphical session is live. The amdgpu->mlrift unbind may crash"
  echo "  your desktop, and restore will NOT auto-recover (remove+rescan is unsafe"
  echo "  with a compositor up) — it'll leave the dGPU unbound for a reboot."
  echo "  NOTE: 'systemctl stop sddm' does NOT end the session (it persists in its"
  echo "  own logind scope). For a clean dev loop, boot to multi-user.target or run"
  echo "  'loginctl terminate-session <wayland-id>' from a TTY first."
  echo "  Continuing in 5s (Ctrl-C to abort)..."
  sleep 5
fi

trap restore EXIT INT TERM HUP

say "1) load mlrift_pci, hand off the WARM card (amdgpu -> mlrift_pci)"
sudo insmod /home/pantelis/mlrift_bin/mlrift_pci.ko 2>/dev/null || lsmod | grep -q mlrift_pci || { echo "insmod FAILED and module not loaded — aborting"; exit 1; }
sudo chmod 666 /dev/mlrift_pci
echo mlrift_pci | sudo tee "$ovr"                                  # force mlrift_pci to be the only binder
echo "$BDF"     | sudo tee /sys/bus/pci/drivers/amdgpu/unbind
echo "$BDF"     | sudo tee /sys/bus/pci/drivers/mlrift_pci/bind 2>/dev/null || true  # may already be auto-bound via override
lspci -nnks "$BDF"   # expect: Kernel driver in use: mlrift_pci

say "2) bring up GMC walker"
sudo /home/pantelis/mlrift_bin/gmc_walker

say "3) done — restore trap returns the dGPU to amdgpu on exit"

say "dmesg tail (kernel errors)"
sudo dmesg | tail -40
sync
