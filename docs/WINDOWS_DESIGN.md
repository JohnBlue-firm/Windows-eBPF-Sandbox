# Windows Design

## Scope

This repository carries over only the Boost.Asio design from QEMU-eBPF-Sandbox. It does not copy the Linux basic or custom OOP implementations. The first milestone is a portable C++20 `io_context` action loop; Windows eBPF loading and QEMU guest provisioning are separate integrations.

## Platform boundary

Boost.Asio can use IOCP on Windows, but that does not make Linux eBPF APIs or hooks portable. eBPF for Windows provides libbpf-compatible user-mode APIs and a Windows execution environment. Program support is determined by the Windows hooks and helpers exposed by that project. Linux-specific XDP, cgroup, syscall-trace, and tracepoint examples must not be presented as working on Windows without a supported Windows equivalent.

The runtime supports Windows 11 and Windows Server 2022 or later. Its deployment paths include native programs compiled into Windows drivers and JIT execution through the eBPF service. Driver signing, HVCI, and the selected runtime mode affect what can be loaded; consult Microsoft's current getting-started guide before automating guest installation.

## Windows replacements for Linux hooks

| Linux example/hook | Windows eBPF status | Practical Windows direction |
| --- | --- | --- |
| XDP | eBPF for Windows has an XDP program/attach type. It is a network-interface hook, not a promise that Linux XDP drivers or helper behavior work unchanged. | Keep an XDP sample, but use Microsoft's Windows eBPF SDK/runtime, a supported NIC path, and validate its documented attach requirements in the guest. |
| cgroup socket hooks | Windows has no Linux cgroup hierarchy. eBPF for Windows documents socket-address attach types, including bind and connect-related hooks; these are Windows networking hooks, not cgroup emulation. | Replace cgroup egress policy with a specific supported socket-address or network hook. A bind policy/observability sample is the clearest first port. |
| tracepoint/syscall trace | There is no general Linux tracepoint or syscall-trace hook equivalent in the standard eBPF-for-Windows examples. | Use ETW for general OS event tracing. Use eBPF only when the event is covered by a documented Windows attach provider. |
| file create/write/rename/delete | eBPF for Windows does not provide a general filesystem modification hook. | `ReadDirectoryChangesW` is notification-only: it reports changes after they occur and cannot veto, block, or roll them back. For pre-operation inspection or enforcement (for example, denying a write or rename), use a Windows Filesystem Minifilter driver. For historical change tracking, consider the USN change journal. These are separate from eBPF and require their own security/privilege model. |

## Implemented samples

- `xdp/xdp_pass.bpf.c` uses the XDP extension's `xdp_md_t` and `SEC("xdp/pass")` interface. XDP is a separate provider from eBPF for Windows core; install/enable the XDP-for-Windows extension before attempting to load this object.
- `socket_address/bind_policy.bpf.c` uses the non-deprecated `BPF_PROG_TYPE_CGROUP_SOCK_ADDR` bind attach types and rejects port 4444 for IPv4 and IPv6. It demonstrates a Windows socket policy, not cgroup grouping.
- `etw_process_monitor` consumes the Microsoft-Windows-Kernel-Process ETW provider and hands event metadata to `ActionLoop`. ETW availability and process-event payloads are provider/version-specific; the example does not equate ETW with a general syscall tracepoint ABI.
- `file_change_monitor` reports completed changes through `ReadDirectoryChangesW`. It cannot enforce policy. Pre-operation allow/deny decisions belong in a Minifilter; its Filter Manager communication port is the appropriate bridge to an Asio user-mode service.

The BPF objects use header snapshots pinned to the following upstream commits so CMake does not track a moving branch:

