#!/bin/bash

echo "========================================"
echo "=== CMP 170HX — Full Pipeline        ==="
echo "=== Stage 1 + FLR + Unload + Unlock  ==="
echo "========================================"

# --- Find GPU once, at top ---
PCI=$(lspci -nn | grep -iE "10de:20b0|10de:20c2" | head -1 | awk '{print $1}')
if [ -z "$PCI" ]; then
    echo "ERROR: No GA100 GPU found (10de:20b0 or 10de:20c2)"
    exit 1
fi
PCI_FULL="0000:${PCI}"
RES="/sys/bus/pci/devices/${PCI_FULL}/resource0"
echo "GPU at ${PCI_FULL}"
echo ""

# --- Warn if running inside X/Wayland ---
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    echo "WARNING: You appear to be in a graphical session."
    echo "Killing Xorg/Wayland will kill this terminal."
    echo "Run this from a TTY (Ctrl+Alt+F3) or SSH instead."
    echo ""
    read -p "Press Enter to continue anyway, or Ctrl+C to abort..."
fi

# ============================================
# STAGE 1: ROP Payload via GSP
# ============================================

echo ">>> Stage 1: Preparing environment..."

# Stop GUI
sudo systemctl stop gdm3 sddm lightdm display-manager 2>/dev/null || true
sudo killall -9 Xorg nvidia-persistenced 2>/dev/null || true
sleep 2

# Unload modules
sudo modprobe -r nvidia-uvm 2>/dev/null || true
sudo modprobe -r nvidia_drm 2>/dev/null || true
sudo modprobe -r nvidia_modeset 2>/dev/null || true
sudo modprobe -r nvidia 2>/dev/null || true
sleep 2

# Build payload — 3 writes, NO WPR2 teardown
cd /home/$SUDO_USER/isolated

python3 - << 'PYEOF'
import struct

PAYLOAD_SIZE = 0xF800
DMA_TARGET = 0x0800
CANARY = 0xFACEB13D
CANARY_ADDR = 0x6340

# 3 writes: STRAP + LMR + PLM (NO WPR2 teardown)
WRITES = [
    (0x009A0204, 0x02779000),  # 1. STRAP 64GB
    (0x00100CE0, 0x0000020B),  # 2. LMR 64GB
    (0x00823804, 0xFFFFFFFF),  # 3. PLM unlock
]

def build():
    payload = bytearray(PAYLOAD_SIZE)
    def w32(dmem, val):
        off = dmem - DMA_TARGET
        if 0 <= off <= len(payload) - 4:
            struct.pack_into('<I', payload, off, val & 0xFFFFFFFF)

    w32(CANARY_ADDR, CANARY)

    a = 0xFF48
    for addr, val in WRITES:
        w32(a + 0x00, CANARY_ADDR)  # r0
        w32(a + 0x04, 0x00000000)   # r1
        w32(a + 0x08, val)           # r2
        w32(a + 0x0C, addr)          # r3
        w32(a + 0x10, CANARY)        # saved_reg = canary
        w32(a + 0x14, 0x000010b9)    # return to 0x10b9 gadget
        a += 0x18

    # TAIL: dynamic offset based on actual number of writes
    TAIL = a
    w32(TAIL + 0x00, 0x00000000)   # r0 = 0
    w32(TAIL + 0x04, 0x00000000)   # r1
    w32(TAIL + 0x08, 0x00000000)   # r2
    w32(TAIL + 0x0C, 0x00000000)   # r3
    w32(TAIL + 0x10, CANARY)        # saved_reg = CANARY
    w32(TAIL + 0x14, 0x0000810d)   # pc -> main() -> secure_teardown()

    return bytes(payload)

p = build()
with open("payload_flr_final.bin", "wb") as f:
    f.write(p)
print(f"Built: {len(p)} bytes")
PYEOF

# Patch GSP
GSP_580="/lib/firmware/nvidia/580.159.04/gsp_tu10x.bin"

