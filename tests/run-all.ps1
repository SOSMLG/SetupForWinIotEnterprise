Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent

$tests = @('syntax-check.ps1', 'json-check.ps1', 'static-check.ps1', 'module-smoke.ps1', 'installer-smoke.ps1')
$failed = @()
foreach ($t in $tests) {
  $path = Join-Path $PSScriptRoot $t
  Write-Host ('--- ' + $t + ' ---')
  # pessimistic default: a powershell that never launched must not read as a pass.
  $LASTEXITCODE = 1
  & powershell -NoProfile -ExecutionPolicy Bypass -File $path
  if ($LASTEXITCODE -ne 0) { $failed += $t; Write-Host ('FAILED: ' + $t) }
}

# PSScriptAnalyzer is optional here. report only, nothing depends on it.
$psa = Get-Module -ListAvailable PSScriptAnalyzer
if ($psa) {
  Write-Host '--- PSScriptAnalyzer (report only) ---'
  Import-Module PSScriptAnalyzer -DisableNameChecking
  $issues = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'install-Win-Iot.ps1') -Severity Error)
  if ($issues.Count) { $issues | ForEach-Object { Write-Host ('  line ' + $_.Line + ': ' + $_.Message) } }
  else { Write-Host '  no errors.' }
} else { Write-Host '--- PSScriptAnalyzer not installed, skipped ---' }

Write-Host ''
if ($failed.Count -eq 0) { Write-Host 'ALL SUITES OK'; exit 0 }
Write-Host ('SUITES FAILED: ' + ($failed -join ', ')); exit 1
