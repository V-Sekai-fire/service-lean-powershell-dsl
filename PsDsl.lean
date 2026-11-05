/-!
# PsDsl: a typed embedded DSL that renders safe PowerShell

Pitfalls it removes:
* nested quoting      -> every string literal is rendered as a PowerShell single-quoted
                         literal with `'` doubled; no interpolation is possible
* "$p" eaten by shell -> scripts are written to a file and run with `-File`
                         (no `-Command`/`-EncodedCommand` length or quoting limits)
* partial edits       -> `guarded` runs a body and, on any error, runs the rollback
* blind edits         -> edits throw unless the pattern occurs the expected number of times
-/

namespace PsDsl

/-- Quote text as a PowerShell single-quoted literal. -/
def quote (s : String) : String :=
  "'" ++ s.replace "'" "''" ++ "'"

inductive Expr where
  | str   : String → Expr
  | num   : Nat → Expr
  | var   : String → Expr
  | regKey : String → String → Expr        -- registry value as string
  | readText : Expr → Expr                 -- file contents, byte-preserving (Latin-1)
  | serviceState : String → Expr
  | count : Expr → Expr → Expr             -- number of regex matches of pattern in text
  | subst : Expr → Expr → Expr → Expr      -- regex replace: text pattern replacement
  | eq    : Expr → Expr → Expr

inductive Stmt where
  | set       : String → Expr → Stmt
  | require   : Expr → String → Stmt       -- precondition, throws message when false
  | setReg    : String → String → Expr → Stmt
  | writeText : Expr → Expr → Stmt         -- path, text (byte-preserving Latin-1)
  | say       : String → Stmt
  | guarded   : List Stmt → List Stmt → Stmt  -- body, rollback on error (then rethrow)

def latin1 : String := "[Text.Encoding]::GetEncoding(28591)"

partial def Expr.render : Expr → String
  | .str s => quote s
  | .num n => toString n
  | .var v => "$" ++ v
  | .regKey k n => s!"[string](Get-ItemProperty -LiteralPath {quote k} -Name {quote n}).{n}"
  | .readText p => s!"{latin1}.GetString([IO.File]::ReadAllBytes({p.render}))"
  | .serviceState n =>
      s!"(Get-CimInstance Win32_Service -Filter {quote s!"Name='{n}'"}).State"
  | .count t p => s!"([regex]::Matches({t.render}, {p.render}).Count)"
  | .subst t p r => s!"[regex]::Replace({t.render}, {p.render}, {r.render})"
  | .eq a b => s!"({a.render} -eq {b.render})"

partial def Stmt.render (ind : String) : Stmt → String
  | .set v e => s!"{ind}${v} = {e.render}\n"
  | .require c msg =>
      s!"{ind}if (-not {c.render}) \{ throw {quote msg} }\n"
  | .setReg k n e =>
      s!"{ind}Set-ItemProperty -LiteralPath {quote k} -Name {quote n} -Value ({e.render})\n"
  | .writeText p t =>
      s!"{ind}[IO.File]::WriteAllBytes({p.render}, {latin1}.GetBytes({t.render}))\n"
  | .say m => s!"{ind}{quote m}\n"
  | .guarded body rollback =>
      let b := String.join (body.map (Stmt.render (ind ++ "    ")))
      let r := String.join (rollback.map (Stmt.render (ind ++ "    ")))
      s!"{ind}try \{\n{b}{ind}} catch \{\n{r}{ind}    throw\n{ind}}\n"

/-- A full script: strict errors, then statements. -/
def render (prog : List Stmt) : String :=
  "$ErrorActionPreference = 'Stop'\n" ++ String.join (prog.map (Stmt.render ""))

/-- Command that runs a saved script, optionally elevated; argv form, no quoting layers. -/
def runnerArgs (scriptPath : String) (elevate : Bool) : String × Array String :=
  let ps := #["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath]
  if elevate then ("gsudo.exe", #["powershell.exe"] ++ ps) else ("powershell.exe", ps)

/-- Require the service to be running. -/
def requireRunning (service : String) : Stmt :=
  .require (.eq (.serviceState service) (.str "Running")) s!"service {service} is not running"

/-- Replace a regex in a text file when it matches exactly `expect` times; rolls back on failure. -/
def replaceInFile (path pattern replacement : String) (expect : Nat) : List Stmt :=
  [ .set "orig" (.readText (.str path)),
    .require (.eq (.count (.var "orig") (.str pattern)) (.num expect))
      s!"expected {expect} match(es) of the pattern in {path}",
    .guarded
      [ .writeText (.str path) (.subst (.var "orig") (.str pattern) (.str replacement)) ]
      [ .writeText (.str path) (.var "orig") ],
    .say s!"updated {path}" ]

/-- Rewrite a registry value by regex when it matches exactly `expect` times; rolls back on failure. -/
def rewriteReg (key name pattern replacement : String) (expect : Nat) : List Stmt :=
  [ .set "old" (.regKey key name),
    .require (.eq (.count (.var "old") (.str pattern)) (.num expect))
      s!"expected {expect} match(es) of the pattern in {name}",
    .guarded
      [ .setReg key name (.subst (.var "old") (.str pattern) (.str replacement)) ]
      [ .setReg key name (.var "old") ],
    .say s!"updated {name}" ]

/-- The ninfer change: lower context and KV capacity, drop rope-yarn. -/
def ninferProgram : List Stmt :=
  let key := "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\ninfer\\Parameters"
  [ requireRunning "ninfer" ]
  ++ rewriteReg key "AppParameters" "(?<!\\S)--max-context\\s+327680(?!\\S)" "--max-context 262144" 1
  ++ rewriteReg key "AppParameters" "(?<!\\S)--kv-capacity\\s+327680(?!\\S)" "--kv-capacity 262144" 1
  ++ rewriteReg key "AppParameters" "(?<!\\S)--rope-yarn(?!\\S)" "" 1
  ++ [ .say "restart the service to apply" ]

end PsDsl
