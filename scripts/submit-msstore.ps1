param(
  [Parameter(Mandatory = $true)]
  [string]$PackagePath,

  [string]$TenantId = $env:PARTNER_CENTER_TENANT_ID,
  [string]$ClientId = $env:PARTNER_CENTER_CLIENT_ID,
  [string]$ClientSecret = $env:PARTNER_CENTER_CLIENT_SECRET,
  [string]$AppId = $env:PARTNER_CENTER_APP_ID
)

$ErrorActionPreference = "Stop"

foreach ($item in @(
  @{ Name = "PARTNER_CENTER_TENANT_ID"; Value = $TenantId },
  @{ Name = "PARTNER_CENTER_CLIENT_ID"; Value = $ClientId },
  @{ Name = "PARTNER_CENTER_CLIENT_SECRET"; Value = $ClientSecret },
  @{ Name = "PARTNER_CENTER_APP_ID"; Value = $AppId }
)) {
  if ([string]::IsNullOrWhiteSpace($item.Value)) {
    throw "Missing $($item.Name)"
  }
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
  throw "Package not found: $PackagePath"
}

$tokenBody = @{
  grant_type    = "client_credentials"
  client_id     = $ClientId
  client_secret = $ClientSecret
  resource      = "https://manage.devcenter.microsoft.com"
}
$tokenResp = Invoke-RestMethod `
  -Method Post `
  -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" `
  -Body $tokenBody

$headers = @{
  Authorization  = "Bearer $($tokenResp.access_token)"
  "Content-Type" = "application/json"
}

$createResp = Invoke-RestMethod `
  -Method Post `
  -Uri "https://manage.devcenter.microsoft.com/v2.0/my/applications/$AppId/submissions" `
  -Headers $headers

$submissionId = $createResp.id
$uploadUrl = $createResp.fileUploadUrl
Write-Host "Submission $submissionId created."

$zip = Join-Path $env:TEMP ("cepheus-msstore-{0}.zip" -f ([guid]::NewGuid().ToString("N")))
try {
  Compress-Archive -Path $PackagePath -DestinationPath $zip -Force
  Invoke-RestMethod `
    -Method Put `
    -Uri $uploadUrl `
    -Headers @{ "x-ms-blob-type" = "BlockBlob" } `
    -InFile $zip

  Invoke-RestMethod `
    -Method Post `
    -Uri "https://manage.devcenter.microsoft.com/v2.0/my/applications/$AppId/submissions/$submissionId/commit" `
    -Headers $headers

  Write-Host "Submission $submissionId committed for Microsoft Store review."
} finally {
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}
