# Regression test for FileUnlocker.exe.
#
# Runs the executable the way Explorer and a script would, checks the documented
# exit codes and output lines, and proves that a locked file can be freed both by
# passing the file and by passing its parent folder.
#
# Requirements: Windows PowerShell 5.1, no modules, no administrator rights.
# It does not touch the registry, and it kills only the holder processes it starts.
#
# Not covered here: the interactive dialog path. Answering No in the confirmation
# box needs UI automation, so that is verified manually. The -silent flag is used
# everywhere below precisely because it avoids any dialog.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Exe,

    [switch] $KeepTemp
)

$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:FailCount = 0
$script:Holders = New-Object System.Collections.ArrayList
$script:SubstDrive = $null

function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)

    if ($Ok) {
        $script:PassCount++
        Write-Host ("PASS  {0}" -f $Name)
    }
    else {
        $script:FailCount++
        Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
        if ($Detail) {
            Write-Host ("      {0}" -f $Detail) -ForegroundColor Red
        }
    }
}

# Quotes one argument the way the C runtime expects it, so an argument that
# contains spaces or a trailing backslash survives intact.
function ConvertTo-CommandLineArgument {
    param([string] $Argument)

    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void] $builder.Append('"')
    $backslashes = 0

    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            # Escape the run of backslashes, then the quote itself.
            [void] $builder.Append('\' * (($backslashes * 2) + 1))
            [void] $builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void] $builder.Append('\' * $backslashes)
            $backslashes = 0
        }

        [void] $builder.Append($ch)
    }

    # Backslashes before the closing quote must be doubled.
    if ($backslashes -gt 0) {
        [void] $builder.Append('\' * ($backslashes * 2))
    }

    [void] $builder.Append('"')
    return $builder.ToString()
}

# Runs the executable with redirection, never through a shell.
# ProcessStartInfo.ArgumentList does not exist in Windows PowerShell 5.1, so the
# command line is built by hand.
function Invoke-Exe {
    param([string[]] $Arguments)

    if ($null -eq $Arguments) {
        $Arguments = @()
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:ExePath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $script:TempDir
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')

    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

# Starts a hidden PowerShell that holds a file open until it is killed.
# The share mode is ReadWrite so that a second holder (the protected fixture) can
# open the same file; with FileShare.None the later opener would fail instead of
# being reported as a second locker.
function Start-Holder {
    param([string] $Path)

    $escaped = $Path.Replace("'", "''")
    $scriptText = "`$f = [System.IO.File]::Open('$escaped', 'Open', 'ReadWrite', 'ReadWrite'); Write-Output 'ready'; Start-Sleep -Seconds 600"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptText)
    $encoded = [System.Convert]::ToBase64String($bytes)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true

    $process = [System.Diagnostics.Process]::Start($info)

    # Wait until the holder reports that it really has the handle open. The first
    # lines can carry a CLIXML banner, so read until the marker or the stream ends.
    $ready = Test-HolderReady -Process $process
    if (-not $ready) {
        try { $process.Kill() } catch { }
        return $null
    }

    [void] $script:Holders.Add($process)
    return $process
}

# Reads the holder's standard output until it reports readiness.
function Test-HolderReady {
    param([System.Diagnostics.Process] $Process)

    for ($i = 0; $i -lt 20; $i++) {
        $line = $Process.StandardOutput.ReadLine()

        if ($null -eq $line) {
            return $false
        }

        if ($line -match 'ready') {
            return $true
        }
    }

    return $false
}

# Starts the same kind of holder from a COPY of the running PowerShell executable
# renamed to one of the protected image names, so the protection check can be
# exercised. This is legitimate test scaffolding: the guard under test is by image
# name, the process is our own copy, it opens the file with FileShare.ReadWrite so a
# second holder can join, and it is started and killed entirely inside this test's
# temp folder. Nothing outside the temp folder is touched.
#
# Returns $null when the copy cannot be created or the fixture does not report ready.
function Start-ProtectedFixture {
    param([string] $Path, [string] $ImageName)

    try {
        $self = (Get-Process -Id $PID).Path
        $fixture = Join-Path $script:TempDir $ImageName
        Copy-Item -LiteralPath $self -Destination $fixture -Force

        $escaped = $Path.Replace("'", "''")
        # ReadWrite sharing is what lets the normal holder open the same file, which
        # is what the Restart Manager reports as two lockers.
        $scriptText = "`$f = [System.IO.File]::Open('$escaped', 'Open', 'ReadWrite', 'ReadWrite'); Write-Output 'ready'; Start-Sleep -Seconds 600"
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptText))

        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $fixture
        $info.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true

        $process = [System.Diagnostics.Process]::Start($info)

        if (-not (Test-HolderReady -Process $process)) {
            try { $process.Kill() } catch { }
            return $null
        }

        [void] $script:Holders.Add($process)
        return $process
    }
    catch {
        return $null
    }
}

