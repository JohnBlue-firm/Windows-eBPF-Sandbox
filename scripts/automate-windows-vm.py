#!/usr/bin/env python3
"""Provision a disposable Windows QEMU guest and collect its build/test results."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path, PurePosixPath
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INSTALLER = ROOT / "build/isos/WindowsServer2022-Eval-en-us.iso"
DEFAULT_DISK = ROOT / "build/windows-automation.qcow2"
DEFAULT_RESULTS = ROOT / "build/windows-automation-results"
WINDOWS_DEV_TOOLS_LABEL = "WINDOWS_DEV_TOOLS"
MAX_UPLOAD_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Unattended Windows Server 2022 setup, SDK/WDK bootstrap, build, and test."
    )
    parser.add_argument("--installer", type=Path, default=DEFAULT_INSTALLER, help="Windows Server 2022 Evaluation ISO.")
    parser.add_argument("--disk", type=Path, default=DEFAULT_DISK, help="New qcow2 disk path; existing disks are never overwritten.")
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS, help="Directory for the returned build/test artifacts.")
    parser.add_argument("--memory", default="8G", help="QEMU guest memory (default: 8G).")
    parser.add_argument("--cpus", type=int, default=4, help="QEMU guest CPU count (default: 4).")
    parser.add_argument("--timeout-hours", type=float, default=12, help="Maximum automation runtime (default: 12 hours).")
    parser.add_argument("--keep-vm", action="store_true", help="Keep the generated VM disk after a successful run.")
    return parser.parse_args()


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"Required host tool was not found on PATH: {name}")
    return path


def make_answer_file(password: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>350</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System</Label><Active>true</Active></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>2</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Windows Automation</FullName>
        <Organization>Local development VM</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>WIN-EBPF-AUTO</ComputerName>
      <TimeZone>UTC</TimeZone>
      <AutoLogon>
        <Password><Value>{password}</Value><PlainText>true</PlainText></Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>{password}</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Start Windows guest automation</Description>
          <CommandLine>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "&amp; {{ $v = Get-Volume -FileSystemLabel 'WINDOWS_DEV_TOOLS' | Where-Object {{ $_.DriveLetter }} | Select-Object -First 1; if (-not $v) {{ throw 'Windows tools media not found' }}; &amp; (Join-Path ($v.DriveLetter + ':\\') 'Invoke-WindowsVmAutomation.ps1') }}"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"""


class ResultReceiver(BaseHTTPRequestHandler):
    token = ""
    destination: Optional[Path] = None
    completed = threading.Event()

    def do_POST(self) -> None:
        if self.path != "/result":
            self.send_error(404)
            return
        supplied_token = self.headers.get("X-Automation-Token", "")
        if not hmac.compare_digest(supplied_token, self.token):
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return
        if length <= 0 or length > MAX_UPLOAD_BYTES:
            self.send_error(413, "Result archive size is invalid")
            return

        temporary = self.destination.with_suffix(".part")
        try:
            with temporary.open("wb") as output:
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ConnectionError("Upload ended before Content-Length bytes were received")
                    output.write(chunk)
                    remaining -= len(chunk)
            os.replace(temporary, self.destination)
        except OSError as error:
            temporary.unlink(missing_ok=True)
            self.send_error(400, f"Could not save result archive: {error}")
            return

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Results received\n")
        self.wfile.flush()
        self.completed.set()

    def log_message(self, _format: str, *_args: object) -> None:
        return


def extract_results(archive_path: Path, destination: Path) -> dict:
    total_size = 0
    with zipfile.ZipFile(archive_path) as archive:
        for item in archive.infolist():
            member = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            if (
                member.is_absolute()
                or ".." in member.parts
                or "\\" in item.filename
                or (member.parts and ":" in member.parts[0])
                or (mode and (mode & 0o170000) == 0o120000)
            ):
                raise RuntimeError(f"Unsafe path in result archive: {item.filename!r}")
            total_size += item.file_size
            if total_size > MAX_EXTRACTED_BYTES:
                raise RuntimeError("Unpacked result archive exceeds the 2 GiB safety limit.")
        archive.extractall(destination)

    manifest_path = destination / "automation-result.json"
    if not manifest_path.is_file():
        raise RuntimeError("Result archive did not contain automation-result.json.")
    return json.loads(manifest_path.read_text(encoding="utf-8-sig"))


