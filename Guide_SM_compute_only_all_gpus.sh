#!/bin/bash
set -Eeuo pipefail

echo "================================================"
echo "=== CMP 170HX — Compute-Only All-GPU Unlock  ==="
echo "=== Auto-detect 10de:20b0 / 10de:20c2       ==="
echo "================================================"

WORKDIR="${WORKDIR:-/home/user/isolated}"
GSP_580="${GSP_580:-/lib/firmware/nvidia/580.159.04/gsp_tu10x.bin}"
PATCHER="${WORKDIR}/patch_gsp.py"
PAYLOAD="${WORKDIR}/payload_compute_only.bin"
PATCHED_GSP="${WORKDIR}/gsp_patched_compute_only.bin"
GSP_BACKUP="${GSP_580}.backup"
GSP_REPLACED=0

declare -a GPUS=()

die() {
    echo "ERROR: $*" >&2
    exit 1
}

restore_gsp() {
    if [ "$GSP_REPLACED" -eq 1 ] && [ -f "$GSP_BACKUP" ]; then
        echo "Restoring original GSP..."
        cp -f "$GSP_BACKUP" "$GSP_580" || true
        sync
        GSP_REPLACED=0
    fi
}

cleanup() {
    local rc=$?
    restore_gsp
    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "Pipeline stopped with error $rc."
        echo "The stock GSP restoration was attempted."
        echo "A complete AC power cycle may be required if the driver or a GPU is wedged."
    fi
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "Run as root."
[ -d "$WORKDIR" ] || die "Missing work directory: $WORKDIR"
[ -f "$PATCHER" ] || die "Missing patcher: $PATCHER"
[ -f "$GSP_580" ] || die "Missing exact GSP: $GSP_580"

mapfile -t GPUS < <(
    lspci -Dnn |
    awk 'tolower($0) ~ /10de:(20b0|20c2)/ {print $1}'
)

[ "${#GPUS[@]}" -gt 0 ] || die "No eligible GA100 GPUs found."

echo "Detected ${#GPUS[@]} eligible GPU(s):"
printf '  %s\n' "${GPUS[@]}"
echo ""

for gpu in "${GPUS[@]}"; do
    [ -e "/sys/bus/pci/devices/$gpu/resource0" ] ||
        die "Missing BAR0 resource for $gpu"
    [ -e "/sys/bus/pci/devices/$gpu/reset" ] ||
        die "Missing FLR reset interface for $gpu"
done

if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "WARNING: A graphical session appears active."
    echo "Stopping it may kill this terminal."
    read -r -p "Type CONTINUE to proceed: " answer
    [ "$answer" = "CONTINUE" ] || die "Cancelled."
fi

echo "This will stop all NVIDIA workloads and process every eligible GPU above."
read -r -p "Type UNLOCK-ALL to continue: " answer
[ "$answer" = "UNLOCK-ALL" ] || die "Cancelled."

stop_gpu_users() {
    echo ">>> Stopping miners, display services, and NVIDIA users..."
    command -v miner >/dev/null 2>&1 && miner stop || true
    pkill -9 rigel 2>/dev/null || true
    pkill -9 peakminer 2>/dev/null || true
    systemctl stop nvidia-persistenced 2>/dev/null || true
    systemctl stop gdm3 sddm lightdm display-manager 2>/dev/null || true
    killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true

    local mypid=$$
    local dev pids pid
    for dev in /dev/nvidia* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm*; do
        [ -e "$dev" ] || continue
        pids="$(fuser "$dev" 2>/dev/null | tr ' ' '\n' | grep -v "^${mypid}$" | xargs || true)"
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
    done
    sleep 3
}

unload_nvidia() {
    echo ">>> Unloading NVIDIA modules..."
    modprobe -r nvidia-uvm 2>/dev/null || true
    modprobe -r nvidia_drm 2>/dev/null || true
    modprobe -r nvidia_modeset 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true

    if lsmod | grep -q '^nvidia'; then
        echo "Graceful unload failed; forcing removal..."
        rmmod -f nvidia_uvm 2>/dev/null || true
        rmmod -f nvidia_drm 2>/dev/null || true
        rmmod -f nvidia_modeset 2>/dev/null || true
        rmmod -f nvidia 2>/dev/null || true
    fi

    if lsmod | grep -q '^nvidia'; then
        lsmod | grep '^nvidia' || true
        die "NVIDIA modules are still loaded."
    fi
}

flr_all() {
    local pass="$1"
    echo ">>> FLR pass $pass across ${#GPUS[@]} GPU(s)..."
    local gpu
    for gpu in "${GPUS[@]}"; do
        echo "  Resetting $gpu"
        echo 1 > "/sys/bus/pci/devices/$gpu/reset" ||
            die "FLR failed on $gpu during pass $pass"
        sleep 1
    done
    sleep 3
}

build_payload() {
    echo ">>> Building compute-only payload..."
    cd "$WORKDIR"

    python3 - "$PAYLOAD" <<'PYEOF'
import struct
import sys

output = sys.argv[1]
PAYLOAD_SIZE = 0xF800
DMA_TARGET = 0x0800
CANARY = 0xFACEB13D
CANARY_ADDR = 0x6340

# Compute-only: PLM unlock. No STRAP or LMR writes.
WRITES = [
    (0x00823804, 0xFFFFFFFF),
]

payload = bytearray(PAYLOAD_SIZE)

def w32(dmem, value):
    off = dmem - DMA_TARGET
    if not (0 <= off <= len(payload) - 4):
        raise ValueError(f"DMEM address outside payload: 0x{dmem:X}")
    struct.pack_into("<I", payload, off, value & 0xFFFFFFFF)

w32(CANARY_ADDR, CANARY)

a = 0xFF48
for addr, value in WRITES:
    w32(a + 0x00, CANARY_ADDR)
    w32(a + 0x04, 0)
    w32(a + 0x08, value)
    w32(a + 0x0C, addr)
    w32(a + 0x10, CANARY)
    w32(a + 0x14, 0x000010B9)
    a += 0x18

w32(a + 0x00, 0)
w32(a + 0x04, 0)
w32(a + 0x08, 0)
w32(a + 0x0C, 0)
w32(a + 0x10, CANARY)
w32(a + 0x14, 0x0000810D)

with open(output, "wb") as f:
    f.write(payload)

print(f"Built {len(payload)} bytes: {output}")
PYEOF
}

patch_and_install_gsp() {
    echo ">>> Patching GSP..."
    [ -f "$GSP_BACKUP" ] || cp -a "$GSP_580" "$GSP_BACKUP"
    python3 "$PATCHER" "$GSP_BACKUP" "$PAYLOAD" "$PATCHED_GSP"
    [ -s "$PATCHED_GSP" ] || die "Patched GSP was not created."
    cp -f "$PATCHED_GSP" "$GSP_580"
    sync
    GSP_REPLACED=1
}

verify_stage1_gpu() {
    local gpu="$1"
    local res="/sys/bus/pci/devices/$gpu/resource0"

    python3 - "$gpu" "$res" <<'PYEOF'
import mmap
import os
import struct
import sys

gpu, path = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDONLY)
bar = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)

