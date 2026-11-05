import PsDsl

open PsDsl

def usage : String :=
"psdsl - generate safe, quoting-proof PowerShell from typed edits

USAGE
  psdsl <command> [options]

COMMANDS
  reg-rewrite    regex-rewrite a registry value
      --key KEY --name NAME --pattern REGEX --replace TEXT
      [--expect N]            required match count (default 1)
      [--require-service S]   only proceed if service S is Running
  file-replace   regex-rewrite a text file (byte-preserving)
      --path FILE --pattern REGEX --replace TEXT [--expect N]
  example        the ninfer GPU-requirement change
  quote TEXT     print TEXT as a PowerShell single-quoted literal

OUTPUT OPTIONS (reg-rewrite, file-replace, example)
  (default)      print the script to stdout
  --out FILE     write the script to FILE
  --run          run the script with powershell.exe -File
  --elevate      run it elevated through gsudo (implies --run)

  -h, --help     show this help

Use --opt=VALUE to pass an empty value (e.g. --replace=): PowerShell drops
empty '' arguments when calling native programs.

Every edit checks the match count first and rolls back on any error.
Strings are always emitted as single-quoted literals, and scripts are run
with -File, so no shell quoting layer can alter them."

structure Opts where
  kv : List (String × String) := []
  flags : List String := []
  pos : List String := []

def flagNames : List String := ["run", "elevate", "help"]

def parseOpts : List String → Opts → Except String Opts
  | [], o => .ok o
  | "-h" :: rest, o => parseOpts rest { o with flags := "help" :: o.flags }
  | a :: rest, o =>
    if a.startsWith "--" then
      let body := (a.drop 2).toString
      match body.splitOn "=" with
      | k :: v :: more =>
          parseOpts rest { o with kv := (k, String.intercalate "=" (v :: more)) :: o.kv }
      | _ =>
        if flagNames.contains body then
          parseOpts rest { o with flags := body :: o.flags }
        else
          match rest with
          | v :: rest' => parseOpts rest' { o with kv := (body, v) :: o.kv }
          | [] => .error s!"option --{body} needs a value"
    else
      parseOpts rest { o with pos := o.pos ++ [a] }

def Opts.get? (o : Opts) (k : String) : Option String :=
  (o.kv.find? (·.1 == k)).map (·.2)

def Opts.req (o : Opts) (k : String) : IO String :=
  match o.get? k with
  | some v => pure v
  | none => throw (IO.userError s!"missing required option --{k}")

def Opts.has (o : Opts) (f : String) : Bool := o.flags.contains f

def Opts.expect (o : Opts) : IO Nat :=
  match o.get? "expect" with
  | none => pure 1
  | some s =>
    match s.toNat? with
    | some n => pure n
    | none => throw (IO.userError s!"--expect must be a number, got '{s}'")

/-- Write the script to a temp .ps1 and run it; the file is always removed. -/
def runScript (script : String) (elevate : Bool) : IO UInt32 := do
  let tmp := (← IO.getEnv "TEMP").getD "."
  let stamp ← IO.monoNanosNow
  let path := s!"{tmp}\\psdsl-{stamp}.ps1"
  IO.FS.writeFile path script
  let (cmd, args) := runnerArgs path elevate
  try
    let child ← IO.Process.spawn { cmd := cmd, args := args }
    child.wait
  finally
    try IO.FS.removeFile path catch _ => pure ()

def emit (o : Opts) (prog : List Stmt) : IO UInt32 := do
  let script := render prog
  match o.get? "out" with
  | some f => IO.FS.writeFile f script; IO.eprintln s!"wrote {f}"
  | none => if !(o.has "run" || o.has "elevate") then IO.print script
  if o.has "run" || o.has "elevate" then
    runScript script (o.has "elevate")
  else
    pure 0

def runCommand (cmd : String) (o : Opts) : IO UInt32 := do
  match cmd with
  | "reg-rewrite" =>
    let n ← o.expect
    let body := rewriteReg (← o.req "key") (← o.req "name")
      (← o.req "pattern") (← o.req "replace") n
    let pre := match o.get? "require-service" with
      | some s => [requireRunning s]
      | none => []
    emit o (pre ++ body)
  | "file-replace" =>
    emit o (replaceInFile (← o.req "path") (← o.req "pattern") (← o.req "replace") (← o.expect))
  | "example" => emit o ninferProgram
  | "quote" =>
    match o.pos with
    | [t] => IO.println (quote t); pure 0
    | _ => throw (IO.userError "quote takes exactly one argument")
  | other => throw (IO.userError s!"unknown command '{other}' (try --help)")

def main (args : List String) : IO UInt32 := do
  match args with
  | [] => IO.println usage; pure 0
  | cmd :: rest =>
    if cmd == "-h" || cmd == "--help" || cmd == "help" then
      IO.println usage; pure 0
    else
      match parseOpts rest {} with
      | .error e => IO.eprintln s!"error: {e}"; pure 2
      | .ok o =>
        if o.has "help" then IO.println usage; pure 0
        else
          try runCommand cmd o
          catch e => IO.eprintln s!"error: {e}"; pure 2
