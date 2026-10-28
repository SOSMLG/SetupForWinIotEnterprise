---
name: powershell-5-1
description: Windows PowerShell 5.1 pitfalls (syntax, encoding, exit codes, JSON, paths). Load when writing or editing .ps1 files.
---
- 5.1 has no `&&`, `||`, ternary `?:`, `??`, `?.` or `-Parallel`. Use if/else.
- Keep scripts ASCII, or save UTF-8 with a BOM. A BOM-less UTF-8 file is read as ANSI and non-ASCII text gets mangled.
- After a native exe, check `$LASTEXITCODE`. try/catch does not see a non-zero exit.
- `Start-Process -Wait -PassThru`, then read `.ExitCode`.
- `Join-Path` takes two arguments only. Nest it for deeper paths.
- `ConvertFrom-Json` has no `-AsHashtable` and chokes on empty-string keys.
- `Get-Content -Raw` for the whole file. `Set-Content -Encoding UTF8` writes a BOM.
- Under `Set-StrictMode -Version 2` an unset variable throws. Wrap results in `@()` before `.Count`.
- Build paths from `$env:USERPROFILE`, `$env:LOCALAPPDATA`, `$env:ProgramFiles`. No hard-coded user names.
- Test with `powershell -NoProfile -File x.ps1`, not `pwsh`.