def build_tools_iso(xorriso: str, iso_path: Path, stage_path: Path) -> str:
    answer_path = stage_path / "Autounattend.xml"
    password = "Aa1!" + secrets.token_hex(20)
    answer_path.write_text(make_answer_file(password), encoding="utf-8")

    config_path = stage_path / "automation-config.json"
    config_path.write_text(
        json.dumps(
            {
                "uploadUrl": f"http://10.0.2.2:{ResultReceiver.server_port}/result",
                "token": ResultReceiver.token,
            }
        ),
        encoding="utf-8",
    )
    grafts = [
        f"Autounattend.xml={answer_path}",
        f"automation-config.json={config_path}",
        "Invoke-WindowsVmAutomation.ps1=scripts/Invoke-WindowsVmAutomation.ps1",
        "setup-windows-guest.ps1=scripts/setup-windows-guest.ps1",
        "test-windows-build.ps1=scripts/test-windows-build.ps1",
        "README.md=README.md",
        "docs=docs",
        "eBPF_boost_asio_design=eBPF_boost_asio_design",
    ]
    subprocess.run(
        [
            xorriso,
            "-as",
            "mkisofs",
            "-quiet",
            "-J",
            "-R",
            "-graft-points",
            "-V",
            WINDOWS_DEV_TOOLS_LABEL,
            "-o",
            str(iso_path),
            *grafts,
        ],
        cwd=ROOT,
        check=True,
    )
    return password


