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
REM pwsh: product windows lanes invoke PowerShell 7 scripts; cmake/ninja ride
REM the PATH for the toolkit's tool checks (Flutter itself locates VS's own).
REM Flutter is NOT installed via choco (that pulls LATEST and drifts ahead of
REM the rest of the pool) -- it is git-cloned at the pinned tag below.
call "%ProgramData%\chocolatey\bin\choco.exe" install -y --no-progress git python3 rsync pwsh cmake ninja --installargs "ADD_CMAKE_TO_PATH=System"
if %ERRORLEVEL% NEQ 0 if %ERRORLEVEL% NEQ 3010 (
    echo [cepheus] ERROR: choco install failed with exit code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

REM --- Flutter (PINNED) + bash on the machine PATH ---------------------------
REM Pin Flutter to the SAME tag as docker/linux/Dockerfile so every OS in the
REM pool builds identically (a newer Flutter breaks shared code like forge).
REM Also put Git's bash on the machine PATH: bash-based product build scripts
REM (e.g. deckhand's scripts/build.sh windows) run over the PowerShell ssh
REM session and need `bash` resolvable.
set "CBUILD_FLUTTER_VERSION=3.41.7"
if not exist "C:\flutter\bin\flutter.bat" (
    git clone --depth 1 --branch %CBUILD_FLUTTER_VERSION% https://github.com/flutter/flutter.git C:\flutter
)
powershell -NoProfile -Command "$m=[Environment]::GetEnvironmentVariable('Path','Machine'); foreach($p in 'C:\flutter\bin','C:\Program Files\Git\bin'){ if($m -notlike '*'+$p+'*'){ $m=$m+';'+$p } }; [Environment]::SetEnvironmentVariable('Path',$m,'Machine')"

REM Flutter Windows desktop needs Visual Studio's "Desktop development with
REM C++". The workload rides the SAME bootstrapper invocation via
REM --package-parameters: the separate visualstudio2022-workload-* choco
REM package can exit 0 without actually installing the payload when queued
REM in the same transaction.
REM VC.ATL: flutter_secure_storage_windows (and other plugins) include atlstr.h.
call "%ProgramData%\chocolatey\bin\choco.exe" install -y --no-progress visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended"
if %ERRORLEVEL% NEQ 0 if %ERRORLEVEL% NEQ 3010 (
    echo [cepheus] ERROR: VS Build Tools install failed with exit code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
REM 3010 = success, reboot required; dockur reboots the VM as part of its
REM normal lifecycle. Verify the MSVC toolset actually materialized -- the VS
REM installer can report success while skipping the workload.
if not exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC" (
    echo [cepheus] WARNING: MSVC toolset missing after install. Run manually:
    echo   "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --norestart --wait
)

REM --- vcpkg + OpenSSL --------------------------------------------------------
REM printdeck-app's Windows lane links OpenSSL from a user vcpkg checkout
REM (scripts/build_windows.ps1 expects %USERPROFILE%\vcpkg\installed\x64-windows).
call "%ProgramData%\chocolatey\bin\choco.exe" install -y --no-progress git >nul 2>&1
git clone https://github.com/microsoft/vcpkg "%USERPROFILE%\vcpkg"
call "%USERPROFILE%\vcpkg\bootstrap-vcpkg.bat" -disableMetrics
"%USERPROFILE%\vcpkg\vcpkg.exe" install openssl:x64-windows
if %ERRORLEVEL% NEQ 0 (
    echo [cepheus] WARNING: vcpkg openssl install failed with %ERRORLEVEL% -- printdeck windows builds need it.
)

echo [cepheus] provisioning complete.
echo [cepheus] NEXT: clone cepheus-build to %USERPROFILE%\cepheus-build
echo           (and add your SSH key if it was not seeded from the oem dir)