if [ ! -f "$GSP_580" ]; then
    echo "ERROR: 580 GSP not found."
    exit 1
fi

if [ ! -f "${GSP_580}.backup" ]; then
    sudo cp "$GSP_580" "${GSP_580}.backup"
fi

python3 patch_gsp.py "${GSP_580}.backup" payload_flr_final.bin gsp_patched_flr_final.bin
sudo cp gsp_patched_flr_final.bin "$GSP_580"

# Stage 1: Load patched GSP, run payload
sudo dmesg -C
sudo modprobe nvidia
sleep 5

echo ""
echo "=== nvidia-smi (Stage 1 — expected fail) ==="
nvidia-smi 2>/dev/null || echo "failed (expected for Stage 1)"

echo ""
echo "=== Stage 1 Registers ==="
sudo python3 - "$RES" <<'PY'
import mmap, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bar = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
def r(off): return struct.unpack_from("<I", bar, off)[0]

print(f"STRAP   0x9A0204 = 0x{r(0x009A0204):08X}")
print(f"LMR     0x100CE0 = 0x{r(0x00100CE0):08X}")
print(f"PLM     0x823804 = 0x{r(0x00823804):08X}")
print(f"WPR2_LO 0x1FA824 = 0x{r(0x001FA824):08X}")
print(f"WPR2_HI 0x1FA828 = 0x{r(0x001FA828):08X}")
print(f"SS0     0x82381C = 0x{r(0x0082381C):08X}")
print(f"SS1     0x823820 = 0x{r(0x00823820):08X}")
print(f"SEC2    0x840040 = 0x{r(0x00840040):08X}")
print(f"GSP     0x110040 = 0x{r(0x00110040):08X}")

strap = r(0x009A0204)
lmr = r(0x00100CE0)
plm = r(0x00823804)
wpr2_lo = r(0x001FA824)
sec2 = r(0x00840040)

print("")
if strap == 0x02779000 and lmr == 0x0000020B:
    print("RESULT: UNLOCKED (64GB)")
else:
    print(f"RESULT: strap=0x{strap:08X} lmr=0x{lmr:08X}")

if plm == 0xFFFFFFFF:
    print("PLM: UNLOCKED")
else:
    print(f"PLM: 0x{plm:08X}")

if wpr2_lo == 0x1FFFFE00:
    print("WPR2: TEARDOWN (empty region)")
else:
    print(f"WPR2: active (0x{wpr2_lo:08X})")

if sec2 == 0x00:
    print("SEC2: 0x00 (success)")
else:
    print(f"SEC2: 0x{sec2:08X}")

bar.close(); os.close(fd)
PY

# Restore original GSP
echo ""
echo "Restoring original GSP..."
sudo cp "${GSP_580}.backup" "$GSP_580"
echo "Done."

echo ""
echo "=== DMESG (Stage 1) ==="
sudo dmesg | grep -iE "nvrm|gsp|booter|mailbox|wpr2|0x31|0x65|fail|ready|timeout|sec2|falcon" | tail -30 || true

echo ""
echo "========================================"
echo "STAGE 1 COMPLETE"
echo "========================================"
echo ""

# ============================================
# POST-EXPLOIT: FLR + Unload + FLR + Unlock
# ============================================

# --- Function: FLR Reset ---
flr_reset() {
    echo "=== FLR Reset ==="
    echo "Resetting ${PCI_FULL}..."
    echo 1 | sudo tee /sys/bus/pci/devices/${PCI_FULL}/reset >/dev/null || true
    sleep 3
    echo "FLR complete."
    echo ""
}