- [eBPF for Windows](https://github.com/microsoft/ebpf-for-windows/tree/b7a8dd217a608719b03afe848cc4d5206445fbda)
- [XDP for Windows](https://github.com/microsoft/xdp-for-windows/tree/6fda82cba9712b0a0aac132e507c0945924d5209)

`windows-dev-tools.iso` also contains the project source. The guest bootstrap copies it from the read-only ISO to `%USERPROFILE%\source\Windows-eBPF-Sandbox`, then runs Microsoft's SHA-256-verified Visual Studio 2022 setup script and reapplies a SHA-256-verified `.vsconfig` pinned to the same commit. The manifest installs the Windows SDK/WDK components required by that eBPF source revision. This does not install eBPF runtime drivers. Install the eBPF core runtime separately, and install/enable the XDP extension separately before attempting to load the XDP object.

The bind object uses the current `cgroup/bind4` and `cgroup/bind6` attach sections; `netsh ebpf add program` loads/attaches the selected section. The XDP extension is a separate provider and requires its `xdp`/`xdpebpf` runtime components. Development verification requires `xdpebpfexport` and running `xdpbpfexport.exe` first. Test-signed drivers require the Microsoft VM test-signing steps and a guest reboot; do not enable test signing on a production machine.

Run `scripts/setup.sh --install-windows-vm` to attach the small guest-tools ISO. After Windows is installed, execute `setup-windows-guest.ps1` from an elevated PowerShell on that ISO. It verifies Microsoft's pinned setup script before installing the VS 2022 components described in its `.vsconfig`, including the Windows SDK and WDK. This prepares a Windows build environment; it does not silently enable test signing or install the eBPF runtime drivers.

The attach providers and supported program types evolve. Check the current [eBPF for Windows Getting Started guide](https://github.com/microsoft/ebpf-for-windows/blob/main/docs/GettingStarted.md) and hook documentation before committing an example to a particular hook ABI.

The Windows-only `file_change_monitor` sample uses `ReadDirectoryChangesW` and forwards notifications into the Boost.Asio `ActionLoop`. Run it with `file_change_monitor.exe C:\watched`. It deliberately does not modify the observed files or claim to enforce a policy. A Minifilter enforcement driver is a separate WDK project: its pre-operation callbacks decide whether to allow, deny, or pend an I/O request; it can send telemetry to a user-mode service over a Filter Manager communication port. Keep policy enforcement in the driver and use Asio for user-mode event processing/control-plane work. Start from Microsoft's [file system minifilter driver documentation](https://learn.microsoft.com/windows-hardware/drivers/ifs/about-file-system-filter-drivers) and [Filter Manager communication-port documentation](https://learn.microsoft.com/windows-hardware/drivers/ifs/communication-between-user-mode-and-kernel-mode).

## Host setup and Boost.Asio

Run `scripts/setup.sh` on Ubuntu/Debian to install the C++ toolchain, Clang/LLVM, CMake, and QEMU. It intentionally does not install Linux `libbpf`, `bpftool`, kernel headers, or system Boost packages: the eBPF runtime runs in the Windows guest, and CMake FetchContent downloads Boost headers for the Asio host application.

## Intended layout

```text
eBPF_boost_asio_design/
  CMakeLists.txt
  actions/       Asio action dispatch and asynchronous consumers
  xdp/           XDP pass-through BPF source
  socket_address/ Bind policy BPF source
  etw/           Windows ETW process event consumer
  file_monitor/  Windows ReadDirectoryChangesW observer sample
  ebpf/          Windows-specific program and object lifecycle wrappers
scripts/
  run-windows-qemu.sh
docs/
  WINDOWS_DESIGN.md
```

The `ebpf/` loader implementation is intentionally not stubbed with Linux `libbpf` calls. Add it after selecting a concrete Windows hook, target OS version, and deployment mode. Keep event collection behind an adapter so the Asio action loop remains testable without kernel components.

## QEMU guest workflow

The chosen image is Windows Server 2022 Evaluation, Desktop Experience, English x64. It is the documented minimum Windows Server version for eBPF for Windows and works with the starter launcher's legacy BIOS device profile without Windows 11's UEFI/TPM 2.0 requirement. The Evaluation image is for temporary development/testing and remains subject to Microsoft's evaluation terms and expiry.

`scripts/setup.sh --download-windows-iso` downloads the ISO from Microsoft's Evaluation Center into the ignored `build/isos/` directory, writes a local SHA-256 file, and creates the qcow2 system disk. `--install-windows-vm` additionally launches the interactive installer. The hash records the exact local download; Microsoft does not publish a checksum alongside this direct Evaluation Center link, so it is not an independent signature verification.

Install Windows and the Microsoft eBPF for Windows runtime inside the guest, then build and run the C++ consumer there. QEMU user-mode networking is enabled for guest access to the network; it does not expose the guest as a host service automatically. For remote Codespaces, use `WIN_VM_DISPLAY=vnc=127.0.0.1:0` and forward TCP port 5900 to interact with the installer.

Windows 11 requires a more complete virtual hardware profile, including UEFI and TPM 2.0. The initial script is aimed at Windows Server 2022, which is supported by eBPF for Windows and is more straightforward to boot in a minimal QEMU setup. Codespaces may not provide nested virtualization; in that case use a local machine with QEMU/KVM or another Windows VM host.

## References

- [eBPF for Windows](https://github.com/microsoft/ebpf-for-windows)
- [Getting Started](https://github.com/microsoft/ebpf-for-windows/blob/main/docs/GettingStarted.md)
- [Original Boost.Asio design](https://github.com/JohnBlue-git/QEMU-eBPF-Sandbox/blob/main/docs/BOOST_ASIO_DESIGN.md)