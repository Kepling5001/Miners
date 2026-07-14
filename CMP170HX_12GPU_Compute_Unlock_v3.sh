#!/bin/bash
set -Eeuo pipefail

echo "========================================================"
echo "=== CMP 170HX — Compute-Only All-GPU Unlock v3      ==="
echo "=== Audited 12-GPU coordinated test build           ==="
echo "========================================================"

WORKDIR="${WORKDIR:-/home/user/isolated}"
DRIVER_VERSION="${DRIVER_VERSION:-580.159.04}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-12}"
GSP="${GSP:-/lib/firmware/nvidia/${DRIVER_VERSION}/gsp_tu10x.bin}"
PATCHER="${WORKDIR}/patch_gsp.py"
PAYLOAD="${WORKDIR}/payload_compute_only_v3.bin"
PATCHED_GSP="${WORKDIR}/gsp_patched_compute_only_v3.bin"
RUN_GSP_BACKUP="${WORKDIR}/gsp_tu10x.${DRIVER_VERSION}.pre_unlock.bin"
STATE_FILE="${WORKDIR}/post_reset_state_v3.tsv"
LOG_FILE="${WORKDIR}/compute_unlock_v3_$(date +%Y%m%d_%H%M%S).log"

# Safety/test controls.
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
SKIP_CUDA_SMOKE="${SKIP_CUDA_SMOKE:-0}"

# Timings can be overridden from the command line if needed.
PER_GPU_RESET_WAIT="${PER_GPU_RESET_WAIT:-3}"
POST_PASS_WAIT="${POST_PASS_WAIT:-20}"
FINAL_INIT_TIMEOUT="${FINAL_INIT_TIMEOUT:-180}"

GSP_REPLACED=0
RESET_METHODS_FORCED=0
LOGGING_STARTED=0
declare -a GPUS=()

log() {
    echo "[$(date +'%H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

restore_gsp() {
    if [ "$GSP_REPLACED" -eq 1 ] && [ -f "$RUN_GSP_BACKUP" ]; then
        log "Restoring stock GSP from this run's backup..."
        cp -f "$RUN_GSP_BACKUP" "$GSP" || true
        sync
        GSP_REPLACED=0
    fi
}

restore_reset_methods() {
    [ "$RESET_METHODS_FORCED" -eq 1 ] || return 0

    log "Restoring default PCI reset-method order..."
    local gpu method_file
    for gpu in "${GPUS[@]}"; do
        method_file="/sys/bus/pci/devices/$gpu/reset_method"
        [ -e "$method_file" ] || continue
        echo default > "$method_file" 2>/dev/null || true
    done
    RESET_METHODS_FORCED=0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    restore_gsp || true
    restore_reset_methods || true

    if [ "$rc" -ne 0 ]; then
        echo
        echo "Pipeline stopped with error $rc."
        echo "The stock GSP and default reset-method order were restored where possible."
        echo "Do not immediately rerun after a GPU/GSP failure."
        echo "A reboot or full AC power cycle may be required."
    fi

    exit "$rc"
}
trap cleanup EXIT INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

start_logging() {
    [ "$LOGGING_STARTED" -eq 0 ] || return 0
    touch "$LOG_FILE" || die "Cannot create log file: $LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    LOGGING_STARTED=1
    log "Log file: $LOG_FILE"
}

check_cmpunlocker_watchdog() {
    local enabled_state="not-found"
    local active_state="inactive"

    enabled_state="$(systemctl is-enabled cmpunlocker.service 2>/dev/null || true)"
    active_state="$(systemctl is-active cmpunlocker.service 2>/dev/null || true)"

    if [ "$active_state" = "active" ] ||
       pgrep -f '/opt/cmpunlocker/daemon/watchdog.py' >/dev/null 2>&1; then
        die "cmpunlocker watchdog/service is running. Stop and mask it before testing."
    fi

    case "$enabled_state" in
        enabled|enabled-runtime|indirect)
            die "cmpunlocker.service is enabled for boot. Disable or mask it before testing."
            ;;
    esac

    echo "cmpunlocker service state: enabled=$enabled_state active=$active_state"
}

verify_driver_version() {
    local installed
    installed="$(modinfo -F version nvidia 2>/dev/null || true)"
    [ "$installed" = "$DRIVER_VERSION" ] ||
        die "Expected NVIDIA driver $DRIVER_VERSION, found '${installed:-unknown}'."
}

