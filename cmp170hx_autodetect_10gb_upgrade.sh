#!/usr/bin/env bash
# Auto-detect 10GB VF upgrade for the verified 610.43.03 CMP 170HX single-card build.
# Usage: bash cmp170hx_threecard_upgrade.sh build  (no installation)
#        bash cmp170hx_threecard_upgrade.sh stage  (install for NEXT boot, no reboot)
set -Eeuo pipefail
K=6.6.0-hiveos
SRC=/home/user/vf-build-only-native_vf_candidate-20261004-110244/open-gpu-kernel-modules-610.43.03
CURRENT=/lib/modules/$K/updates/cmpunlocker
SAFE=/home/user/vf-singlecard-known-good-20261004
OUT=/home/user/vf-auto10gb-candidate-20261004
ORIG_SHA=d39f91342dd9bd2337bbc4e494b37dd36454fb59f71f3b401da7b808191d0d57
BASEROM=92.00.66.00.02
[ "$(id -u)" = 0 ] || { echo 'ERROR: root required'; exit 1; }
[ "$(uname -r)" = "$K" ] || { echo 'ERROR: wrong kernel'; exit 1; }
[ -f "$SRC/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c" ] || { echo 'ERROR: compiled source missing'; exit 1; }
[ -f "$SRC/src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c" ] || { echo 'ERROR: compiled source missing'; exit 1; }
[ -x /home/user/restore-cmpunlocker.sh ] || { echo 'ERROR: recovery script missing'; exit 1; }
mkdir -p "$SAFE" "$OUT"
MODULES=(nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem)
case "${1:-}" in
build)
  printf '%s  %s\n' "$ORIG_SHA" "$CURRENT/nvidia.ko" | sha256sum -c - || { echo 'ERROR: installed one-card module no longer matches'; exit 1; }
  printf '%s  %s\n' "$ORIG_SHA" "$SRC/kernel-open/nvidia.ko" | sha256sum -c - || { echo 'ERROR: source-built one-card module mismatch'; exit 1; }
  for m in "${MODULES[@]}"; do
    [ -s "$CURRENT/$m.ko" ] && [ -s "$SRC/kernel-open/$m.ko" ] || exit 1
    cp -a "$CURRENT/$m.ko" "$SAFE/$m.ko"
  done
  cp -a /etc/modprobe.d "$SAFE/modprobe.d" 2>/dev/null || true
  cp -a "$SRC/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c" "$SAFE/kernel_gsp.c"
  cp -a "$SRC/src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c" "$SAFE/message_queue_cpu.c"
  # Apply the same selective policy in BOTH the VBIOS registry injection
  # and the expanded GSP command-queue path. 0xffffffff means all matching
  # 0x2082 10GB cards, whatever their dynamic PCI bus numbers. The original
  # native VBIOS-version check remains enforced in kernel_gsp.c.
  python3 - "$SRC" <<'PYCODE'
import pathlib, sys
src=pathlib.Path(sys.argv[1])/'src/nvidia/src/kernel/gpu/gsp'
a=src/'kernel_gsp.c'
b=src/'message_queue_cpu.c'
x=a.read_text(); y=b.read_text()
old_a='gpuGetBus(pGpu) != targetBus || gpuGetDevice(pGpu) != 0U)'
old_b='cmpEnable == 1 && gpuGetBus(pGpu) == cmpBus)'
# Original single-card driver ONLY. Fail closed on unexpected or already
# modified source; never risk rebuilding from an unrecognized source state.
assert x.count(old_a)==1, 'unexpected or previously patched VBIOS filter source'
assert y.count(old_b)==1, 'unexpected or previously patched command-queue filter source'
assert x.count('"92.00.66.00.02"')==2, 'unexpected ROM-version guard'
assert x.count('cmpVbiosImage')>=3, 'expected embedded native VBIOS image missing'
assert '(pGpu->idInfo.PCIDeviceID >> 16) != 0x2082U' in x
assert '(pGpu->idInfo.PCIDeviceID >> 16) == 0x2082U' in y
assert '"RMCmpVbiosOverride"' in x and '"RMCmpVbiosOverride"' in y
new_a=('(targetBus != 0xFFFFFFFFU && gpuGetBus(pGpu) != targetBus) || '
       'gpuGetDevice(pGpu) != 0U)')
