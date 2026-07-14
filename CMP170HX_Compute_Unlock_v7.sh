#!/bin/bash
set -Eeuo pipefail

echo "========================================================"
echo "=== CMP 170HX — Compute-Only All-GPU Unlock v7      ==="
echo "=== reset-settle and CUDA-readiness recovery      ==="
echo "========================================================"

WORKDIR="${WORKDIR:-/home/user/isolated}"
DRIVER_VERSION="${DRIVER_VERSION:-580.159.04}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-0}"
GSP="${GSP:-/lib/firmware/nvidia/${DRIVER_VERSION}/gsp_tu10x.bin}"
PAYLOAD="${WORKDIR}/payload_compute_only_v7.bin"
PATCHED_GSP="${WORKDIR}/gsp_patched_compute_only_v7.bin"
RUN_GSP_BACKUP="${WORKDIR}/gsp_tu10x.${DRIVER_VERSION}.pre_unlock.bin"
STATE_FILE="${WORKDIR}/post_reset_state_v7.tsv"
LOG_FILE="${WORKDIR}/compute_unlock_v7_$(date +%Y%m%d_%H%M%S).log"

# Safety/test controls.
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
SKIP_CUDA_SMOKE="${SKIP_CUDA_SMOKE:-0}"

# GPU-client drain controls. HiveOS monitoring can briefly respawn nvidia-smi
# or other NVML clients after the first FLR. v4 drains those clients and
# requires a quiet window instead of aborting on the first transient holder.
HOLDER_DRAIN_TIMEOUT="${HOLDER_DRAIN_TIMEOUT:-60}"
HOLDER_QUIET_CHECKS="${HOLDER_QUIET_CHECKS:-3}"

# Timings can be overridden from the command line if needed.
#
# The earlier failures followed reset order:
# - with forward-order pass 2, the last BDF failed to initialize;
# - with reverse-order pass 2, the first BDFs (reset last) lacked CUDA readiness.
#
# v7 gives the last-reset card a much longer settle period before SS0/SS1 and
# before the stock driver/UVM are loaded.
PER_GPU_RESET_WAIT="${PER_GPU_RESET_WAIT:-5}"
POST_PASS1_WAIT="${POST_PASS1_WAIT:-10}"
POST_PASS2_WAIT="${POST_PASS2_WAIT:-90}"
POST_SS_WAIT="${POST_SS_WAIT:-30}"
PRE_UVM_WAIT="${PRE_UVM_WAIT:-45}"
POST_UVM_WAIT="${POST_UVM_WAIT:-30}"
FINAL_INIT_TIMEOUT="${FINAL_INIT_TIMEOUT:-240}"

# Per-GPU CUDA readiness checks run as separate processes and retry only failed
# cards. One UVM recycle is attempted if a subset remains unavailable.
CUDA_READY_ATTEMPTS="${CUDA_READY_ATTEMPTS:-8}"
CUDA_READY_RETRY_WAIT="${CUDA_READY_RETRY_WAIT:-10}"
UVM_RECYCLE_AFTER_ATTEMPT="${UVM_RECYCLE_AFTER_ATTEMPT:-2}"
UVM_RECYCLE_WAIT="${UVM_RECYCLE_WAIT:-30}"
CUDA_TEST_TIMEOUT="${CUDA_TEST_TIMEOUT:-45}"
CUDA_SMOKE_SRC="${WORKDIR}/cuda_smoke_v7.cu"
CUDA_SMOKE_BIN="${WORKDIR}/cuda_smoke_v7"

GSP_REPLACED=0
RESET_METHODS_FORCED=0
LOGGING_STARTED=0
declare -a GPUS=()
declare -a PROTECTED_PIDS=()

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

build_protected_pid_list() {
    PROTECTED_PIDS=()

    local pid="$$"
    local parent
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        PROTECTED_PIDS+=("$pid")
        parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        [ -n "$parent" ] || break
        [ "$parent" != "$pid" ] || break
        pid="$parent"
    done

    PROTECTED_PIDS+=("1")
}

pid_is_protected() {
    local candidate="$1"
    local protected
    for protected in "${PROTECTED_PIDS[@]}"; do
        [ "$candidate" = "$protected" ] && return 0
    done
    return 1
}

list_gpu_holder_pids() {
    local dev
    for dev in /dev/nvidia*; do
        [ -e "$dev" ] || continue
        fuser "$dev" 2>/dev/null || true
    done |
        tr ' ' '\n' |
        grep -E '^[0-9]+$' |
        sort -nu
}