verify_known_stock_gsp() {
    local active_hash stock_source="" stock_hash

    # Prefer the most deliberate recovery copies first.
    for candidate in \
        "/root/gsp_tu10x.bin.${DRIVER_VERSION}.original" \
        "${GSP}.cmpunlocker.bak" \
        "${GSP}.backup"; do
        if [ -f "$candidate" ]; then
            stock_source="$candidate"
            break
        fi
    done

    [ -n "$stock_source" ] ||
        die "No known stock GSP backup found. Refusing to patch without a recovery copy."

    active_hash="$(sha256sum "$GSP" | awk '{print $1}')"
    stock_hash="$(sha256sum "$stock_source" | awk '{print $1}')"

    echo "Active GSP SHA-256: $active_hash"
    echo "Stock reference: $stock_source"
    echo "Stock SHA-256:  $stock_hash"

    [ "$active_hash" = "$stock_hash" ] ||
        die "Active GSP does not match the selected stock backup. Restore stock firmware first."
}

assert_no_gpu_holders() {
    local dev pids
    local found=0

    for dev in /dev/nvidia*; do
        [ -e "$dev" ] || continue
        pids="$(fuser "$dev" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | xargs || true)"
        if [ -n "$pids" ]; then
            echo "GPU device still in use: $dev -> $pids"
            found=1
        fi
    done

    [ "$found" -eq 0 ] ||
        die "One or more processes still hold NVIDIA device files."
}

detect_gpus() {
    mapfile -t GPUS < <(
        lspci -Dnn |
        awk 'tolower($0) ~ /10de:(20b0|20c2)/ {print tolower($1)}'
    )

    [ "${#GPUS[@]}" -gt 0 ] || die "No eligible GA100 GPUs found."

    if [ "$EXPECTED_GPU_COUNT" -gt 0 ] &&
       [ "${#GPUS[@]}" -ne "$EXPECTED_GPU_COUNT" ]; then
        die "Expected ${EXPECTED_GPU_COUNT} eligible GPUs, found ${#GPUS[@]}."
    fi

    echo "Detected ${#GPUS[@]} eligible GPU(s):"
    printf '  %s\n' "${GPUS[@]}"
    echo
}

preflight() {
    [ "$(id -u)" -eq 0 ] || die "Run this script as root."

    for cmd in python3 lspci nvidia-smi modprobe modinfo fuser timeout sort comm awk sed grep \
               sha256sum cmp dmesg tee pgrep pkill killall systemctl readlink lsmod; do
        require_command "$cmd"
    done

    [ -d "$WORKDIR" ] || die "Missing work directory: $WORKDIR"
    [ -f "$PATCHER" ] || die "Missing patcher: $PATCHER"
    [ -f "$GSP" ] || die "Missing exact GSP firmware: $GSP"

    check_cmpunlocker_watchdog
    verify_driver_version
    verify_known_stock_gsp
    python3 -m py_compile "$PATCHER"

    local gpu devdir
    for gpu in "${GPUS[@]}"; do
        devdir="/sys/bus/pci/devices/$gpu"
        [ -e "$devdir/resource0" ] || die "Missing BAR0 resource for $gpu"
        [ -e "$devdir/reset" ] || die "Missing reset interface for $gpu"
        [ -e "$devdir/reset_method" ] || die "Missing reset_method interface for $gpu"

        if ! grep -qw flr "$devdir/reset_method"; then
            die "$gpu does not advertise FLR support: $(cat "$devdir/reset_method")"
        fi
    done

    echo "Reset methods before override:"
    for gpu in "${GPUS[@]}"; do
        printf "  %s: " "$gpu"
        cat "/sys/bus/pci/devices/$gpu/reset_method"
    done
    echo
}

