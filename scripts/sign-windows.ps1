param(
  # One or more files to sign (installer .exe, plus optionally the inner
  # .exe/.dll before packaging). Globs are expanded.
  [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Path,

  # Azure Trusted Signing configuration. Defaults come from the environment so
  # CI only has to set secrets; nothing is hardcoded.
  [string]$Endpoint      = $env:TRUSTED_SIGNING_ENDPOINT,
  [string]$Account       = $env:TRUSTED_SIGNING_ACCOUNT,
  [string]$CertProfile   = $env:TRUSTED_SIGNING_CERT_PROFILE,

  # Azure service-principal auth, consumed by DefaultAzureCredential.
  [string]$TenantId      = $env:AZURE_TENANT_ID,
  [string]$ClientId      = $env:AZURE_CLIENT_ID,
  [string]$ClientSecret  = $env:AZURE_CLIENT_SECRET,

  # Pin the dotnet `sign` tool version for reproducible CI installs.
  [string]$SignToolVersion = $(if ($env:SIGN_CLI_VERSION) { $env:SIGN_CLI_VERSION } else { "0.9.1-beta.25278.1" }),

  [switch]$DryRun
)

# ─────────────────────────────────────────────────────────────────────────────
# Windows code signing via Azure Trusted Signing.
#
# Signing is ENV-GATED: when the Trusted Signing / Azure variables are not all
# present, this script prints a warning and exits 0, leaving the artifact
# UNSIGNED. That lets unsigned dev/CI builds "just work" before Azure is set up
# — flip signing on later purely by providing the secrets, with no code change.
# (Same pattern as Deckhand's macOS DMG script and submit-msstore.ps1.)
#
# Required to actually sign (set all of):
#   TRUSTED_SIGNING_ENDPOINT       e.g. https://eus.codesigning.azure.net
#   TRUSTED_SIGNING_ACCOUNT        Trusted Signing account name
#   TRUSTED_SIGNING_CERT_PROFILE   certificate profile name
#   AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET   service principal
#
# Implementation uses the cross-platform `sign` dotnet global tool
# (https://github.com/dotnet/sign), which has first-class Trusted Signing
# support and only needs the .NET SDK (preinstalled on windows-latest).
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$envDryRun = $env:CBUILD_DRY_RUN
$isDryRun = $DryRun.IsPresent -or `
  (-not [string]::IsNullOrEmpty($envDryRun) -and `
   $envDryRun -notin @("0", "false", "no"))

# Expand globs and verify every target exists up front.
$files = @()
foreach ($p in $Path) {
  $resolved = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
  if ($resolved) {
    $files += $resolved.FullName
  } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
    $files += (Resolve-Path -LiteralPath $p).Path
  } else {
    throw "File to sign not found: $p"
  }
}
if ($files.Count -eq 0) {
  throw "No files matched for signing: $($Path -join ', ')"
}

# Decide whether signing is configured.
$signingVars = @($Endpoint, $Account, $CertProfile, $TenantId, $ClientId, $ClientSecret)
$signingConfigured = -not ($signingVars | Where-Object { [string]::IsNullOrWhiteSpace($_) })

if (-not $signingConfigured) {
  Write-Warning "Trusted Signing not configured (TRUSTED_SIGNING_* / AZURE_* unset)."
  Write-Warning "Leaving artifact(s) UNSIGNED:"
  foreach ($f in $files) { Write-Warning "    $f" }
  Write-Warning "Set the Trusted Signing secrets to enable signing — no code change needed."
  exit 0
}

if ($isDryRun) {
  Write-Host "[dry-run] Would sign with Azure Trusted Signing:"
  Write-Host "  Endpoint:      $Endpoint"
  Write-Host "  Account:       $Account"
  Write-Host "  Cert profile:  $CertProfile"
  foreach ($f in $files) { Write-Host "  File:          $f" }
  Write-Host "[dry-run] No signing performed."
  exit 0
}

# Authenticate via service principal (consumed by DefaultAzureCredential).
$env:AZURE_TENANT_ID     = $TenantId
$env:AZURE_CLIENT_ID     = $ClientId
$env:AZURE_CLIENT_SECRET = $ClientSecret

# Ensure the `sign` tool is available, installing it pinned if needed.
# Put the global-tools dir on PATH *before* probing: on a warm or self-hosted
# runner the tool may already be installed but absent from this process's PATH,
# and `dotnet tool install` errors with "already installed" in that case.
$toolsPath = Join-Path $env:USERPROFILE ".dotnet\tools"
if ((Test-Path $toolsPath) -and ($env:PATH -notlike "*$toolsPath*")) {
  $env:PATH = "$toolsPath;$env:PATH"
}
if (-not (Get-Command sign -ErrorAction SilentlyContinue)) {
  Write-Host "==> Installing dotnet 'sign' tool ($SignToolVersion)"
  & dotnet tool install --global sign --version $SignToolVersion
  if ($LASTEXITCODE -ne 0) {
    # Already-installed or partial: update is idempotent and recovers both.
    & dotnet tool update --global sign --version $SignToolVersion
  }
  if ((Test-Path $toolsPath) -and ($env:PATH -notlike "*$toolsPath*")) {
    $env:PATH = "$toolsPath;$env:PATH"
  }
  if (-not (Get-Command sign -ErrorAction SilentlyContinue)) {
    throw "Failed to install the 'sign' tool"
  }
}

foreach ($f in $files) {
  Write-Host "==> Signing $f (Trusted Signing: $Account/$CertProfile)"
  & sign code trusted-signing $f `
    --trusted-signing-endpoint $Endpoint `
    --trusted-signing-account $Account `
    --trusted-signing-certificate-profile $CertProfile `
    --timestamp-url "http://timestamp.acs.microsoft.com" `
    --verbosity information
  if ($LASTEXITCODE -ne 0) { throw "Signing failed for $f" }
}

Write-Host "==> Signed $($files.Count) file(s) with Azure Trusted Signing."
