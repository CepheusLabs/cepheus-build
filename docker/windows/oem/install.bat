@echo off
REM ===========================================================================
REM Cepheus Build — Windows VM provisioning.
REM
REM dockur/windows runs this automatically (as admin) after the unattended
REM Windows install completes. It turns the VM into a cepheus-build worker:
REM   * OpenSSH Server on :22 (the container backend's ssh endpoint)
REM   * Chocolatey + git, Flutter, Python, and the VS C++ desktop toolchain
REM
REM After this runs, add your dispatch host's SSH public key (see README) and
REM place the cepheus-build toolkit at %USERPROFILE%\cepheus-build (the path in
REM build.toml [container_profiles.default.windows].toolkit).
REM ===========================================================================
echo [cepheus] provisioning Windows build VM...

REM --- OpenSSH Server -------------------------------------------------------
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
powershell -NoProfile -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd"
powershell -NoProfile -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22"
REM Match build.toml shell = "powershell": invoke cepheus-build via PowerShell.
reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" /f
mkdir "%USERPROFILE%\.ssh" 2>nul

REM --- Chocolatey -----------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"

REM --- Build toolchains -----------------------------------------------------
REM Flutter Windows desktop needs Visual Studio's "Desktop development with C++".
call choco install -y git python3 flutter visualstudio2022buildtools visualstudio2022-workload-nativedesktop

echo [cepheus] provisioning complete.
echo [cepheus] NEXT: add your SSH public key to
echo           C:\ProgramData\ssh\administrators_authorized_keys
echo           and clone cepheus-build to %USERPROFILE%\cepheus-build