stop_gpu_users() {
    log "Stopping miners, display services, and NVIDIA users..."

    command -v miner >/dev/null 2>&1 && miner stop || true
    pkill -9 rigel 2>/dev/null || true
    pkill -9 peakminer 2>/dev/null || true
    pkill -9 keryx-miner 2>/dev/null || true

    systemctl stop nvidia-persistenced 2>/dev/null || true
    systemctl stop gdm3 sddm lightdm display-manager 2>/dev/null || true
    killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true

    local mypid=$$
    local dev pids pid
    for dev in /dev/nvidia*; do
        [ -e "$dev" ] || continue
        pids="$(
            fuser "$dev" 2>/dev/null |
            tr ' ' '\n' |
            grep -E '^[0-9]+$' |
            grep -v "^${mypid}$" |
            xargs || true
        )"

        for pid in $pids; do
            log "Killing PID $pid holding $dev"
            kill -9 "$pid" 2>/dev/null || true
        done
    done

    sleep 5
}

unbind_all_nvidia() {
    log "Unbinding eligible GPUs from the NVIDIA driver..."

    local gpu driver
    for gpu in "${GPUS[@]}"; do
        driver=""

        if [ -L "/sys/bus/pci/devices/$gpu/driver" ]; then
            driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$gpu/driver")")"
        fi

        case "$driver" in
            nvidia)
                echo "$gpu" > /sys/bus/pci/drivers/nvidia/unbind ||
                    die "Failed to unbind $gpu from NVIDIA"
                sleep 1
                if [ -L "/sys/bus/pci/devices/$gpu/driver" ] &&
                   [ "$(basename "$(readlink -f "/sys/bus/pci/devices/$gpu/driver")")" = "nvidia" ]; then
                    die "$gpu still reports NVIDIA as its bound driver after unbind."
                fi
                ;;
            "")
                log "$gpu is already unbound"
                ;;
            *)
                die "$gpu is unexpectedly bound to driver '$driver'"
                ;;
        esac
    done

    sleep 5
}

unload_nvidia_safely() {
    log "Gracefully unloading NVIDIA modules; forced rmmod is disabled..."

    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia_drm 2>/dev/null || true
    modprobe -r nvidia_modeset 2>/dev/null || true
    modprobe -r nvidia_peermem 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true

    if lsmod | grep -q '^nvidia'; then
        echo
        echo "NVIDIA modules still loaded:"
        lsmod | grep '^nvidia' || true
        echo
        echo "GPU device holders:"
        fuser -v /dev/nvidia* 2>/dev/null || true
        die "NVIDIA modules would not unload gracefully. No forced rmmod was attempted."
    fi

    log "All NVIDIA modules unloaded cleanly."
}

force_flr_only() {
    log "Forcing FLR-only reset method on every eligible GPU..."

    local gpu method_file current
    for gpu in "${GPUS[@]}"; do
        method_file="/sys/bus/pci/devices/$gpu/reset_method"
        echo flr > "$method_file" ||
            die "Failed to force FLR for $gpu"

        current="$(cat "$method_file")"
        [ "$current" = "flr" ] ||
            die "$gpu reset method did not become FLR-only: $current"

        echo "  $gpu: $current"
    done

    RESET_METHODS_FORCED=1
}

flr_pass_forward() {
    local pass="$1"
    log "FLR pass $pass, forward order..."

    local gpu
    for gpu in "${GPUS[@]}"; do
        echo "  Resetting $gpu using $(cat "/sys/bus/pci/devices/$gpu/reset_method")"
        echo 1 > "/sys/bus/pci/devices/$gpu/reset" ||
            die "FLR failed on $gpu during pass $pass"
        sleep "$PER_GPU_RESET_WAIT"
    done

    log "Waiting ${POST_PASS_WAIT}s after pass $pass..."
    sleep "$POST_PASS_WAIT"
}

