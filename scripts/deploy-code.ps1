<#
.SYNOPSIS
  Deploys the function code to the gateway with a server-side (remote) build.

.DESCRIPTION
  Infrastructure is provisioned by Terraform (infra/). Code is deployed
  separately by this script so the two lifecycles stay decoupled.

  A remote build is required: the app's dependencies (cryptography/cffi via the
  azure-* SDKs) ship native binaries, so a locally built package would not run on
  the Linux host. This script zips the source and lets Azure (Oryx) build it.

  The deployment runs over the app's SCM endpoint. When the Function App is
  locked to private inbound access, set -OpenPublicAccess to briefly allow
  public access for the deploy and re-lock it afterwards.

.EXAMPLE
  ./scripts/deploy-code.ps1 -ResourceGroup rg-docgw-dev -FunctionApp docgw-dev-xxxxx

.EXAMPLE
  ./scripts/deploy-code.ps1 -ResourceGroup rg-docgw-dev -FunctionApp docgw-dev-xxxxx -OpenPublicAccess
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $ResourceGroup,
  [Parameter(Mandatory = $true)] [string] $FunctionApp,
  [string] $SourceDir = (Join-Path $PSScriptRoot '..\src\functionapp'),
  [switch] $OpenPublicAccess
)

$ErrorActionPreference = 'Stop'
$resourceId = az functionapp show -n $FunctionApp -g $ResourceGroup --query id -o tsv

function Set-PublicAccess([string]$state) {
  az resource update --ids $resourceId --set properties.publicNetworkAccess=$state --output none
}

$relock = $false
if ($OpenPublicAccess) {
  $current = az resource show --ids $resourceId --query "properties.publicNetworkAccess" -o tsv
  if ($current -ne 'Enabled') {
    Write-Host "Opening public inbound access for deployment..."
    Set-PublicAccess 'Enabled'
    $relock = $true
    Start-Sleep -Seconds 30 # let the SCM endpoint become reachable
  }
}

try {
  # Build the deployment zip from source (code only; no local dependencies).
  $zip = Join-Path $env:TEMP "docgw-deploy-$(Get-Random).zip"
  $files = 'function_app.py', 'host.json', 'requirements.txt', 'auth.py', 'config.py', 'documents.py'
  Push-Location $SourceDir
  Compress-Archive -Path $files -DestinationPath $zip -Force
  Pop-Location
  Write-Host "Built package: $zip ($((Get-Item $zip).Length) bytes)"

  # Submit the remote-build deployment. az may exit non-zero on a cosmetic
  # post-deploy host-key check even though the deployment itself succeeds, so we
  # capture output and verify the real outcome via the deployment status below.
  Write-Host "Deploying with remote build..."
  $log = az functionapp deployment source config-zip `
    --name $FunctionApp --resource-group $ResourceGroup `
    --src $zip --build-remote true 2>&1
  $log | ForEach-Object { Write-Host "  $_" }

  if (-not ($log -match 'status code 202')) {
    throw "Deployment was not accepted. See output above."
  }

  # Confirm the functions actually indexed (the real success signal).
  Write-Host "Verifying functions indexed..."
  $ok = $false
  foreach ($attempt in 1..12) {
    Start-Sleep -Seconds 10
    $fns = az functionapp function list -n $FunctionApp -g $ResourceGroup --query "[].name" -o tsv 2>$null
    if ($fns) { Write-Host "Indexed functions:`n$fns"; $ok = $true; break }
    Write-Host "  ...not indexed yet (attempt $attempt/12)"
  }
  if (-not $ok) { throw "Deployment finished but no functions indexed. Check the build logs." }

  Write-Host "Deployment succeeded." -ForegroundColor Green
}
finally {
  Remove-Item $zip -ErrorAction SilentlyContinue
  if ($relock) {
    Write-Host "Re-locking Function App to private inbound access..."
    Set-PublicAccess 'Disabled'
  }
}
