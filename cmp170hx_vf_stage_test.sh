#!/usr/bin/env bash
# Stages test driver and automatic rollback, but does NOT reboot or unload running modules.
set -euo pipefail
K=6.6.0-hiveos
B=/home/user/vf-rollback-20261004-111311
N=/home/user/vf-build-only-native_vf_candidate-20261004-110244/open-gpu-kernel-modules-610.43.03/kernel-open
D=/lib/modules/$K/updates/cmpunlocker
[ "$(id -u)" = 0 ] || { echo 'Must run as root'; exit 1; }
[ "$(uname -r)" = "$K" ] || { echo 'Wrong kernel'; exit 1; }
[ -x /home/user/restore-cmpunlocker.sh ] || { echo 'Restore script missing'; exit 1; }
[ -d "$B/modprobe.d" ] || { echo 'Original config backup missing'; exit 1; }
printf '%s  %s\n' 'e49ca2885fb290807a391aa6c61fb7cb8a5b8816d703fcd711cf263384d15347' "$B/cmpunlocker/nvidia.ko" \
  | sha256sum -c -
printf '%s  %s\n' 'e49ca2885fb290807a391aa6c61fb7cb8a5b8816d703fcd711cf263384d15347' "$D/nvidia.ko" \
  | sha256sum -c -
printf '%s  %s\n' 'd39f91342dd9bd2337bbc4e494b37dd36454fb59f71f3b401da7b808191d0d57' "$N/nvidia.ko" \
  | sha256sum -c -
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
  [ -s "$N/$m.ko" ] && [ -s "$B/cmpunlocker/$m.ko" ] || { echo "Missing $m module"; exit 1; }
  [ "$(modinfo -F version "$N/$m.ko")" = 610.43.03 ] || exit 1
  [ "$(modinfo -F vermagic "$N/$m.ko")" = "6.6.0-hiveos SMP preempt mod_unload modversions " ] || exit 1
done
# Arm a rollback on the next boot, 15 minutes after boot. Never start the timer now.
cat >/etc/systemd/system/cmp-vf-autorestore.service <<'UNIT'
[Unit]
Description=Restore known-good CMPUnlocker after experimental VF boot
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/systemctl disable cmp-vf-autorestore.timer; /home/user/restore-cmpunlocker.sh && /sbin/reboot'
UNIT
cat >/etc/systemd/system/cmp-vf-autorestore.timer <<'UNIT'
[Unit]
Description=VF test safety rollback after boot
[Timer]
OnBootSec=15min
AccuracySec=1s
Unit=cmp-vf-autorestore.service
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable cmp-vf-autorestore.timer
# Stage all modules in the original priority path, preserving non-module files.
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
  install -m 0644 "$N/$m.ko" "$D/$m.ko"
done
# One combined NVreg parameter; preserve all previously observed settings.
sed -i '/^options[[:space:]]\+nvidia[[:space:]]\+NVreg_RegistryDwords=/d' \
 /etc/modprobe.d/nvidia.conf /etc/modprobe.d/cmp-pcie-gen2.conf
cat >/etc/modprobe.d/cmp-vf-experimental.conf <<'CONF'
options nvidia NVreg_RegistryDwords="RM1457588=1;RM1774520=1;RmForceEnableGen2=1;RMPcieLinkSpeed=0x1;RMCmpVbiosOverride=1;RMCmpVbiosTargetBus=2"
CONF
depmod -a "$K"
echo '=== MODULE THAT WILL LOAD AFTER REBOOT ==='
modinfo -n nvidia
sha256sum "$D/nvidia.ko"
echo '=== RESOLVED MODULE ==='
modprobe -D nvidia | head -n 12
echo '=== NVIDIA CONFIG ==='
modprobe -c | grep '^options nvidia '
echo '=== ROLLBACK ARMED FOR NEXT BOOT ==='
systemctl is-enabled cmp-vf-autorestore.timer
printf '\nREADY TO REBOOT (not rebooted). Rollback occurs 15min after next boot unless disabled.\n'