flr_pass_reverse() {
    local pass="$1"
    log "FLR pass $pass, reverse order..."

    local i gpu
    for ((i=${#GPUS[@]}-1; i>=0; i--)); do
        gpu="${GPUS[$i]}"
        echo "  Resetting $gpu using $(cat "/sys/bus/pci/devices/$gpu/reset_method")"
        echo 1 > "/sys/bus/pci/devices/$gpu/reset" ||
            die "FLR failed on $gpu during pass $pass"
        sleep "$PER_GPU_RESET_WAIT"
    done

    log "Waiting ${POST_PASS_WAIT}s after pass $pass..."
    sleep "$POST_PASS_WAIT"
}

build_payload() {
    log "Building compute-only payload..."
    cd "$WORKDIR"

    python3 - "$PAYLOAD" <<'PYEOF'
import struct
import sys

output = sys.argv[1]
PAYLOAD_SIZE = 0xF800
DMA_TARGET = 0x0800
CANARY = 0xFACEB13D
CANARY_ADDR = 0x6340

# Compute-only Stage 1. No VRAM STRAP or LMR writes.
WRITES = [
    (0x00823804, 0xFFFFFFFF),  # PLM unlock
]

payload = bytearray(PAYLOAD_SIZE)

def w32(dmem: int, value: int) -> None:
    offset = dmem - DMA_TARGET
    if not (0 <= offset <= len(payload) - 4):
        raise ValueError(f"DMEM address outside payload: 0x{dmem:X}")
    struct.pack_into("<I", payload, offset, value & 0xFFFFFFFF)

w32(CANARY_ADDR, CANARY)

address = 0xFF48
for register, value in WRITES:
    w32(address + 0x00, CANARY_ADDR)
    w32(address + 0x04, 0)
    w32(address + 0x08, value)
    w32(address + 0x0C, register)
    w32(address + 0x10, CANARY)
    w32(address + 0x14, 0x000010B9)
    address += 0x18

w32(address + 0x00, 0)
w32(address + 0x04, 0)
w32(address + 0x08, 0)
w32(address + 0x0C, 0)
w32(address + 0x10, CANARY)
w32(address + 0x14, 0x0000810D)

with open(output, "wb") as file:
    file.write(payload)

print(f"Built {len(payload)} bytes: {output}")
PYEOF
}

patch_and_install_gsp() {
    log "Creating run-specific GSP backup and patching..."

    cp -a "$GSP" "$RUN_GSP_BACKUP"
    sync

    python3 "$PATCHER" "$RUN_GSP_BACKUP" "$PAYLOAD" "$PATCHED_GSP"
    [ -s "$PATCHED_GSP" ] || die "Patched GSP was not created."

    python3 - "$PATCHED_GSP" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
if len(data) < 4 or data[:4] != b"\x7fELF":
    raise SystemExit("Patched GSP is not an ELF file")
PYEOF

    cmp -s "$RUN_GSP_BACKUP" "$PATCHED_GSP" &&
        die "Patched GSP is identical to stock input."

    cp -f "$PATCHED_GSP" "$GSP"
    sync
    GSP_REPLACED=1
}

verify_stage1_gpu() {
    local gpu="$1"
    local resource="/sys/bus/pci/devices/$gpu/resource0"

    python3 - "$gpu" "$resource" <<'PYEOF'
import mmap
import os
import struct
import sys

gpu, path = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDONLY)
bar = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)

def read32(offset: int) -> int:
    return struct.unpack_from("<I", bar, offset)[0]

strap = read32(0x009A0204)
lmr = read32(0x00100CE0)
plm = read32(0x00823804)
wpr2_lo = read32(0x001FA824)
wpr2_hi = read32(0x001FA828)
sec2 = read32(0x00840040)

print(
    f"{gpu}: STRAP=0x{strap:08X} LMR=0x{lmr:08X} "
    f"PLM=0x{plm:08X} WPR2_LO=0x{wpr2_lo:08X} "
    f"WPR2_HI=0x{wpr2_hi:08X} SEC2=0x{sec2:08X}"
)

bar.close()
os.close(fd)

if plm != 0xFFFFFFFF:
    raise SystemExit(1)
PYEOF
}

collect_post_reset_state() {
    : > "$STATE_FILE"

    local gpu resource
    for gpu in "${GPUS[@]}"; do
        resource="/sys/bus/pci/devices/$gpu/resource0"

        python3 - "$gpu" "$resource" >> "$STATE_FILE" <<'PYEOF'
import mmap
import os
import struct
import sys

gpu, path = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDONLY)
bar = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)

def read32(offset: int) -> int:
    return struct.unpack_from("<I", bar, offset)[0]

plm = read32(0x00823804)
wpr2_lo = read32(0x001FA824)
wpr2_hi = read32(0x001FA828)
sec2 = read32(0x00840040)
gsp = read32(0x00110040)

print(
    f"{gpu}\t{plm:08X}\t{wpr2_lo:08X}\t"
    f"{wpr2_hi:08X}\t{sec2:08X}\t{gsp:08X}"
)

bar.close()
os.close(fd)
PYEOF
    done
}