def read32(offset):
    return struct.unpack_from("<I", bar, offset)[0]

strap = read32(0x009A0204)
lmr   = read32(0x00100CE0)
plm   = read32(0x00823804)
wpr2  = read32(0x001FA824)
sec2  = read32(0x00840040)

print(
    f"{gpu}: STRAP=0x{strap:08X} LMR=0x{lmr:08X} "
    f"PLM=0x{plm:08X} WPR2=0x{wpr2:08X} SEC2=0x{sec2:08X}"
)

bar.close()
os.close(fd)

if plm != 0xFFFFFFFF:
    raise SystemExit(1)
PYEOF
}

compute_unlock_gpu() {
    local gpu="$1"
    local res="/sys/bus/pci/devices/$gpu/resource0"

    python3 - "$gpu" "$res" <<'PYEOF'
import mmap
import os
import struct
import sys

gpu, path = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR)
bar = mmap.mmap(fd, 0x1000000, access=mmap.ACCESS_WRITE)

def read32(offset):
    return struct.unpack_from("<I", bar, offset)[0]

def write32(offset, value):
    struct.pack_into("<I", bar, offset, value & 0xFFFFFFFF)

plm = read32(0x00823804)
if plm != 0xFFFFFFFF:
    raise RuntimeError(f"{gpu}: PLM is not unlocked: 0x{plm:08X}")

write32(0x0082381C, 0x88888888)
write32(0x00823820, 0x00000008)

ss0 = read32(0x0082381C)
ss1 = read32(0x00823820)

print(f"{gpu}: SS0=0x{ss0:08X} SS1=0x{ss1:08X}")

bar.close()
os.close(fd)

if ss0 != 0x88888888 or ss1 != 0x00000008:
    raise SystemExit(1)
PYEOF
}

stop_gpu_users
unload_nvidia
build_payload
patch_and_install_gsp

echo ">>> Loading patched GSP across all eligible GPUs..."
dmesg -C || true
modprobe nvidia
sleep 8

echo ""
echo "=== Stage 1 verification ==="
stage1_fail=0
for gpu in "${GPUS[@]}"; do
    if ! verify_stage1_gpu "$gpu"; then
        echo "FAILED: PLM did not unlock on $gpu"
        stage1_fail=1
    fi
done

restore_gsp

[ "$stage1_fail" -eq 0 ] ||
    die "Stage 1 failed on one or more GPUs. Compute unlock was not attempted."

echo ""
echo "=== Stage 1 succeeded on every eligible GPU ==="

# Preserve the same ordering as the proven one-GPU pipeline:
# patched driver loaded -> FLR -> unload -> FLR -> SS0/SS1 writes
flr_all 1
unload_nvidia
flr_all 2

echo ">>> Applying SS0/SS1 compute unlock to every eligible GPU..."
unlock_fail=0
for gpu in "${GPUS[@]}"; do
    if ! compute_unlock_gpu "$gpu"; then
        echo "FAILED: Compute unlock did not stick on $gpu"
        unlock_fail=1
    fi
done

[ "$unlock_fail" -eq 0 ] ||
    die "Compute unlock failed on one or more GPUs."

echo ">>> Reloading stock NVIDIA driver..."
modprobe nvidia
sleep 8

echo ""
echo "=== Final GPU list ==="
nvidia-smi -L

final_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
if [ "$final_count" -ne "${#GPUS[@]}" ]; then
    die "Detected ${#GPUS[@]} eligible GPUs initially, but nvidia-smi now sees $final_count."
fi

echo ""
echo "=== Final NVIDIA status ==="
nvidia-smi

echo ""
echo "================================================"
echo "SUCCESS: compute unlock applied to ${#GPUS[@]} GPU(s)"
echo "No STRAP or LMR VRAM-capacity writes were used."
echo "================================================"

trap - EXIT INT TERM