def write_private_secret(path: Path, value: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as secret_file:
        secret_file.write(value + "\n")


def stop_process(process: subprocess.Popen, timeout: int = 20) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main() -> int:
    args = parse_args()
    installer = args.installer.resolve()
    disk = args.disk.resolve()
    results = args.results.resolve()
    build_dir = ROOT / "build"
    iso_path: Optional[Path] = None
    stage_path: Optional[Path] = None
    qemu_process: Optional[subprocess.Popen] = None
    disk_created = False
    run_succeeded = False
    admin_password: Optional[str] = None
    server: Optional[HTTPServer] = None
    server_thread: Optional[threading.Thread] = None
    qemu_log: Optional[Path] = None
    password_path = build_dir / "windows-automation-admin-password.txt"

    try:
        if not installer.is_file():
            raise RuntimeError(
                f"Windows installer ISO not found: {installer}\n"
                "Download the official evaluation ISO first with `make vm-image`."
            )
        if disk.exists():
            raise RuntimeError(
                f"Refusing to overwrite existing VM disk: {disk}\n"
                "Choose another --disk path or remove this specific generated disk yourself."
            )
        if results.exists():
            raise RuntimeError(
                f"Refusing to overwrite existing results: {results}\n"
                "Choose another --results path or move the existing results first."
            )
        result_archive = results.parent / f"{results.name}.zip"
        if (
            disk == results
            or disk in results.parents
            or results in disk.parents
            or disk == result_archive
            or disk in result_archive.parents
            or result_archive in disk.parents
        ):
            raise RuntimeError("--disk must not overlap the result directory or its ZIP archive.")
        if args.keep_vm and password_path.exists():
            raise RuntimeError(
                f"Refusing to overwrite the existing guest password file: {password_path}"
            )
        if args.cpus < 1 or args.timeout_hours <= 0:
            raise RuntimeError("--cpus and --timeout-hours must be positive.")

        qemu_img = require_tool("qemu-img")
        qemu = require_tool(os.environ.get("QEMU_SYSTEM_X86_64", "qemu-system-x86_64"))
        xorriso = require_tool("xorriso")
        build_dir.mkdir(parents=True, exist_ok=True)
        disk.parent.mkdir(parents=True, exist_ok=True)
        results.parent.mkdir(parents=True, exist_ok=True)

        token = secrets.token_urlsafe(32)
        ResultReceiver.token = token
        ResultReceiver.destination = result_archive
        ResultReceiver.completed = threading.Event()
        if ResultReceiver.destination.exists():
            raise RuntimeError(
                f"Refusing to overwrite existing result archive: {ResultReceiver.destination}"
            )
        server = HTTPServer(("0.0.0.0", 0), ResultReceiver)
        server.timeout = 1
        ResultReceiver.server_port = server.server_address[1]
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()

        stage_path = Path(tempfile.mkdtemp(prefix="windows-automation-", dir=build_dir))
        iso_fd, iso_name = tempfile.mkstemp(
            prefix="windows-automation-tools-", suffix=".iso", dir=build_dir
        )
        os.close(iso_fd)
        iso_path = Path(iso_name)
        admin_password = build_tools_iso(xorriso, iso_path, stage_path)
        subprocess.run([qemu_img, "create", "-f", "qcow2", str(disk), "64G"], check=True)
        disk_created = True

        accel = "kvm" if Path("/dev/kvm").exists() and os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
        if accel == "tcg":
            print("Warning: KVM is unavailable; Windows installation and SDK setup may take many hours.")
        qemu_args = [
            qemu,
            "-machine",
            "pc",
            "-accel",
            accel,
            "-cpu",
            "host" if accel == "kvm" else "qemu64",
            "-smp",
            str(args.cpus),
            "-m",
            args.memory,
            "-drive",
            f"file={disk},format=qcow2,if=ide,index=0",
            "-drive",
            f"file={installer},media=cdrom,readonly=on,if=ide,index=2",
            "-drive",
            f"file={iso_path},media=cdrom,readonly=on,if=ide,index=3",
            "-boot",
            "order=dc,menu=off",
            "-nic",
            "user,model=e1000",
            "-display",
            "none",
            "-monitor",
            "none",
        ]
        print(f"Starting unattended Windows guest (disk: {disk}).")
        print(f"Guest build/test results will be collected under: {results}")
        log_fd, log_name = tempfile.mkstemp(
            prefix="windows-automation-qemu-", suffix=".log", dir=build_dir
        )
        os.close(log_fd)
        qemu_log = Path(log_name)
        with qemu_log.open("wb") as log_file:
            qemu_process = subprocess.Popen(
                qemu_args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=log_file,
            )
            deadline = time.monotonic() + args.timeout_hours * 3600
            next_status = time.monotonic() + 60
            while time.monotonic() < deadline:
                if ResultReceiver.completed.wait(timeout=2):
                    break
                exit_code = qemu_process.poll()
                if exit_code is not None:
                    raise RuntimeError(
                        f"QEMU exited with status {exit_code} before returning guest results. "
                        f"See {qemu_log}."
                    )
                if time.monotonic() >= next_status:
                    print("Windows setup/bootstrap/build is still running; no guest interaction is required.")
                    next_status = time.monotonic() + 60
            else:
                raise TimeoutError(
                    f"Windows automation exceeded {args.timeout_hours:g} hours. "
                    f"QEMU diagnostics: {qemu_log}"
                )
            stop_process(qemu_process)

        results.mkdir(parents=True, exist_ok=False)
        manifest = extract_results(ResultReceiver.destination, results)
        if not isinstance(manifest, dict):
            raise RuntimeError("Result archive manifest must be a JSON object.")
        ResultReceiver.destination.unlink()
        print(f"Guest result: {manifest.get('status', 'unknown')}")
        print(f"Result manifest: {results / 'automation-result.json'}")
        print(f"Build/test artifacts: {results}")
        if manifest.get("status") != "passed":
            print(f"Guest reported failure: {manifest.get('error')}", file=sys.stderr)
            print(f"Guest transcript: {results / 'automation.log'}", file=sys.stderr)
            return 1

        run_succeeded = True
        if not args.keep_vm:
            disk.unlink()
            disk_created = False
            print("Removed the temporary VM disk; use --keep-vm to retain it on future runs.")
        else:
            print(f"VM disk retained. Guest Administrator password: {password_path}")
        return 0
    except KeyboardInterrupt:
        print("Interrupted; stopping the QEMU guest.", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile, json.JSONDecodeError, TimeoutError) as error:
        print(f"Windows VM automation failed: {error}", file=sys.stderr)
        return 1
    finally:
        if qemu_process is not None:
            stop_process(qemu_process)
        if server is not None:
            server.shutdown()
            server.server_close()
        if server_thread is not None:
            server_thread.join(timeout=5)
        if iso_path is not None:
            iso_path.unlink(missing_ok=True)
        if stage_path is not None:
            try:
                shutil.rmtree(stage_path)
            except OSError as error:
                print(f"Could not remove automation staging directory {stage_path}: {error}", file=sys.stderr)
        if disk_created:
            print(f"VM disk retained: {disk}", file=sys.stderr)
            if admin_password is not None and not password_path.exists():
                try:
                    write_private_secret(password_path, admin_password)
                    print(f"Guest Administrator password saved with owner-only permissions: {password_path}", file=sys.stderr)
                except OSError as error:
                    print(f"Could not save the guest password to {password_path}: {error}", file=sys.stderr)
        if qemu_log is not None:
            if run_succeeded:
                qemu_log.unlink(missing_ok=True)
            else:
                print(f"QEMU diagnostics: {qemu_log}", file=sys.stderr)
        if (
            ResultReceiver.destination is not None
            and ResultReceiver.destination.exists()
            and not (results / "automation-result.json").exists()
        ):
            print(f"Guest result archive retained at: {ResultReceiver.destination}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