print_post_reset_state() {
    echo "BDF              PLM       WPR2_LO  WPR2_HI  SEC2      GSP"
    awk -F '\t' '{
        printf "%-16s 0x%s 0x%s 0x%s 0x%s 0x%s\n",
            $1, $2, $3, $4, $5, $6
    }' "$STATE_FILE"
}

validate_post_reset_state() {
    log "Checking PLM and WPR2 state before SS0/SS1 writes..."
    collect_post_reset_state
    print_post_reset_state

    local bad_plm
    bad_plm="$(awk -F '\t' '$2 != "FFFFFFFF" {print $1}' "$STATE_FILE")"
    if [ -n "$bad_plm" ]; then
        echo "PLM was lost on:"
        echo "$bad_plm"
        return 1
    fi

    # A successful secure teardown has previously been identified by this
    # empty WPR2 lower-bound value. Retry any outlier once with FLR only.
    local expected_wpr2="1FFFFE00"
    mapfile -t bad_wpr2 < <(
        awk -F '\t' -v expected="$expected_wpr2" \
            '$3 != expected {print $1}' "$STATE_FILE"
    )

    if [ "${#bad_wpr2[@]}" -gt 0 ]; then
        echo
        echo "WPR2 did not reach the expected teardown state on:"
        printf '  %s\n' "${bad_wpr2[@]}"
        echo "Retrying one targeted FLR on each outlier..."

        local gpu
        for gpu in "${bad_wpr2[@]}"; do
            echo flr > "/sys/bus/pci/devices/$gpu/reset_method"
            echo 1 > "/sys/bus/pci/devices/$gpu/reset" ||
                die "Targeted FLR failed on $gpu"
            sleep 10
        done

        sleep "$POST_PASS_WAIT"
        collect_post_reset_state
        print_post_reset_state

        bad_plm="$(awk -F '\t' '$2 != "FFFFFFFF" {print $1}' "$STATE_FILE")"
        [ -z "$bad_plm" ] || {
            echo "PLM was lost after targeted retry on:"
            echo "$bad_plm"
            return 1
        }

        mapfile -t bad_wpr2 < <(
            awk -F '\t' -v expected="$expected_wpr2" \
                '$3 != expected {print $1}' "$STATE_FILE"
        )

        if [ "${#bad_wpr2[@]}" -gt 0 ]; then
            echo "WPR2 still failed to tear down on:"
            printf '  %s\n' "${bad_wpr2[@]}"
            return 1
        fi
    fi

    log "All GPUs have PLM unlocked and WPR2 in teardown state."
}

compute_unlock_gpu() {
    local gpu="$1"
    local resource="/sys/bus/pci/devices/$gpu/resource0"

    python3 - "$gpu" "$resource" <<'PYEOF'
import mmap
import os
import struct
import sys

gpu, path = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR)
bar = mmap.mmap(fd, 0x1000000, access=mmap.ACCESS_WRITE)

def read32(offset: int) -> int:
    return struct.unpack_from("<I", bar, offset)[0]

def write32(offset: int, value: int) -> None:
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

normalize_bdfs() {
    sed -E \
        -e 's/^00000000:/0000:/' \
        -e 's/^0000:([0-9A-Fa-f]{2}):/0000:\L\1:/' |
    tr 'A-F' 'a-f'
}

wait_for_all_gpus() {
    log "Waiting up to ${FINAL_INIT_TIMEOUT}s for all GPUs to initialize..."

    local expected_count="${#GPUS[@]}"
    local elapsed=0
    local visible_count=0
    local output="${WORKDIR}/visible_bdfs.txt"

    while [ "$elapsed" -lt "$FINAL_INIT_TIMEOUT" ]; do
        : > "$output"

        if timeout 12 nvidia-smi \
            --query-gpu=pci.bus_id \
            --format=csv,noheader,nounits \
            2>/dev/null |
            normalize_bdfs |
            sort -u > "$output"; then
            visible_count="$(grep -c . "$output" || true)"
        else
            visible_count="$(grep -c . "$output" || true)"
        fi

        echo "  ${elapsed}s: ${visible_count}/${expected_count} GPUs initialized"

        if [ "$visible_count" -eq "$expected_count" ]; then
            local missing
            missing="$(
                comm -23 \
                    <(printf '%s\n' "${GPUS[@]}" | sort -u) \
                    "$output"
            )"

            if [ -z "$missing" ]; then
                return 0
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo
    echo "Visible GPU BDFs:"
    cat "$output" || true
    echo
    echo "Missing expected BDFs:"
    comm -23 \
        <(printf '%s\n' "${GPUS[@]}" | sort -u) \
        "$output" || true

    return 1
}

