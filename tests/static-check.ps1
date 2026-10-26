# static-check.ps1: cheap source checks the parser can't do.
# FAIL = a bug class that already bit once. warn = worth a look, never fails the run.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'install-Win-Iot.ps1'

$fails = @()
$warns = 0
function Fail($msg) { Write-Host ('  FAIL: ' + $msg); $script:fails += $msg }
function Warn($msg) { Write-Host ('  warn: ' + $msg); $script:warns++ }
function Test-InFunction($node) {
  $p = $node.Parent
  while ($p) {
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }
    $p = $p.Parent
  }
  return $false
}

$files = @(Get-ChildItem $root -Recurse | Where-Object {
  $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '\\ISO\\build\\|\\ISO\\Offline\\|\\node_modules\\'
})

# 1. wmi class names use underscores. Win32-Battery (hyphen) throws and the catch hides it.
foreach ($f in $files) {
  $text = Get-Content $f.FullName -Raw
  foreach ($m in [regex]::Matches($text, '(?i)(Get-CimInstance|Get-WmiObject)\s+(-ClassName\s+)?(Win32-\w+)')) {
    Fail ($f.Name + ': bad wmi class name ' + $m.Groups[3].Value)
  }
}
Write-Host '  checked: wmi class names'

# 2. PS 5.1 reads a bom-less utf-8 script as ANSI. keep scripts ascii, or give them a bom.
foreach ($f in $files) {
  $b = [System.IO.File]::ReadAllBytes($f.FullName)
  $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  if (-not $bom) {
    $hi = 0
    foreach ($x in $b) { if ($x -gt 127) { $hi++ } }
    if ($hi -gt 0) { Fail ($f.Name + ': non-ascii bytes without a bom (' + $hi + ')') }
  }
}
Write-Host '  checked: script encoding'

# installer AST for the next three
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { Fail 'installer does not parse, see syntax-check' }
else {
  # 3. a script-level call must come after the function it calls. powershell resolves at run time.
  $funcs = @{}
  $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  foreach ($d in $defs) { if (-not (Test-InFunction $d)) { $funcs[$d.Name.ToLower()] = $d.Extent.StartLineNumber } }
  $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
  foreach ($c in $cmds) {
    if (Test-InFunction $c) { continue }
    $name = $c.GetCommandName()
    if (-not $name) { continue }
    $key = $name.ToLower()
    if ($funcs.ContainsKey($key) -and $c.Extent.StartLineNumber -lt $funcs[$key]) {
      Fail ('installer line ' + $c.Extent.StartLineNumber + ': ' + $name + ' is called before it is defined (line ' + $funcs[$key] + ')')
    }
  }
  Write-Host '  checked: function order'

  # 4. params nobody reads. a dead switch looks like it works. warn only.
  $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
  $vars = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
  foreach ($p in $paramNames) {
    $uses = @($vars | Where-Object { $_.VariablePath.UserPath -eq $p -and $_.Parent -isnot [System.Management.Automation.Language.ParameterAst] })
    if ($uses.Count -eq 0) { Warn ('installer param -' + $p + ' is never used') }
  }
  Write-Host '  checked: unused params'
}

# 5. .gitconfig has a blank identity on purpose, so it must be fresh-only.
$lines = @(Get-Content $installer)
foreach ($l in $lines) {
  if ($l -match 'Git\\\.gitconfig' -and $l -notmatch 'Copy-Fresh') { Fail ('gitconfig deploy must use Copy-Fresh: ' + $l.Trim()) }
}
Write-Host '  checked: gitconfig deploy'

# 5b. -KeepFastStartup has to actually gate the hibernate-off call. it only logged once.
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match 'powercfg /hibernate off') {
    $from = [Math]::Max(0, $i - 6)
    $near = ($lines[$from..$i] -join ' ')
    if ($near -notmatch 'KeepFastStartup') { Fail ('installer line ' + ($i + 1) + ': hibernate off is not gated by -KeepFastStartup') }
  }
}
Write-Host '  checked: KeepFastStartup gate'

# 6. files the installer expects from the repo. missing ones just log a skip, so warn only.
$text = Get-Content $installer -Raw
$seen = @{}
foreach ($m in [regex]::Matches($text, "Join-Path \`$Repo '([^']+)'")) {
  $rel = $m.Groups[1].Value
  if ($seen.ContainsKey($rel) -or $rel -eq 'Fonts') { continue }
  $seen[$rel] = $true
  if (-not (Test-Path -Path (Join-Path $root $rel))) { Warn ('installer expects ' + $rel + ' but it is not in the repo') }
}
Write-Host '  checked: expected repo files'

Write-Host ''
if ($fails.Count -eq 0) { Write-Host ('STATIC OK (' + $warns + ' warnings)'); exit 0 }
Write-Host ('STATIC FAIL (' + $fails.Count + ' problems, ' + $warns + ' warnings)')
exit 1
