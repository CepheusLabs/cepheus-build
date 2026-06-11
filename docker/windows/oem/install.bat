@echo off
REM ===========================================================================
REM Cepheus Build — Windows VM provisioning.
REM
REM dockur/windows runs this automatically (as admin) after the unattended
REM Windows install completes. It turns the VM into a cepheus-build worker:
REM   * OpenSSH Server on :22 (the container backend's ssh endpoint)
REM   * Chocolatey + git, rsync, Flutter, Python, and the VS C++ toolchain
REM     (rsync is required VM-side: the dispatch host's rsync spawns
REM     `rsync --server` here over ssh for the repo push / artifact pull)
REM
REM Drop your dispatch host's SSH public key at docker/windows/oem/
REM authorized_keys BEFORE first boot and this script installs it (and turns
REM password auth off). Otherwise add it manually afterwards (see README).
REM Then clone the cepheus-build toolkit to %USERPROFILE%\cepheus-build (the
REM path in build.toml [container_profiles.default.windows].toolkit).
REM ===========================================================================
echo [cepheus] provisioning Windows build VM...

REM --- OpenSSH Server -------------------------------------------------------
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
powershell -NoProfile -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd"
powershell -NoProfile -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22"
REM Match build.toml shell = "powershell": invoke cepheus-build via PowerShell.
reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" /f
mkdir "%USERPROFILE%\.ssh" 2>nul

REM --- SSH key (seeded from the oem dir when present) -----------------------
REM %~dp0 is this script's directory: dockur copies the mounted /oem folder
REM into the VM and runs install.bat from it, so a sibling authorized_keys
REM file rides along. The admin authorized_keys file requires a restricted
REM ACL or sshd ignores it. With key auth in place, disable password auth.
if exist "%~dp0authorized_keys" (
    echo [cepheus] installing administrators_authorized_keys from oem dir
    copy /Y "%~dp0authorized_keys" "C:\ProgramData\ssh\administrators_authorized_keys" >nul
    icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
    powershell -NoProfile -Command "Add-Content -Path 'C:\ProgramData\ssh\sshd_config' -Value 'PasswordAuthentication no'; Restart-Service sshd"
) else (
    echo [cepheus] no authorized_keys in oem dir; password auth stays on --
    echo [cepheus] add your key to C:\ProgramData\ssh\administrators_authorized_keys
)

REM --- Chocolatey -----------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"

REM --- Build toolchains -----------------------------------------------------
REM choco.exe is invoked by absolute path: this cmd session's PATH predates the
REM Chocolatey install, so a bare `choco` would not resolve yet. rsync (cwRsync)
REM must be on the MACHINE PATH for non-interactive sshd sessions; Chocolatey's
REM shim dir (C:\ProgramData\chocolatey\bin) satisfies that.
REM Flutter Windows desktop needs Visual Studio's "Desktop development with C++".
call "%ProgramData%\chocolatey\bin\choco.exe" install -y --no-progress git python3 rsync flutter visualstudio2022buildtools visualstudio2022-workload-nativedesktop
if %ERRORLEVEL% NEQ 0 if %ERRORLEVEL% NEQ 3010 (
    echo [cepheus] ERROR: choco install failed with exit code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
REM 3010 = success, reboot required (VS Build Tools); dockur reboots the VM
REM as part of its normal lifecycle.

echo [cepheus] provisioning complete.
echo [cepheus] NEXT: clone cepheus-build to %USERPROFILE%\cepheus-build
echo           (and add your SSH key if it was not seeded from the oem dir)