cuda_smoke_test() {
    log "Running per-GPU CUDA smoke test..."

    if python3 -c 'import torch' >/dev/null 2>&1; then
        python3 - "${#GPUS[@]}" <<'PYEOF'
import sys
import torch

expected = int(sys.argv[1])
count = torch.cuda.device_count()
print(f"PyTorch sees {count}/{expected} CUDA devices")

if count != expected:
    raise SystemExit(1)

failed = False

for index in range(count):
    try:
        with torch.cuda.device(index):
            a = torch.ones((1024, 1024), device=f"cuda:{index}", dtype=torch.float32)
            b = torch.ones((1024, 1024), device=f"cuda:{index}", dtype=torch.float32)
            c = a @ b
            torch.cuda.synchronize(index)
            value = float(c[0, 0].item())

        if value != 1024.0:
            raise RuntimeError(f"unexpected result {value}")

        print(f"GPU {index}: CUDA allocation + kernel OK")
    except Exception as error:
        failed = True
        print(f"GPU {index}: FAILED — {error}")

if failed:
    raise SystemExit(1)
PYEOF
        return
    fi

    if command -v nvcc >/dev/null 2>&1; then
        cat > "${WORKDIR}/cuda_smoke_v2.cu" <<'CUDAOF'
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

__global__ void fill_kernel(float *data, int count) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < count) {
        data[index] = static_cast<float>(index);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        std::fprintf(stderr, "Usage: %s <expected_gpu_count>\n", argv[0]);
        return 2;
    }

    int expected = std::atoi(argv[1]);
    int count = 0;
    cudaError_t status = cudaGetDeviceCount(&count);

    if (status != cudaSuccess) {
        std::fprintf(stderr, "cudaGetDeviceCount failed: %s\n",
                     cudaGetErrorString(status));
        return 1;
    }

    std::printf("CUDA sees %d/%d devices\n", count, expected);
    if (count != expected) {
        return 1;
    }

    bool failed = false;
    constexpr int elements = 1024 * 1024;
    constexpr size_t bytes = elements * sizeof(float);

    for (int device = 0; device < count; ++device) {
        status = cudaSetDevice(device);
        if (status != cudaSuccess) {
            std::printf("GPU %d: cudaSetDevice FAILED: %s\n",
                        device, cudaGetErrorString(status));
            failed = true;
            continue;
        }

        float *buffer = nullptr;
        status = cudaMalloc(&buffer, bytes);
        if (status == cudaSuccess) {
            fill_kernel<<<(elements + 255) / 256, 256>>>(buffer, elements);
            status = cudaGetLastError();
        }
        if (status == cudaSuccess) {
            status = cudaDeviceSynchronize();
        }

        if (status == cudaSuccess) {
            std::printf("GPU %d: CUDA allocation + kernel OK\n", device);
        } else {
            std::printf("GPU %d: FAILED: %s\n",
                        device, cudaGetErrorString(status));
            failed = true;
        }

        if (buffer != nullptr) {
            cudaFree(buffer);
        }
    }

    return failed ? 1 : 0;
}
CUDAOF

        nvcc -O2 -arch=sm_80 \
            "${WORKDIR}/cuda_smoke_v2.cu" \
            -o "${WORKDIR}/cuda_smoke_v2"

        "${WORKDIR}/cuda_smoke_v2" "${#GPUS[@]}"
        return
    fi

    if [ "$SKIP_CUDA_SMOKE" = "1" ]; then
        echo "WARNING: CUDA smoke test skipped by SKIP_CUDA_SMOKE=1."
        return 0
    fi

    die "Neither PyTorch nor nvcc is installed; CUDA smoke validation is required."
}

