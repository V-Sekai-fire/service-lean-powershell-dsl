# psdsl

A small Lean 4 CLI that generates safe PowerShell from typed edits, so you never fight shell quoting again.

## Why

- Every string is emitted as a PowerShell single-quoted literal (`'` doubled): no interpolation, no nested quoting.
- Scripts are written to a temp `.ps1` and run with `-File` (never `-Command`/`-EncodedCommand`), so there are no length or quoting limits.
- Edits require an exact match count (`--expect`, default 1) and roll back on any error.
- Elevation goes through `gsudo` with plain argv, no extra quoting layer.

## Build

```powershell
lake build
.lake\build\bin\psdsl.exe --help
```

## Usage

```powershell
# Print the script (default), write it, run it, or run it elevated
psdsl reg-rewrite --key 'HKLM:\SYSTEM\...\Parameters' --name AppParameters `
      --pattern '(?<!\S)--rope-yarn(?!\S)' --replace= --require-service ninfer --elevate

psdsl file-replace --path C:\x\config.txt --pattern 327680 --replace 262144 --expect 2 --run

psdsl example          # the ninfer GPU-requirement change
psdsl quote "it's"     # 'it''s'
```

Use `--opt=VALUE` to pass an empty value (`--replace=`): PowerShell drops empty `''` arguments to native programs.

## Layout

- `PsDsl.lean`: the DSL (`Expr`, `Stmt`, renderer, `rewriteReg`, `replaceInFile`).
- `Main.lean`: the CLI.
