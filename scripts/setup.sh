#!/usr/bin/env bash
set -euo pipefail

download_windows_iso=false
launch_windows_installer=false

usage() {
    printf 'Usage: %s [--download-windows-iso | --install-windows-vm]\n' "$0"
    printf '  --download-windows-iso  Download the official Server 2022 Evaluation ISO and create its VM disk.\n'
    printf '  --install-windows-vm    Do the above and launch the interactive QEMU installer.\n'
}

case "${1:-}" in
    "") ;;
    --download-windows-iso) download_windows_iso=true ;;
    --install-windows-vm)
        download_windows_iso=true
        launch_windows_installer=true
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
    printf 'This setup script supports Ubuntu/Debian hosts with apt-get.\n' >&2
    exit 1
fi

if (( EUID == 0 )); then
    apt=(apt-get)
else
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'Run as root or install sudo to install host packages.\n' >&2
        exit 1
    fi
    apt=(sudo apt-get)
fi

packages=(
    build-essential
    ca-certificates
    clang
    cmake
    curl
    git
    lld
    llvm
    pkg-config
    python3
    qemu-system-x86
    qemu-utils
    xorriso
)

prepare_windows_vm() {
    local iso_dir="build/isos"
    local iso_path="$iso_dir/WindowsServer2022-Eval-en-us.iso"
    local partial_path="$iso_path.part"
    local iso_url='https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'

    mkdir -p "$iso_dir"
    if [[ ! -f "$iso_path" ]]; then
        printf 'Downloading the official Windows Server 2022 Evaluation ISO (~4.7 GiB)...\n'
        printf 'Source: Microsoft Evaluation Center (en-us, x64).\n'
        rm -f "$partial_path"
        curl --fail --location --retry 3 --retry-all-errors \
            --output "$partial_path" "$iso_url"
        if [[ $(stat -c '%s' "$partial_path") -lt 4000000000 ]]; then
            rm -f "$partial_path"
            printf 'Downloaded file is unexpectedly small; refusing to use it as an ISO.\n' >&2
            return 1
        fi
        mv "$partial_path" "$iso_path"
    else
        printf 'Reusing existing ISO: %s\n' "$iso_path"
    fi

    sha256sum "$iso_path" > "$iso_path.sha256"
    printf 'ISO SHA-256 recorded in %s.sha256\n' "$iso_path"

    if [[ ! -f build/windows.qcow2 ]]; then
        qemu-img create -f qcow2 build/windows.qcow2 "${WIN_VM_DISK_SIZE:-64G}"
    fi

    xorriso -as mkisofs -quiet -J -R -graft-points -V WINDOWS_DEV_TOOLS \
        -o build/isos/windows-dev-tools.iso \
        setup-windows-guest.ps1=scripts/setup-windows-guest.ps1 \
        README.md=README.md \
        docs=docs \
        eBPF_boost_asio_design=eBPF_boost_asio_design
    printf 'Windows guest tools/project media created at build/isos/windows-dev-tools.iso\n'
}

printf '[1/3] Updating apt package lists...\n'
"${apt[@]}" update

printf '[2/3] Installing C++/eBPF toolchain and QEMU...\n'
"${apt[@]}" install -y "${packages[@]}"

printf '[3/3] Configuring the Asio project (CMake fetches Boost headers)...\n'
cmake -S eBPF_boost_asio_design -B build

if [[ "$download_windows_iso" == true ]]; then
    printf '\nThe Microsoft Evaluation ISO is subject to its evaluation license terms.\n'
    prepare_windows_vm
fi

printf '\nSetup complete. Build and run the Asio smoke test with:\n'
printf '  cmake --build build\n'
printf '  ./build/asio_smoke_test\n'
printf '\nBoot a Windows installer ISO with:\n'
printf '  ./scripts/run-windows-qemu.sh /path/to/WindowsServer2022.iso\n'

if [[ "$download_windows_iso" == true ]]; then
    printf '  ./scripts/run-windows-qemu.sh\n'
fi

if [[ "$launch_windows_installer" == true ]]; then
    printf '\nLaunching the interactive Windows Server 2022 installer...\n'
    WIN_VM_BOOT_ORDER=dc ./scripts/run-windows-qemu.sh
fi