new_b=('cmpEnable == 1 && (cmpBus == 0xFFFFFFFFU || '
       'gpuGetBus(pGpu) == cmpBus))')
a.write_text(x.replace(old_a,new_a))
b.write_text(y.replace(old_b,new_b))
print('PASS: auto-detect 0x2082; native ROM-version check retained; other GPU types excluded')
PYCODE
  echo '=== COMPILE COMPLETE MODULE SET, NO INSTALL ==='
  if ! make -C "$SRC" -j2 modules SYSSRC="/lib/modules/$K/build" CC=gcc; then
    echo 'BUILD FAILED. Installed/loaded GPU driver is untouched.'
    echo 'Source can be restored from:' "$SAFE"
    exit 1
  fi
  for m in "${MODULES[@]}"; do
    [ -s "$SRC/kernel-open/$m.ko" ] || exit 1
    [ "$(modinfo -F version "$SRC/kernel-open/$m.ko")" = 610.43.03 ] || exit 1
    [ "$(modinfo -F vermagic "$SRC/kernel-open/$m.ko")" = '6.6.0-hiveos SMP preempt mod_unload modversions ' ] || exit 1
    install -m 0644 "$SRC/kernel-open/$m.ko" "$OUT/$m.ko"
  done
  printf '%s  %s\n' "$ORIG_SHA" "$OUT/nvidia.ko" | sha256sum -c - >/dev/null 2>&1 && { echo 'ERROR: rebuilt nvidia.ko unchanged';exit 1; } || true
  sha256sum "$OUT/nvidia.ko"
  echo 'BUILD COMPLETE. Current driver NOT changed. Next: stage.'
  ;;
stage)
  [ -s "$OUT/nvidia.ko" ] || { echo 'ERROR: run build first'; exit 1; }
  printf '%s  %s\n' "$ORIG_SHA" "$CURRENT/nvidia.ko" | sha256sum -c -
  printf '%s  %s\n' "$ORIG_SHA" "$SAFE/nvidia.ko" | sha256sum -c -
  [ "$(systemctl is-enabled cmp-vf-autorestore.timer 2>/dev/null || true)" != 'enabled' ] || { echo 'ERROR: old rollback timer still enabled';exit 1; }
  [ -f /home/user/vf-rollback-20261004-111311/cmpunlocker/nvidia.ko ] || exit 1
  # Verify the expected three 10GB cards are present for this first
  # multi-card test. No PCI bus or GPU index is hardcoded into driver policy.
  count=$(lspci -Dnn | grep -Eic '\[10de:2082\]' || true)
  echo "Detected $count 10GB 170HX cards (PCI device 10de:2082)"
  [ "$count" = 3 ] || { echo 'ERROR: expected 3 cards for initial multi-card test'; exit 1; }
  for m in "${MODULES[@]}"; do
    [ -s "$OUT/$m.ko" ] || exit 1
    [ "$(modinfo -F version "$OUT/$m.ko")" = '610.43.03' ] || exit 1
    [ "$(modinfo -F vermagic "$OUT/$m.ko")" = '6.6.0-hiveos SMP preempt mod_unload modversions ' ] || exit 1
  done
  # Re-arm 15-minute rescue on next boot; not launched now.
  systemctl enable cmp-vf-autorestore.timer
  for m in "${MODULES[@]}"; do
    install -m 0644 "$OUT/$m.ko" "$CURRENT/$m.ko"
  done
  # Keep the other four working NVIDIA registry settings intact.
  cat > /etc/modprobe.d/cmp-vf-experimental.conf <<'CONF'
options nvidia NVreg_RegistryDwords="RM1457588=1;RM1774520=1;RmForceEnableGen2=1;RMPcieLinkSpeed=0x1;RMCmpVbiosOverride=1;RMCmpVbiosTargetBus=0xffffffff"
CONF
  depmod -a "$K"
  echo '=== NEXT-BOOT DRIVER ==='
  sha256sum "$CURRENT/nvidia.ko"
  modprobe -D nvidia | head -n 6
  echo '=== REGISTRY ==='
  modprobe -c | grep '^options nvidia '
  echo '=== ROLLBACK ==='
  systemctl is-enabled cmp-vf-autorestore.timer
  echo 'AUTO-DETECT DRIVER STAGED. Not rebooted. Rollback armed for next boot.'
  ;;
*) echo "Usage: bash $0 build | stage";exit 2;;
esac
