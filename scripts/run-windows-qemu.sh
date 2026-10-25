#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 2 ]]; then
    printf 'Usage: %s [windows-installer.iso] [disk.qcow2]\n' "$0" >&2
    exit 2
fi

iso_input=${1:-build/isos/WindowsServer2022-Eval-en-us.iso}
iso_path=$(realpath "$iso_input")
if [[ ! -f "$iso_path" ]]; then
    printf 'Installer ISO not found: %s\n' "$iso_path" >&2
    exit 1
fi

qemu=${QEMU_SYSTEM_X86_64:-qemu-system-x86_64}
if ! command -v "$qemu" >/dev/null 2>&1; then
    printf 'QEMU executable not found: %s\n' "$qemu" >&2
    exit 1
fi
if ! command -v qemu-img >/dev/null 2>&1; then
    printf 'qemu-img is required to create the VM disk.\n' >&2
    exit 1
fi

disk_path=${2:-${WIN_VM_DISK:-build/windows.qcow2}}
mkdir -p "$(dirname "$disk_path")"
if [[ ! -f "$disk_path" ]]; then
    qemu-img create -f qcow2 "$disk_path" "${WIN_VM_DISK_SIZE:-64G}"
fi

accel=tcg
cpu=qemu64
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=kvm
    cpu=host
else
    printf 'Warning: KVM is unavailable to this user; Windows software emulation will be slow.\n' >&2
fi

display=${WIN_VM_DISPLAY:-gtk}
if [[ "${WIN_VM_DAEMONIZE:-0}" == 1 || "${WIN_VM_DAEMONIZE:-false}" == true ]]; then
    display=${WIN_VM_DISPLAY:-vnc=127.0.0.1:0}
fi

qemu_args=(
    -machine pc \
    -accel "$accel" \
    -cpu "$cpu" \
    -smp "${WIN_VM_CPUS:-4}" \
    -m "${WIN_VM_MEMORY:-8G}" \
    -drive "file=$disk_path,format=qcow2,if=ide,index=0" \
    -drive "file=$iso_path,media=cdrom,readonly=on,if=ide,index=2" \
    -boot "order=${WIN_VM_BOOT_ORDER:-c},menu=on" \
    -nic user,model=e1000 \
    -display "$display"
)

guest_tools_iso=build/isos/windows-dev-tools.iso
if [[ -f "$guest_tools_iso" ]]; then
    qemu_args+=(-drive "file=$guest_tools_iso,media=cdrom,readonly=on,if=ide,index=3")
fi

if [[ "${WIN_VM_DAEMONIZE:-0}" == 1 || "${WIN_VM_DAEMONIZE:-false}" == true ]]; then
    pid_file=${WIN_VM_PID_FILE:-build/windows-qemu.pid}
    log_file=${WIN_VM_LOG_FILE:-build/windows-qemu.log}
    mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"

    if [[ -f "$pid_file" ]]; then
        old_pid=$(<"$pid_file")
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null &&
            ps -p "$old_pid" -o args= | grep -q '[q]emu-system'; then
            printf 'QEMU is already running with PID %s.\n' "$old_pid" >&2
            exit 1
        fi
        rm -f "$pid_file"
    fi

    "$qemu" "${qemu_args[@]}" -daemonize -pidfile "$pid_file" -D "$log_file"
    printf 'QEMU is running in the background (PID %s).\n' "$(<"$pid_file")"
    printf 'VNC: %s | Log: %s | Stop: kill $(<%s)\n' "$display" "$log_file" "$pid_file"
else
    exec "$qemu" "${qemu_args[@]}"
fi