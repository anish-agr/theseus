# Lints the Windows helper scripts.
#
#   pwsh -File tools/ci/lint_powershell.ps1 [-Path tools]
#
# These scripts have branches that only execute on a machine in a
# particular broken state, so a mistake can sit in one unnoticed until
# the day you actually need it. Two checks, and it is worth being clear
# about what each one is worth:
#
#   1. Parse. Catches genuine syntax errors. It does NOT catch a
#      statement used where an expression belongs, because PowerShell
#      reads an opening paren followed by the `if` keyword as a call to
#      a command named "if" - valid syntax, CommandNotFoundException at
#      runtime. That exact mistake shipped in anisette.ps1.
#
#   2. Statement-as-expression: the narrow lint for precisely that trap.
#      Done over the token stream rather than the raw text, so comments
#      and strings that merely describe the pattern are not flagged.
#      The `$(...)` subexpression form is correct and is not flagged.
param([string]$Path = "tools")

$ErrorActionPreference = 'Stop'
$problems = 0

$K = [System.Management.Automation.Language.TokenKind]
$statementKeywords = @($K::If, $K::Foreach, $K::While, $K::Switch, $K::Do)

foreach ($file in Get-ChildItem $Path -Recurse -Filter *.ps1 | Sort-Object FullName) {
    $rel = Resolve-Path -Relative $file.FullName
    $issues = @()

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors) {
        foreach ($e in $errors) {
            $issues += "line {0}: syntax: {1}" -f `
                $e.Extent.StartLineNumber, $e.Message
        }
    }

    # A bare "(" immediately followed by a statement keyword. The
    # correct subexpression form tokenizes as DollarParen, so it never
    # matches here.
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        if ($tokens[$i].Kind -eq $K::LParen -and
            $statementKeywords -contains $tokens[$i + 1].Kind) {
            $issues += ("line {0}: '{1}' used as an expression - write " +
                "it as a subexpression or assign it to a variable first") -f `
                $tokens[$i + 1].Extent.StartLineNumber,
                $tokens[$i + 1].Text
        }
    }

    if ($issues) {
        $problems += $issues.Count
        foreach ($i in $issues) {
            Write-Host "FAIL  ${rel}: $i" -ForegroundColor Red
            Write-Host "::error file=$rel::$i"
        }
    } else {
        Write-Host "ok    $rel" -ForegroundColor Green
    }
}

Write-Host ""
if ($problems) {
    Write-Host "$problems problem(s)." -ForegroundColor Red
    exit 1
}
Write-Host "All scripts parse and are free of the statement-as-expression trap." `
    -ForegroundColor Green