# Runs the executable without redirection and returns only the exit code, used where
# the output is irrelevant.
function Get-ExitCode {
    param([string[]] $Arguments)

    return (Invoke-Exe -Arguments $Arguments).ExitCode
}

function Stop-Holders {
    foreach ($holder in $script:Holders) {
        try {
            if (-not $holder.HasExited) {
                $holder.Kill()
                [void] $holder.WaitForExit(3000)
            }
        }
        catch {
            # Already gone.
        }
        finally {
            $holder.Dispose()
        }
    }

    $script:Holders.Clear()
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host ("error: '{0}' was not found." -f $Exe) -ForegroundColor Red
    exit 1
}

$script:ExePath = (Resolve-Path -LiteralPath $Exe).Path
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("FileUnlockerSmoke_" + [System.Guid]::NewGuid().ToString('N'))
[void] (New-Item -ItemType Directory -Path $script:TempDir)

Write-Host ("Testing {0}" -f $script:ExePath)
Write-Host ("Temp    {0}" -f $script:TempDir)
Write-Host ""

try {
    $plainFile = Join-Path $script:TempDir "plain.txt"
    [System.IO.File]::WriteAllText($plainFile, "hello")

    $dashFile = Join-Path $script:TempDir "-dashed.txt"
    [System.IO.File]::WriteAllText($dashFile, "hello")

    $subDir = Join-Path $script:TempDir "sub"
    [void] (New-Item -ItemType Directory -Path $subDir)
    $lockedFile = Join-Path $subDir "locked.txt"
    [System.IO.File]::WriteAllText($lockedFile, "hello")

    $missingPath = Join-Path $script:TempDir "does-not-exist.txt"

    # -----------------------------------------------------------------------
    # 1. No arguments
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @()
    Write-Result ($r.ExitCode -eq 1) "no args returns 1" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match 'error:') "no args writes a usage error to stderr" ("stderr={0}" -f $r.StdErr.Trim())
    Write-Result ($r.StdErr -notmatch 'Unhandled|Exception') "no args leaks no exception text" ("stderr={0}" -f $r.StdErr.Trim())

    # -----------------------------------------------------------------------
    # 2. Help and version
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-help')
    Write-Result ($r.ExitCode -eq 0) "-help returns 0" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdOut -match 'Usage:') "-help writes usage to stdout" ("stdout length={0}" -f $r.StdOut.Length)
    Write-Result ($r.StdOut -match 'Exit codes:') "-help documents exit codes" ""

    $r = Invoke-Exe -Arguments @('-version')
    Write-Result ($r.ExitCode -eq 0) "-version returns 0" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdOut -match 'FileUnlocker: \d+\.\d+\.\d+') "-version prints the version on stdout" ("stdout={0}" -f $r.StdOut.Trim())

    # -----------------------------------------------------------------------
    # 3. Usage errors
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-nope', $plainFile)
    Write-Result ($r.ExitCode -eq 1) "unknown option returns 1" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match "unknown option '-nope'") "unknown option names the option" ("stderr={0}" -f $r.StdErr.Trim())

    $r = Invoke-Exe -Arguments @($plainFile, $dashFile)
    Write-Result ($r.ExitCode -eq 1) "two paths returns 1" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match 'unexpected argument') "two paths reports the extra argument" ("stderr={0}" -f $r.StdErr.Trim())

    # -----------------------------------------------------------------------
    # 4. Nonexistent path
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-silent', $missingPath)
    Write-Result ($r.ExitCode -eq 2) "missing path returns 2" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match 'does not exist or is not accessible') "missing path explains itself" ("stderr={0}" -f $r.StdErr.Trim())
    Write-Result ($r.StdOut -notmatch 'result: nothing locked') "missing path never claims nothing locked" ("stdout={0}" -f $r.StdOut.Trim())

    # -----------------------------------------------------------------------
    # 5. Unlocked file
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-silent', $plainFile)
    Write-Result ($r.ExitCode -eq 0) "unlocked file returns 0" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdOut -match 'result: nothing locked') "unlocked file reports nothing locked" ("stdout={0}" -f $r.StdOut.Trim())
    Write-Result ($r.StdOut -match 'unlocking ') "unlocked file prints the full path" ("stdout={0}" -f $r.StdOut.Trim())

    # -----------------------------------------------------------------------
    # 6. Locked file, -silent before the path
    # -----------------------------------------------------------------------
    $holder = Start-Holder -Path $lockedFile
    $r = Invoke-Exe -Arguments @('-silent', $lockedFile)
    Write-Result ($r.ExitCode -eq 0) "locked file is unlocked with exit 0" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdOut -match '1 locking process\(es\)') "locked file reports the locking process" ("stdout={0}" -f $r.StdOut.Trim())
    Write-Result ($r.StdOut -match 'killed ') "locked file reports a kill" ("stdout={0}" -f $r.StdOut.Trim())
    Write-Result ($r.StdOut -match 'result: unlocked') "locked file ends with unlocked" ("stdout={0}" -f $r.StdOut.Trim())

    $holderGone = $false
    try {
        $holderGone = $holder.HasExited
    }
    catch {
        $holderGone = $true
    }
    Write-Result $holderGone "the holder process really died" "holder still running"

    # A dialog would block forever in silent mode; reaching here proves there was none.
    Write-Result ($r.StdErr -notmatch 'error:') "silent run writes nothing to stderr" ("stderr={0}" -f $r.StdErr.Trim())

    # -----------------------------------------------------------------------
    # 7. Locked file inside a subfolder, unlocked by passing the parent folder
    # -----------------------------------------------------------------------
    [System.IO.File]::WriteAllText($lockedFile, "hello again")
    $holder = Start-Holder -Path $lockedFile
    $r = Invoke-Exe -Arguments @('-silent', $script:TempDir)
    Write-Result ($r.ExitCode -eq 0) "folder unlock returns 0" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdOut -match 'killed ') "folder unlock finds the file in the subfolder" ("stdout={0}" -f $r.StdOut.Trim())
    Write-Result ($r.StdOut -match 'result: unlocked') "folder unlock ends with unlocked" ("stdout={0}" -f $r.StdOut.Trim())

    # -----------------------------------------------------------------------
    # 8. -- ends option parsing
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('--', $dashFile)
    Write-Result ($r.ExitCode -eq 0) "dash-prefixed path is treated as a path" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -notmatch 'unknown option') "dash-prefixed path is not a usage error" ("stderr={0}" -f $r.StdErr.Trim())

    $r = Invoke-Exe -Arguments @('--', '-definitely-not-here.txt')
    Write-Result ($r.ExitCode -eq 2) "missing dash-prefixed path returns 2, not 1" ("exit={0}" -f $r.ExitCode)

    # -----------------------------------------------------------------------
    # 9. Extra argument after --
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('--', $plainFile, $dashFile)
    Write-Result ($r.ExitCode -eq 1) "a second positional after -- returns 1" ("exit={0}" -f $r.ExitCode)

    # -----------------------------------------------------------------------
    # 10. Drive roots are refused (regression guard for the drive-wide scan)
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-silent', '/')
    Write-Result ($r.ExitCode -eq 1) "-silent / returns 1" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match 'drive root') "-silent / explains that it is a drive root" ("stderr={0}" -f $r.StdErr.Trim())
    Write-Result ($r.StdOut -notmatch 'unlocking') "-silent / never starts unlocking" ("stdout={0}" -f $r.StdOut.Trim())

    $r = Invoke-Exe -Arguments @('-silent', '\')
    Write-Result ($r.ExitCode -eq 1) "-silent \ returns 1" ("exit={0}" -f $r.ExitCode)

    $r = Invoke-Exe -Arguments @('-silent', 'C:\')
    Write-Result ($r.ExitCode -eq 1) "-silent C:\ returns 1" ("exit={0}" -f $r.ExitCode)

    # A spare drive letter is mapped onto the test's own temp folder, so a regression
    # can only ever scan this tiny tree and never a real volume.
    $substDrive = $null
    foreach ($letter in @('Q', 'R', 'T', 'U', 'V', 'W')) {
        $candidate = $letter + ':'
        if (-not (Test-Path ($candidate + '\'))) {
            $null = & subst.exe $candidate $script:TempDir 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path ($candidate + '\'))) {
                $substDrive = $candidate
                $script:SubstDrive = $candidate
                break
            }
        }
    }

    if ($null -eq $substDrive) {
        Write-Host "SKIP  subst drive root refusal (subst is unavailable)"
    }
    else {
        $r = Invoke-Exe -Arguments @('-silent', ($substDrive + '\'))
        Write-Result ($r.ExitCode -eq 1) ("subst {0}\ returns 1" -f $substDrive) ("exit={0}" -f $r.ExitCode)
        Write-Result ($r.StdErr -match 'drive root') ("subst {0}\ is refused as a drive root" -f $substDrive) ("stderr={0}" -f $r.StdErr.Trim())
        Write-Result ($r.StdOut -notmatch 'unlocking') ("subst {0}\ never starts unlocking" -f $substDrive) ("stdout={0}" -f $r.StdOut.Trim())
    }

    # -----------------------------------------------------------------------
    # 11. Option classification (regression guard for the '-'/'/' rule)
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('--silent=1')
    Write-Result ($r.ExitCode -eq 1) "--silent=1 returns 1" ("exit={0}" -f $r.ExitCode)
    Write-Result ($r.StdErr -match 'unknown option') "--silent=1 is an unknown option" ("stderr={0}" -f $r.StdErr.Trim())

    $r = Invoke-Exe -Arguments @('-')
    Write-Result ($r.ExitCode -eq 1) "a lone - returns 1" ("exit={0}" -f $r.ExitCode)

    $r = Invoke-Exe -Arguments @('/silent', $plainFile)
    Write-Result ($r.ExitCode -eq 0) "/silent still works as an option" ("exit={0}" -f $r.ExitCode)

    $unixLike = "/definitely-not-here-" + [System.Guid]::NewGuid().ToString('N')
    $r = Invoke-Exe -Arguments @($unixLike)
    Write-Result ($r.ExitCode -eq 2) "an unknown /name is treated as a path, not an option" ("exit={0}" -f $r.ExitCode)

    # -----------------------------------------------------------------------
    # 12. Version string
    # -----------------------------------------------------------------------
    $r = Invoke-Exe -Arguments @('-version')
    Write-Result ($r.StdOut.Trim() -eq 'FileUnlocker: 1.2.0') "-version prints exactly 'FileUnlocker: 1.2.0'" ("stdout={0}" -f $r.StdOut.Trim())

    # -----------------------------------------------------------------------
    # 13. Protected process: the item stays locked and the tool must say so
    # -----------------------------------------------------------------------
    $protectedFile = Join-Path $script:TempDir "protected.txt"
    [System.IO.File]::WriteAllText($protectedFile, "hello")

    $fixture = Start-ProtectedFixture -Path $protectedFile -ImageName "LogonUI.exe"

    if ($null -eq $fixture) {
        Write-Host "SKIP  protected-only assertions (the fixture could not be started)"
    }
    else {
        $r = Invoke-Exe -Arguments @('-silent', $protectedFile)
        Write-Result ($r.StdOut -match 'protected system process') "protected-only reports the skip" ("stdout={0}" -f $r.StdOut.Trim())
        Write-Result ($r.StdOut -match 'result: still locked \(1 process\(es\)\)') "protected-only reports it is still locked" ("stdout={0}" -f $r.StdOut.Trim())
        Write-Result ($r.StdOut -notmatch 'result: unlocked') "protected-only never claims unlocked" ("stdout={0}" -f $r.StdOut.Trim())
        Write-Result ($r.ExitCode -eq 3) "protected-only returns 3" ("exit={0}" -f $r.ExitCode)

        $fixtureAlive = $false
        try { $fixtureAlive = -not $fixture.HasExited } catch { $fixtureAlive = $false }
        Write-Result $fixtureAlive "the protected fixture is still alive" "the fixture was killed"

        # -------------------------------------------------------------------
        # 14. Protected plus killable: the normal holder dies, the item stays
        #     locked, and the exit code must be 4, not 0. This is the
        #     regression guard for the post-kill identity check.
        # -------------------------------------------------------------------
        $normalHolder = Start-Holder -Path $protectedFile

        if ($null -eq $normalHolder) {
            Write-Result $false "protected plus killable could start a normal holder" "the holder did not start"
        }
        else {
            $r = Invoke-Exe -Arguments @('-silent', $protectedFile)
            Write-Result ($r.StdOut -match 'killed ') "protected plus killable kills the normal holder" ("stdout={0}" -f $r.StdOut.Trim())
            Write-Result ($r.StdOut -match 'result: still locked \(1 process\(es\)\)') "protected plus killable reports still locked" ("stdout={0}" -f $r.StdOut.Trim())
            Write-Result ($r.StdOut -notmatch 'result: unlocked') "protected plus killable never claims unlocked" ("stdout={0}" -f $r.StdOut.Trim())
            Write-Result ($r.ExitCode -eq 4) "protected plus killable returns 4" ("exit={0}" -f $r.ExitCode)

            $normalDead = $false
            try { $normalDead = $normalHolder.HasExited } catch { $normalDead = $true }
            Write-Result $normalDead "the normal holder really died" "the normal holder is still running"

            $fixtureAlive = $false
            try { $fixtureAlive = -not $fixture.HasExited } catch { $fixtureAlive = $false }
            Write-Result $fixtureAlive "the protected fixture survived the run" "the protected fixture was killed"
        }
    }
}
finally {
    Stop-Holders

    if ($script:SubstDrive) {
        try { $null = & subst.exe $script:SubstDrive /d 2>&1 } catch { }
    }

    if ($KeepTemp) {
        Write-Host ("Keeping {0}" -f $script:TempDir)
    }
    else {
        try {
            Remove-Item -Recurse -Force -LiteralPath $script:TempDir -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host ("note: could not remove {0}" -f $script:TempDir)
        }
    }
}

Write-Host ""
Write-Host ("Passed {0}, failed {1}" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -gt 0) {
    exit 1
}

exit 0