main() {
    detect_gpus
    preflight
    start_logging

    if [ "$PREFLIGHT_ONLY" = "1" ]; then
        log "PREFLIGHT_ONLY=1: checks passed; no GPU or firmware changes were made."
        trap - EXIT INT TERM
        exit 0
    fi

    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "WARNING: A graphical session appears active."
        echo "Stopping it may kill this terminal."
        read -r -p "Type CONTINUE to proceed: " answer
        [ "$answer" = "CONTINUE" ] || die "Cancelled."
    fi

    echo "This will stop every NVIDIA workload and process all eligible GPUs."
    echo "Forced rmmod is disabled. The script aborts instead of forcing a busy module."
    echo "Expected GPU count: $EXPECTED_GPU_COUNT"
    read -r -p "Type UNLOCK-ALL-V3 to continue: " answer
    [ "$answer" = "UNLOCK-ALL-V3" ] || die "Cancelled."

    stop_gpu_users
    assert_no_gpu_holders

    # Clean initial stock-driver removal.
    unbind_all_nvidia
    unload_nvidia_safely

    build_payload
    patch_and_install_gsp

    log "Loading patched GSP across all eligible GPUs..."
    dmesg -C || true
    modprobe nvidia
    sleep 20

    echo
    echo "=== Stage 1 verification ==="
    local stage1_fail=0
    local gpu

    for gpu in "${GPUS[@]}"; do
        if ! verify_stage1_gpu "$gpu"; then
            echo "FAILED: PLM did not unlock on $gpu"
            stage1_fail=1
        fi
    done

    restore_gsp

    [ "$stage1_fail" -eq 0 ] ||
        die "Stage 1 failed on one or more GPUs. Compute unlock was not attempted."

    echo
    echo "=== Stage 1 succeeded on every eligible GPU ==="

    # 0d previously advertised "acpi flr bus" and selected ACPI first.
    # Force all devices to use the same FLR path.
    force_flr_only

    # Preserve the successful one-GPU ordering:
    # patched driver loaded -> first FLR -> unload -> second FLR -> SS writes.
    flr_pass_forward 1

    # Re-check because HiveOS/watchdogs may restart GPU users during the long run.
    stop_gpu_users
    assert_no_gpu_holders

    # Explicit unbind avoids the rmmod -f kernel hang seen on the 12-GPU rig.
    unbind_all_nvidia
    unload_nvidia_safely

    # Reverse order prevents the same last card receiving the shortest settle time.
    flr_pass_reverse 2

    validate_post_reset_state ||
        die "Post-reset PLM/WPR2 validation failed. Stock driver was not loaded."

    log "Applying SS0/SS1 compute unlock to every eligible GPU..."
    local unlock_fail=0

    for gpu in "${GPUS[@]}"; do
        if ! compute_unlock_gpu "$gpu"; then
            echo "FAILED: Compute unlock did not stick on $gpu"
            unlock_fail=1
        fi
        sleep 1
    done

    [ "$unlock_fail" -eq 0 ] ||
        die "Compute unlock failed on one or more GPUs."

    sleep 10

    # Clear expected patched-GSP errors so final-driver errors are easy to see.
    dmesg -C || true

    log "Loading stock NVIDIA driver..."
    modprobe nvidia
    sleep 15

    if ! wait_for_all_gpus; then
        echo
        echo "=== Final NVIDIA/GSP errors ==="
        dmesg | grep -iE \
            'NVRM|Xid|RmInitAdapter|unexpected WPR2|reset required|GSP' |
            tail -200 || true
        die "Not every GPU initialized under the stock NVIDIA driver."
    fi

    log "All expected GPUs initialized; loading NVIDIA UVM..."
    modprobe nvidia_uvm
    sleep 5

    echo
    echo "=== Final GPU list ==="
    nvidia-smi -L

    cuda_smoke_test ||
        die "One or more visible GPUs failed the CUDA smoke test."

    echo
    echo "=== Final NVIDIA status ==="
    nvidia-smi

    echo
    echo "=== Final driver errors, if any ==="
    dmesg | grep -iE \
        'NVRM|Xid|RmInitAdapter|unexpected WPR2|reset required|GSP' |
        tail -100 || true

    restore_reset_methods

    echo
    echo "========================================================"
    echo "SUCCESS: compute unlock v3 validated on ${#GPUS[@]} GPU(s)"
    echo "No STRAP or LMR VRAM-capacity writes were used."
    echo "All GPUs passed NVIDIA initialization and CUDA validation."
    echo "========================================================"

    trap - EXIT INT TERM
}

main "$@"