# --- Function: Aggressive NVIDIA Unload ---
aggressive_unload() {
    echo "=== Aggressive NVIDIA Unload ==="
    MYPID=$$

    echo "[1] Stopping NVIDIA services..."
    sudo systemctl stop nvidia-persistenced 2>/dev/null || true
    sudo systemctl disable nvidia-persistenced 2>/dev/null || true
    sudo systemctl stop gdm3 sddm lightdm display-manager 2>/dev/null || true
    sudo killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true
    sleep 2

    echo "[2] Killing processes holding GPU devices (excluding PID $MYPID)..."
    for dev in /dev/nvidia* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm*; do
        [ -e "$dev" ] || continue
        PIDS=$(sudo fuser $dev 2>/dev/null | tr ' ' '\n' | grep -v "^${MYPID}$" | xargs)
        if [ -n "$PIDS" ]; then
            echo "  Killing PIDs on $dev: $PIDS"
            for pid in $PIDS; do
                sudo kill -9 "$pid" 2>/dev/null || true
            done
        fi
    done
    sleep 1

    echo "[3] Current NVIDIA modules:"
    lsmod | grep nvidia || echo "  (none)"

    echo "[4] Attempting graceful removal..."
    sudo modprobe -r nvidia-uvm 2>/dev/null || true
    sudo modprobe -r nvidia_drm 2>/dev/null || true
    sudo modprobe -r nvidia_modeset 2>/dev/null || true
    sudo modprobe -r nvidia 2>/dev/null || true

    if lsmod | grep -q nvidia; then
        echo "[5] Graceful failed. Forcing removal..."
        sudo rmmod -f nvidia_uvm 2>/dev/null || true
        sudo rmmod -f nvidia_drm 2>/dev/null || true
        sudo rmmod -f nvidia_modeset 2>/dev/null || true
        sudo rmmod -f nvidia 2>/dev/null || true
    fi

    echo "[6] Final state:"
    if lsmod | grep nvidia; then
        echo "WARNING: Modules still present."
        sudo lsof /dev/nvidia* 2>/dev/null || true
        cat /proc/modules | grep nvidia || true
    else
        echo "SUCCESS: All NVIDIA modules unloaded."
    fi
    echo ""
}

# --- Function: Compute Unlock (from unlc.py) ---
compute_unlock() {
    echo "=== Compute Unlock (SS0/SS1) ==="
    sudo python3 - "$RES" <<'PYEOF'
import mmap, os, struct, sys

fd = os.open(sys.argv[1], os.O_RDWR)
bar = mmap.mmap(fd, 0x1000000, access=mmap.ACCESS_WRITE)

def read(off):
    return struct.unpack_from("<I", bar, off)[0]

def write(off, val):
    struct.pack_into("<I", bar, off, val & 0xFFFFFFFF)

plm = read(0x00823804)
print(f"PLM     0x823804 = 0x{plm:08X}")

if plm != 0xFFFFFFFF:
    print("WARNING: PLM not fully unlocked. Writes may fail.")
    print("Run Stage 1 exploit first.")
else:
    print("PLM: UNLOCKED — writing SS0/SS1")
    write(0x0082381C, 0x88888888)
    write(0x00823820, 0x00000008)

    ss0 = read(0x0082381C)
    ss1 = read(0x00823820)
    print(f"SS0     0x82381C = 0x{ss0:08X}")
    print(f"SS1     0x823820 = 0x{ss1:08X}")

    if ss0 == 0x88888888 and ss1 == 0x00000008:
        print("Compute unlock SUCCESS")
    else:
        print("Compute unlock FAILED — values did not stick")

bar.close()
os.close(fd)
PYEOF
    echo ""
}

echo ">>> Step 1/4: First FLR Reset"
flr_reset

echo ">>> Step 2/4: Aggressive Driver Unload"
aggressive_unload

echo ">>> Step 3/4: Second FLR Reset"
flr_reset

echo ">>> Step 4/4: Compute Unlock"
compute_unlock

echo "========================================"
echo "Reloading driver..."
sudo modprobe nvidia || true
sleep 3

echo ""
echo "=== nvidia-smi ==="
nvidia-smi || echo "nvidia-smi failed"

echo ""
echo "========================================"
echo "FULL PIPELINE COMPLETE"
echo "========================================"