describe_holder_pid() {
    local pid="$1"
    ps -p "$pid" -o pid=,ppid=,stat=,unit=,comm=,args= 2>/dev/null || true

    if [ -r "/proc/$pid/cgroup" ]; then
        printf '      cgroup: '
        tr '\n' ' ' < "/proc/$pid/cgroup" 2>/dev/null || true
        echo
    fi
}

kill_gpu_holders_once() {
    mapfile -t holder_pids < <(list_gpu_holder_pids)
    [ "${#holder_pids[@]}" -gt 0 ] || return 0

    local pid
    for pid in "${holder_pids[@]}"; do
        [ -d "/proc/$pid" ] || continue

        if pid_is_protected "$pid"; then
            echo "Refusing to kill protected process $pid, which is in this script's shell/SSH ancestry:"
            describe_holder_pid "$pid"
            return 1
        fi

        log "GPU holder detected; terminating PID $pid"
        describe_holder_pid "$pid"
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 1

    for pid in "${holder_pids[@]}"; do
        [ -d "/proc/$pid" ] || continue
        pid_is_protected "$pid" && continue
        log "GPU holder PID $pid survived SIGTERM; sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    done

    return 0
}

drain_gpu_holders() {
    log "Draining transient NVIDIA device holders for up to ${HOLDER_DRAIN_TIMEOUT}s..."

    local elapsed=0
    local quiet=0
    local count=0

    while [ "$elapsed" -lt "$HOLDER_DRAIN_TIMEOUT" ]; do
        mapfile -t current_holders < <(list_gpu_holder_pids)
        count="${#current_holders[@]}"

        if [ "$count" -eq 0 ]; then
            quiet=$((quiet + 1))
            echo "  holder check: quiet ${quiet}/${HOLDER_QUIET_CHECKS}"
            if [ "$quiet" -ge "$HOLDER_QUIET_CHECKS" ]; then
                log "NVIDIA device files remained quiet for ${HOLDER_QUIET_CHECKS} consecutive checks."
                return 0
            fi
        else
            quiet=0
            echo "  holder check: ${count} PID(s) active"
            kill_gpu_holders_once || return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo
    echo "NVIDIA device holders remained after ${HOLDER_DRAIN_TIMEOUT}s:"
    mapfile -t current_holders < <(list_gpu_holder_pids)
    local pid
    for pid in "${current_holders[@]}"; do
        describe_holder_pid "$pid"
    done
    return 1
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
               sha256sum cmp dmesg tee pgrep pkill killall systemctl readlink lsmod ps seq; do
        require_command "$cmd"
    done

    [ -d "$WORKDIR" ] || die "Missing work directory: $WORKDIR"
    [ -f "$GSP" ] || die "Missing exact GSP firmware: $GSP"

    check_cmpunlocker_watchdog
    verify_driver_version
    verify_known_stock_gsp

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

    build_cuda_smoke_test
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

    sleep 2
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
                if ! echo "$gpu" > /sys/bus/pci/drivers/nvidia/unbind; then
                    echo "Failed to unbind $gpu from NVIDIA on this attempt."
                    return 1
                fi
                sleep 1
                if [ -L "/sys/bus/pci/devices/$gpu/driver" ] &&
                   [ "$(basename "$(readlink -f "/sys/bus/pci/devices/$gpu/driver")")" = "nvidia" ]; then
                    echo "$gpu still reports NVIDIA as its bound driver after unbind."
                    return 1
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

quiesce_and_unbind_all_nvidia() {
    local attempt

    for attempt in $(seq 1 5); do
        log "GPU quiesce/unbind attempt $attempt/5..."
        stop_gpu_users

        drain_gpu_holders || {
            echo "Could not obtain a quiet NVIDIA-device window on attempt $attempt."
            sleep 2
            continue
        }

        if unbind_all_nvidia; then
            # Once every GPU is unbound, new NVML/nvidia-smi opens can no
            # longer race the module-unload step. Drain any handles that were
            # already in flight before attempting module removal.
            if drain_gpu_holders; then
                return 0
            fi
            echo "GPU holders persisted after unbind on attempt $attempt."
        fi

        sleep 2
    done

    die "Could not quiesce and unbind all NVIDIA GPUs after 5 attempts."
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

    local wait_after
    if [ "$pass" = "1" ]; then
        wait_after="$POST_PASS1_WAIT"
    else
        wait_after="$POST_PASS2_WAIT"
    fi
    log "Waiting ${wait_after}s after pass $pass..."
    sleep "$wait_after"
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

    local wait_after
    if [ "$pass" = "1" ]; then
        wait_after="$POST_PASS1_WAIT"
    else
        wait_after="$POST_PASS2_WAIT"
    fi
    log "Waiting ${wait_after}s after pass $pass..."
    sleep "$wait_after"
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
    log "Creating run-specific GSP backup and patching with embedded patcher..."

    cp -a "$GSP" "$RUN_GSP_BACKUP"
    sync

    python3 - "$RUN_GSP_BACKUP" "$PAYLOAD" "$PATCHED_GSP" <<'PYEOF'
import struct
import sys
from pathlib import Path

input_path, payload_path, output_path = sys.argv[1:4]
PAYLOAD_SIZE = 0xF800
SIGNATURE_NAME = b".fwsignature_ga100"

gsp = bytearray(Path(input_path).read_bytes())
payload = Path(payload_path).read_bytes()

if len(payload) != PAYLOAD_SIZE:
    raise ValueError(f"Payload size mismatch: {len(payload)} != {PAYLOAD_SIZE}")
if gsp[:4] != b"\x7fELF":
    raise ValueError("Stock GSP is not an ELF file")

e_shoff = struct.unpack_from("<Q", gsp, 0x28)[0]
e_shentsize = struct.unpack_from("<H", gsp, 0x3A)[0]
e_shnum = struct.unpack_from("<H", gsp, 0x3C)[0]
e_shstrndx = struct.unpack_from("<H", gsp, 0x3E)[0]

if e_shentsize < 0x40 or e_shnum == 0 or e_shstrndx >= e_shnum:
    raise ValueError("Invalid ELF section-header metadata")

shdr_total = e_shnum * e_shentsize
if e_shoff + shdr_total > len(gsp):
    raise ValueError("ELF section headers are outside the GSP file")

orig_shdrs = bytearray(gsp[e_shoff:e_shoff + shdr_total])
strtab_hdr_off = e_shstrndx * e_shentsize
strtab_off = struct.unpack_from("<Q", orig_shdrs, strtab_hdr_off + 0x18)[0]
strtab_size = struct.unpack_from("<Q", orig_shdrs, strtab_hdr_off + 0x20)[0]

if strtab_off + strtab_size > len(gsp):
    raise ValueError("ELF section-name string table is outside the GSP file")

strtab = bytes(gsp[strtab_off:strtab_off + strtab_size])
sig_index = -1
sig_offset = 0

for index in range(e_shnum):
    header = index * e_shentsize
    name_index = struct.unpack_from("<I", orig_shdrs, header)[0]
    if name_index >= len(strtab):
        continue
    end = strtab.find(b"\x00", name_index)
    if end == -1:
        end = len(strtab)
    name = strtab[name_index:end]
    if name == SIGNATURE_NAME:
        sig_index = index
        sig_offset = struct.unpack_from("<Q", orig_shdrs, header + 0x18)[0]
        print(f"Found .fwsignature_ga100 at offset 0x{sig_offset:X}")
        break

if sig_index < 0:
    raise ValueError(".fwsignature_ga100 section not found")

payload_end = sig_offset + PAYLOAD_SIZE
if len(gsp) < payload_end:
    gsp.extend(b"\x00" * (payload_end - len(gsp)))
gsp[sig_offset:payload_end] = payload

new_shdrs = bytearray(orig_shdrs)
sig_header = sig_index * e_shentsize
struct.pack_into("<Q", new_shdrs, sig_header + 0x20, PAYLOAD_SIZE)

new_strtab_offset = len(gsp)
gsp.extend(strtab)
struct.pack_into("<Q", new_shdrs, strtab_hdr_off + 0x18, new_strtab_offset)

new_shoff = len(gsp)
gsp.extend(new_shdrs)
struct.pack_into("<Q", gsp, 0x28, new_shoff)

Path(output_path).write_bytes(gsp)
print(f"Patched GSP written to: {output_path}")
PYEOF

    [ -s "$PATCHED_GSP" ] || die "Patched GSP was not created."

    python3 - "$PATCHED_GSP" <<'PYEOF'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
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

        sleep "$POST_PASS2_WAIT"
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

build_cuda_smoke_test() {
    [ "$SKIP_CUDA_SMOKE" = "1" ] && return 0

    command -v nvcc >/dev/null 2>&1 ||
        die "nvcc is required for v7 CUDA validation, or set SKIP_CUDA_SMOKE=1."

    cat > "$CUDA_SMOKE_SRC" <<'CUDAOF'
#include <cuda_runtime.h>
#include <cstdio>

__global__ void increment_kernel(int *data) {
    const int index = threadIdx.x;
    if (index < 32) {
        data[index] += 1;
    }
}

static bool check(cudaError_t status, const char *operation) {
    if (status == cudaSuccess) {
        return true;
    }

    std::fprintf(
        stderr,
        "%s failed: %s\n",
        operation,
        cudaGetErrorString(status)
    );
    return false;
}

int main() {
    int count = 0;
    if (!check(cudaGetDeviceCount(&count), "cudaGetDeviceCount")) {
        return 1;
    }

    if (count != 1) {
        std::fprintf(stderr, "Expected exactly one visible GPU, found %d\n", count);
        return 1;
    }

    cudaDeviceProp properties{};
    if (!check(cudaGetDeviceProperties(&properties, 0), "cudaGetDeviceProperties")) {
        return 1;
    }

    std::printf("GPU: %s\n", properties.name);

    if (!check(cudaSetDevice(0), "cudaSetDevice")) {
        return 1;
    }

    // Explicitly create the CUDA context before allocating.
    if (!check(cudaFree(nullptr), "CUDA context creation")) {
        return 1;
    }

    int host[32] = {};
    int *device = nullptr;

    if (!check(cudaMalloc(&device, sizeof(host)), "cudaMalloc")) {
        return 1;
    }

    if (!check(
            cudaMemcpy(device, host, sizeof(host), cudaMemcpyHostToDevice),
            "cudaMemcpy HtoD"
        )) {
        cudaFree(device);
        return 1;
    }

    increment_kernel<<<1, 32>>>(device);

    if (!check(cudaGetLastError(), "kernel launch") ||
        !check(cudaDeviceSynchronize(), "cudaDeviceSynchronize") ||
        !check(
            cudaMemcpy(host, device, sizeof(host), cudaMemcpyDeviceToHost),
            "cudaMemcpy DtoH"
        )) {
        cudaFree(device);
        return 1;
    }

    cudaFree(device);

    for (int value : host) {
        if (value != 1) {
            std::fprintf(stderr, "Incorrect kernel result\n");
            return 1;
        }
    }

    std::puts("CUDA allocation + kernel OK");
    return 0;
}
CUDAOF

    log "Compiling native per-GPU CUDA smoke test..."
    timeout 120 nvcc -O2 -arch=sm_80 "$CUDA_SMOKE_SRC" -o "$CUDA_SMOKE_BIN" ||
        die "CUDA smoke-test compilation failed."
}

recycle_uvm_once() {
    log "Recycling nvidia_uvm after persistent CUDA-readiness failures..."

    # Do not alter HiveOS services. Only remove short-lived nvtool instances
    # that could be in flight while UVM is recycled.
    pkill -9 nvtool 2>/dev/null || true
    sleep 2

    if lsmod | grep -q '^nvidia_uvm'; then
        if ! modprobe -r nvidia_uvm; then
            echo "WARNING: nvidia_uvm could not be unloaded."
            return 1
        fi
    fi

    modprobe nvidia_uvm ||
        die "nvidia_uvm failed to reload."

    if command -v nvidia-modprobe >/dev/null 2>&1; then
        nvidia-modprobe -u -c=0 2>/dev/null || true
    fi

    log "Waiting ${UVM_RECYCLE_WAIT}s after UVM recycle..."
    sleep "$UVM_RECYCLE_WAIT"
}

cuda_smoke_test() {
    log "Running isolated per-GPU CUDA readiness test..."

    if [ "$SKIP_CUDA_SMOKE" = "1" ]; then
        echo "WARNING: CUDA smoke test skipped by SKIP_CUDA_SMOKE=1."
        return 0
    fi

    local map_file="${WORKDIR}/cuda_device_map_v7.csv"

    timeout 30 nvidia-smi \
        --query-gpu=index,pci.bus_id,uuid \
        --format=csv,noheader,nounits > "$map_file" ||
        die "Could not build the final NVIDIA device map."

    declare -A uuid_by_bdf=()
    declare -A index_by_bdf=()

    local index raw_bdf uuid bdf gpu
    while IFS=',' read -r index raw_bdf uuid; do
        index="$(echo "$index" | xargs)"
        raw_bdf="$(echo "$raw_bdf" | xargs)"
        uuid="$(echo "$uuid" | xargs)"
        bdf="$(printf '%s\n' "$raw_bdf" | normalize_bdfs)"

        uuid_by_bdf["$bdf"]="$uuid"
        index_by_bdf["$bdf"]="$index"
    done < "$map_file"

    for gpu in "${GPUS[@]}"; do
        [ -n "${uuid_by_bdf[$gpu]:-}" ] ||
            die "No final NVIDIA UUID mapping found for $gpu."
    done

    local -a pending=("${GPUS[@]}")
    local -a next_pending=()
    local attempt test_uuid test_index
    local uvm_recycled=0

    for attempt in $(seq 1 "$CUDA_READY_ATTEMPTS"); do
        echo
        log "CUDA readiness attempt $attempt/$CUDA_READY_ATTEMPTS for ${#pending[@]} GPU(s)..."
        next_pending=()

        for gpu in "${pending[@]}"; do
            test_uuid="${uuid_by_bdf[$gpu]}"
            test_index="${index_by_bdf[$gpu]}"

            if CUDA_DEVICE_ORDER=PCI_BUS_ID \
               CUDA_VISIBLE_DEVICES="$test_uuid" \
               timeout "$CUDA_TEST_TIMEOUT" \
               "$CUDA_SMOKE_BIN"; then
                echo "$gpu (nvidia-smi index $test_index): CUDA ready"
            else
                echo "$gpu (nvidia-smi index $test_index): CUDA not ready"
                next_pending+=("$gpu")
            fi
        done

        if [ "${#next_pending[@]}" -eq 0 ]; then
            log "Every expected GPU passed isolated CUDA validation."
            return 0
        fi

        echo "Still pending:"
        printf '  %s\n' "${next_pending[@]}"
        pending=("${next_pending[@]}")

        if [ "$uvm_recycled" -eq 0 ] &&
           [ "$attempt" -ge "$UVM_RECYCLE_AFTER_ATTEMPT" ]; then
            recycle_uvm_once || true
            uvm_recycled=1
        elif [ "$attempt" -lt "$CUDA_READY_ATTEMPTS" ]; then
            log "Waiting ${CUDA_READY_RETRY_WAIT}s before retrying pending GPUs..."
            sleep "$CUDA_READY_RETRY_WAIT"
        fi
    done

    echo
    echo "CUDA remained unavailable on:"
    printf '  %s\n' "${pending[@]}"

    echo
    echo "Recent NVIDIA/UVM errors:"
    dmesg | grep -iE \
        'NVRM|Xid|RmInitAdapter|unexpected WPR2|reset required|GSP|UVM' |
        tail -200 || true

    return 1
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
    echo "HiveOS services and watchdog units are not stopped, masked, or modified."
    echo "Only transient GPU-holder processes may be terminated during module unload."
    echo "Forced rmmod is disabled. The script aborts instead of forcing a busy module."
    echo "Expected GPU count: ${EXPECTED_GPU_COUNT:-0} (0 means auto-detect all)"
    read -r -p "Type UNLOCK-ALL-V7 to continue: " answer
    [ "$answer" = "UNLOCK-ALL-V7" ] || die "Cancelled."

    build_protected_pid_list

    # Clean initial stock-driver removal. The holder-drain loop handles
    # transient HiveOS monitoring clients without aborting on the first PID.
    quiesce_and_unbind_all_nvidia
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

    # HiveOS monitoring can respawn a short-lived nvidia-smi/NVML client here.
    # Drain and diagnose those clients, then unbind immediately once the device
    # files have stayed quiet for several consecutive checks.
    quiesce_and_unbind_all_nvidia
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

    log "Waiting ${POST_SS_WAIT}s after the final SS0/SS1 write..."
    sleep "$POST_SS_WAIT"

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

    log "All expected GPUs initialized."
    log "Waiting ${PRE_UVM_WAIT}s before loading NVIDIA UVM..."
    sleep "$PRE_UVM_WAIT"

    log "Loading NVIDIA UVM..."
    modprobe nvidia_uvm

    if command -v nvidia-modprobe >/dev/null 2>&1; then
        nvidia-modprobe -u -c=0 2>/dev/null || true
    fi

    log "Waiting ${POST_UVM_WAIT}s after loading NVIDIA UVM..."
    sleep "$POST_UVM_WAIT"

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
    echo "SUCCESS: compute unlock v7 validated on ${#GPUS[@]} GPU(s)"
    echo "No STRAP or LMR VRAM-capacity writes were used."
    echo "All GPUs passed NVIDIA initialization and CUDA validation."
    echo "========================================================"

    trap - EXIT INT TERM
}

main "$@"
