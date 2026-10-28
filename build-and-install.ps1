<#
.SYNOPSIS
    Builds File Unlocker and installs it into a permanent folder, in one step.

.DESCRIPTION
    Finds a usable .NET SDK (or downloads one), builds the project from a throwaway
    copy under the temp folder, publishes it into a staging folder, copies it to the
    install folder, verifies that the installed executable runs, and registers the
    Explorer context menu.

    The repository itself is never modified: the build always runs against a copy in
    the temp folder, which is deleted afterwards.

.PARAMETER InstallDir
    Where the tool is installed. Default: %LOCALAPPDATA%\Programs\FileUnlocker.

.PARAMETER Runtime
    Runtime identifier to publish for. win-x64 (default) or win-arm64.

.PARAMETER FrameworkDependent
    Publish without bundling the .NET runtime. Smaller output, but the matching .NET
    runtime must be installed on the machine.

.PARAMETER AllUsers
    Register the Explorer menu for all users instead of the current user. This needs
    administrator rights and triggers a UAC prompt.

.PARAMETER SkipInstall
    Build and install the files only; do not touch the context menu.

.PARAMETER Uninstall
    Remove the menu entries, delete the install folder, and stop. Never builds.

.PARAMETER NoDownload
    Never download an SDK. Fail with instructions if no usable SDK is available.

.PARAMETER SdkDir
    Where a downloaded SDK is cached and looked up.
    Default: %LOCALAPPDATA%\FileUnlockerSdk.

.PARAMETER Quiet
    Print only warnings, errors and the final summary.

.EXAMPLE
    .\build-and-install.ps1

.EXAMPLE
    .\build-and-install.ps1 -FrameworkDependent -InstallDir "$env:TEMP\FileUnlocker"

.EXAMPLE
    .\build-and-install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string] $InstallDir = "$env:LOCALAPPDATA\Programs\FileUnlocker",
    [string] $Runtime = 'win-x64',
    [switch] $FrameworkDependent,
    [switch] $AllUsers,
    [switch] $SkipInstall,
    [switch] $Uninstall,
    [switch] $NoDownload,
    [string] $SdkDir = "$env:LOCALAPPDATA\FileUnlockerSdk",
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectFile = Join-Path $RepoRoot 'FileUnlocker\FileUnlocker.csproj'
$SourceDir = Join-Path $RepoRoot 'FileUnlocker'
$MinimumSdkMajor = 8

# ---------------------------------------------------------------------------
# Output helpers. All ASCII, all prefixed, all suppressed by -Quiet.
# ---------------------------------------------------------------------------

function Write-Status {
    param([string] $Message)

    if (-not $Quiet) {
        Write-Host ("[FileUnlocker] " + $Message)
    }
}

function Write-Warn {
    param([string] $Message)

    Write-Host ("[FileUnlocker] warning: " + $Message) -ForegroundColor Yellow
}

function Write-Fail {
    param([string] $Message)

    Write-Host ("[FileUnlocker] error: " + $Message) -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Native process helper.
# ---------------------------------------------------------------------------

# Runs a native program and returns its output and exit code without ever letting
# stderr abort the script.
#
# Why this exists: this script sets $ErrorActionPreference = 'Stop', and in Windows
# PowerShell 5.1 a native command that writes anything to stderr turns into a
# terminating NativeCommandError. That killed the run on the first `dotnet publish`
# of a fresh machine, because the first-use banner and NuGet restore progress both
# go to stderr. The message on that error can even be empty, which is what produced
# an "[FileUnlocker] error:" line with no text at all.
#
# The preference is relaxed to 'Continue' only for the duration of the call, so
# stderr becomes ordinary captured text. The exit code is read immediately after the
# call, so a genuine failure is still a failure: callers must keep checking it.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $Arguments = @()
    )

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @()
    $exitCode = $null

    try {
        try {
            $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { ConvertTo-CleanLine -Line $_ })
            $exitCode = $LASTEXITCODE
        }
        catch {
            # The program could not be started at all (not found, not executable).
            # Report it the same way as a non-zero exit code so callers that only
            # check the exit code still see a failure.
            $lines = @($_.Exception.Message)
            $exitCode = -1
        }
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    # A null exit code means the program could not be started at all.
    if ($null -eq $exitCode) {
        $exitCode = -1
    }

    return [pscustomobject]@{
        Lines    = $lines
        ExitCode = $exitCode
    }
}

# The last few lines of captured output, for an error message that explains itself.
# Turns one captured stream object into a plain string.
#
# PowerShell wraps redirect-merging in ErrorRecord/RemoteException objects, and
# [string] on those appends the type name. Unwrapping the exception first keeps the
# captured output readable, which matters because it is printed and quoted in errors.
function ConvertTo-CleanLine {
    param($Line)

    if ($null -eq $Line) {
        return ''
    }

    if ($Line -is [System.Management.Automation.ErrorRecord]) {
        $exception = $Line.Exception

        if ($null -ne $exception -and $null -ne $exception.InnerException) {
            return [string] $exception.InnerException.Message
        }

        if ($null -ne $exception) {
            return [string] $exception.Message
        }
    }

    return [string] $Line
}

function Get-NativeTail {
    param(
        [string[]] $Lines,
        [int] $Count = 20
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return '(the command printed nothing)'
    }

    $tail = if ($Lines.Count -le $Count) { $Lines } else { $Lines[($Lines.Count - $Count)..($Lines.Count - 1)] }
    return (@($tail) -join "`n")
}

# ---------------------------------------------------------------------------
# SDK discovery.
# ---------------------------------------------------------------------------

# Reads the major version out of <TargetFramework>net10.0-windows</TargetFramework>.
function Get-RepoFrameworkMajor {
    $line = Select-String -Path $ProjectFile -Pattern '<TargetFramework>([^<]+)</TargetFramework>' |
        Select-Object -First 1

    if ($null -eq $line) {
        throw "Could not read <TargetFramework> from $ProjectFile."
    }

    $framework = $line.Matches[0].Groups[1].Value
    $match = [regex]::Match($framework, '^net(\d+)\.')

    if (-not $match.Success) {
        throw "Unrecognised target framework '$framework' in $ProjectFile."
    }

    return [int] $match.Groups[1].Value
}

# Returns the SDK major versions reported by one dotnet executable.
# An executable that is only a runtime host reports none, which is exactly what
# happens for a stock "C:\Program Files\dotnet\dotnet.exe" without an SDK: the
# list is empty and the exit code is still 0, so the empty list must be treated
# as "unusable" and never as success.
function Get-SdkMajorVersions {
    param([string] $DotnetPath)

    $found = @()
    $result = Invoke-Native -FilePath $DotnetPath -Arguments @('--list-sdks')

    foreach ($line in @($result.Lines)) {
        $match = [regex]::Match([string] $line, '^(\d+)\.\d+\.\d+')

        if ($match.Success) {
            $found += [int] $match.Groups[1].Value
        }
    }

    return $found
}

# Describes one candidate: whether its SDK list is usable, its best major version,
# and the framework the copy should be retargeted to.
function Test-SdkCandidate {
    param(
        [string] $DotnetPath,
        [int] $RepoMajor
    )

    $result = [ordered]@{
        Path        = $DotnetPath
        IsUsable    = $false
        BestMajor   = 0
        Framework   = $null
        Retargeted  = $false
        Reason      = ''
    }

    if ([string]::IsNullOrWhiteSpace($DotnetPath)) {
        $result.Reason = 'not found'
        return [pscustomobject] $result
    }

    if (-not (Test-Path -LiteralPath $DotnetPath)) {
        $result.Reason = 'not found'
        return [pscustomobject] $result
    }

    $majors = Get-SdkMajorVersions -DotnetPath $DotnetPath

    if ($majors.Count -eq 0) {
        $result.Reason = 'no SDK installed'
        return [pscustomobject] $result
    }

    $best = ($majors | Measure-Object -Maximum).Maximum
    $result.BestMajor = $best

    if ($best -ge $RepoMajor) {
        $result.IsUsable = $true
        $result.Framework = "net$RepoMajor.0-windows"
        $result.Reason = "SDK $best"
        return [pscustomobject] $result
    }

    if ($best -ge $MinimumSdkMajor) {
        $result.IsUsable = $true
        $result.Retargeted = $true
        $result.Framework = "net$best.0-windows"
        $result.Reason = "SDK $best (older than the project)"
        return [pscustomobject] $result
    }

    $result.Reason = "SDK $best is too old"
    return [pscustomobject] $result
}

# Applies the resolution order from the interface description.
function Resolve-Sdk {
    param(
        [int] $RepoMajor,
        [bool] $AllowDownload,
        [string] $CacheDir
    )

    $cachedDotnet = Join-Path $CacheDir 'dotnet.exe'
    $pathDotnet = $null
    $onPath = Get-Command 'dotnet' -ErrorAction SilentlyContinue

    if ($null -ne $onPath) {
        $pathDotnet = $onPath.Source
    }

    # 1. dotnet on PATH with a matching-or-newer SDK.
    $candidate = Test-SdkCandidate -DotnetPath $pathDotnet -RepoMajor $RepoMajor
    if ($candidate.IsUsable -and -not $candidate.Retargeted) {
        return $candidate
    }

    # 2. cached SDK with a matching-or-newer SDK.
    $candidate = Test-SdkCandidate -DotnetPath $cachedDotnet -RepoMajor $RepoMajor
    if ($candidate.IsUsable -and -not $candidate.Retargeted) {
        return $candidate
    }

    # 3. dotnet on PATH with any SDK >= 8, retargeting the copy.
    $candidate = Test-SdkCandidate -DotnetPath $pathDotnet -RepoMajor $RepoMajor
    if ($candidate.IsUsable) {
        return $candidate
    }

    # 4. cached SDK with any SDK >= 8, retargeting the copy.
    $candidate = Test-SdkCandidate -DotnetPath $cachedDotnet -RepoMajor $RepoMajor
    if ($candidate.IsUsable) {
        return $candidate
    }

    # 5. Download one, unless forbidden.
    if (-not $AllowDownload) {
        return $null
    }

    Write-Status ("No usable .NET SDK found. Downloading the .NET $RepoMajor.0 SDK into $CacheDir ...")

    if (-not (Install-Sdk -Channel "$RepoMajor.0" -CacheDir $CacheDir)) {
        return $null
    }

    $candidate = Test-SdkCandidate -DotnetPath $cachedDotnet -RepoMajor $RepoMajor

    if ($candidate.IsUsable) {
        return $candidate
    }

    return $null
}

function Install-Sdk {
    param(
        [string] $Channel,
        [string] $CacheDir
    )

    $script = Join-Path $env:TEMP 'FileUnlockerDotnetInstall.ps1'
    $url = 'https://dot.net/v1/dotnet-install.ps1'

    try {
        if (-not (Test-Path $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        }

        # A stricter machine may still default to an older TLS version, so modern
        # TLS is enabled explicitly, keeping whatever is already enabled.
        try {
            $enabled = [System.Net.ServicePointManager]::SecurityProtocol

            if (($enabled -band [System.Net.SecurityProtocolType]::Tls12) -eq 0) {
                [System.Net.ServicePointManager]::SecurityProtocol =
                    $enabled -bor [System.Net.SecurityProtocolType]::Tls12
            }
        }
        catch {
            # The property may be unavailable or locked down; the download below
            # still reports a clear error if the handshake then fails.
        }

        Write-Status "Downloading $url ..."

        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($url, $script)

        if (-not (Test-Path -LiteralPath $script)) {
            Write-Fail "The download of $url produced no file."
            return $false
        }

        $length = (Get-Item -LiteralPath $script).Length

        if ($length -le 0) {
            Write-Fail "The download of $url produced an empty file (0 bytes)."
            return $false
        }

        Write-Status "Downloaded $length bytes."

        Write-Status "Installing the SDK into $CacheDir ..."

        $install = Invoke-Native -FilePath 'powershell.exe' -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script,
            '-Channel', $Channel, '-InstallDir', $CacheDir, '-NoPath'
        )

        if ($install.ExitCode -ne 0) {
            Write-Fail ("The SDK installer failed with exit code " + $install.ExitCode + ".")
            Write-Host ("[FileUnlocker] last output from the SDK installer:")
            Write-Host (Get-NativeTail -Lines $install.Lines)
            return $false
        }

        return $true
    }
    catch {
        Write-Fail ("The SDK could not be downloaded: " + $_.Exception.Message)
        return $false
    }
    finally {
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }
}

function Show-ManualSdkOptions {
    Write-Host ''
    Write-Host '[FileUnlocker] No usable .NET SDK is available.'
    Write-Host '[FileUnlocker] Install one of these, then run this script again:'
    Write-Host '[FileUnlocker]   winget install Microsoft.DotNet.SDK.10'
    Write-Host '[FileUnlocker] or point at an existing SDK folder:'
    Write-Host '[FileUnlocker]   .\build-and-install.ps1 -SdkDir <an existing SDK folder>'
    Write-Host '[FileUnlocker] or allow a download into the default cache:'
    Write-Host '[FileUnlocker]   .\build-and-install.ps1'
}

# ---------------------------------------------------------------------------
# Repository safety.
# ---------------------------------------------------------------------------

function Test-IsGitRepo {
    $git = Get-Command 'git' -ErrorAction SilentlyContinue

    if ($null -eq $git) {
        return $false
    }

    return (Test-Path (Join-Path $RepoRoot '.git'))
}

function Get-RepoStatus {
    if (-not (Test-IsGitRepo)) {
        return $null
    }

    $result = Invoke-Native -FilePath 'git' -Arguments @('-C', $RepoRoot, 'status', '--porcelain')

    if ($result.ExitCode -ne 0) {
        return $null
    }

    return (@($result.Lines) -join "`n")
}

function Test-RepoUnchanged {
    param(
        [string] $Before,
        [string] $After
    )

    if ($null -eq $Before -or $null -eq $After) {
        return $true
    }

    return $Before -eq $After
}

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------

function New-BuildCopy {
    param([string] $Destination)

    Write-Status "Copying the project to $Destination ..."

    $copy = Invoke-Native -FilePath 'robocopy' -Arguments @(
        $RepoRoot, $Destination, '/MIR', '/XD', '.git', 'bin', 'obj',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    )

    # robocopy uses exit codes 0-7 for success, 8 and above for failure.
    if ($copy.ExitCode -ge 8) {
        throw ("Could not copy the project to $Destination (robocopy exit " + $copy.ExitCode + ").`n" +
            (Get-NativeTail -Lines $copy.Lines))
    }
}

function Set-CopyFramework {
    param(
        [string] $CopyRoot,
        [string] $Framework
    )

    $copyProject = Join-Path $CopyRoot 'FileUnlocker\FileUnlocker.csproj'
    $text = Get-Content -LiteralPath $copyProject -Raw
    $updated = $text -replace '<TargetFramework>[^<]+</TargetFramework>', "<TargetFramework>$Framework</TargetFramework>"

    if ($updated -eq $text) {
        return
    }

    Write-Status "Retargeting the build copy to $Framework (the repository is left untouched)."

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($copyProject, $updated, $utf8NoBom)
}

function Invoke-Publish {
    param(
        [string] $CopyRoot,
        [string] $StagingDir,
        [string] $RuntimeId,
        [bool] $SelfContained,
        [string] $DotnetPath
    )

    $copyProject = Join-Path $CopyRoot 'FileUnlocker\FileUnlocker.csproj'

    $arguments = @(
        'publish', $copyProject,
        '-c', 'Release',
        '-o', $StagingDir,
        '-r', $RuntimeId,
        '-p:DebugType=none',
        '-p:DebugSymbols=false',
        '--nologo'
    )

    if ($SelfContained) {
        $arguments += '--self-contained', 'true'
        $arguments += '-p:PublishSingleFile=true'
    }
    else {
        $arguments += '--self-contained', 'false'
    }

    Write-Status ("Publishing for $RuntimeId " + $(if ($SelfContained) { '(self-contained, single file)' } else { '(framework-dependent)' }) + ' ...')

    # Goes through Invoke-Native so that the first-use banner, NuGet restore progress
    # and any other stderr text are captured instead of aborting the script.
    $publish = Invoke-Native -FilePath $DotnetPath -Arguments $arguments

    foreach ($line in @($publish.Lines)) {
        if (-not $Quiet) {
            Write-Host ("[FileUnlocker]   " + [string] $line)
        }
    }

    if ($publish.ExitCode -ne 0) {
        throw ("dotnet publish failed with exit code " + $publish.ExitCode + ". Last output:`n" +
            (Get-NativeTail -Lines $publish.Lines))
    }
}

function Complete-Staging {
    param([string] $StagingDir)

    foreach ($name in @('FileUnlocker.exe', 'install.bat', 'remove.bat', 'key.ico')) {
        $target = Join-Path $StagingDir $name

        if (Test-Path -LiteralPath $target) {
            continue
        }

        $source = Join-Path $SourceDir $name

        if (-not (Test-Path -LiteralPath $source)) {
            throw "Neither the publish output nor the source folder contains $name."
        }

        Write-Status "Publish output had no $name; taking it from the project folder."
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

# Every file name one of our installs is expected to contain.
$InstallFileNames = @('FileUnlocker.exe', 'install.bat', 'remove.bat', 'key.ico')

# Decides whether a folder may be mirrored into (which prunes unknown files).
#
# IsOurs is true only when the folder holds FileUnlocker.exe and every entry in it is
# one of our own install files. A folder that also holds anything else is never
# pruned, so user data that happens to live next to an install is not deleted.
function Get-OwnInstallFileState {
    param([string] $Target)

    $state = [ordered]@{
        HasExe = $false
        IsOurs = $false
    }

    if (-not (Test-Path -LiteralPath $Target)) {
        return [pscustomobject] $state
    }

    $state.HasExe = Test-Path -LiteralPath (Join-Path $Target 'FileUnlocker.exe')

    if (-not $state.HasExe) {
        return [pscustomobject] $state
    }

    try {
        $entries = @(Get-ChildItem -LiteralPath $Target -Force)
    }
    catch {
        # An unreadable folder is never mirrored into.
        return [pscustomobject] $state
    }

    foreach ($entry in $entries) {
        if ($InstallFileNames -notcontains $entry.Name) {
            return [pscustomobject] $state
        }
    }

    $state.IsOurs = $true
    return [pscustomobject] $state
}

function Install-Files {
    param(
        [string] $StagingDir,
        [string] $Target
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        Write-Status "Creating $Target ..."
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    # Mirroring prunes stale files, but it also deletes anything in the destination
    # that is not part of the build. That is only acceptable when the destination
    # holds nothing except one of our own installs, so the folder is checked to
    # contain our executable and no foreign files. A folder that also holds anything
    # else is copied into without deleting, which keeps user data safe.
    $ours = Get-OwnInstallFileState -Target $Target
    $copyArguments = @($StagingDir, $Target)

    if ($ours.IsOurs) {
        Write-Status "Updating the existing install in $Target (stale files are removed) ..."
        $copyArguments += '/MIR'
    }
    else {
        Write-Status "Installing into $Target ..."

        if ($ours.HasExe) {
            Write-Status 'The folder already holds a FileUnlocker install together with other files, so nothing is deleted.'
        }
        else {
            Write-Status 'The folder is not an existing install, so files are copied in without deleting anything already there.'
        }

        $copyArguments += '/E'
    }

    $copyArguments += @('/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $copy = Invoke-Native -FilePath 'robocopy' -Arguments $copyArguments

    # robocopy uses exit codes 0-7 for success, 8 and above for failure.
    if ($copy.ExitCode -ge 8) {
        throw ("Could not copy the build into $Target (robocopy exit " + $copy.ExitCode + ").`n" +
            (Get-NativeTail -Lines $copy.Lines))
    }
}

function Test-PublishedExe {
    param(
        [string] $Target,
        [bool] $FrameworkDependentBuild,
        [string] $What = 'the executable'
    )

    $exe = Join-Path $Target 'FileUnlocker.exe'

    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Fail "The executable was not found at $exe."
        return $false
    }

    # The executable is a GUI-subsystem app, so PowerShell's call operator does not
    # wait for it and returns no output. cmd.exe waits, and its exit code and stdout
    # are reliable, so the check goes through cmd.
    $verify = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', ('"' + $exe + '" -version'))

    $text = (@($verify.Lines) -join ' ')
    Write-Status ("Verifying " + $What + ": " + $text.Trim())

    if ($verify.ExitCode -eq 0 -and $text -like '*1.2.0*') {
        return $true
    }

    Write-Fail ("The executable did not report version 1.2.0 (exit code " + $verify.ExitCode + ").")

    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-Host '[FileUnlocker] last output from the executable:'
        Write-Host (Get-NativeTail -Lines $verify.Lines)
    }

    if ($FrameworkDependentBuild) {
        Write-Host '[FileUnlocker] This build is framework-dependent, so it needs the matching .NET runtime on this machine.'
        Write-Host '[FileUnlocker] Re-run without -FrameworkDependent to get a self-contained install.'
    }

    return $false
}

# ---------------------------------------------------------------------------
# Context menu.
# ---------------------------------------------------------------------------

function Test-IsElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Invoke-MenuScript {
    param(
        [string] $Target,
        [string] $ScriptName,
        [bool] $ForAllUsers
    )

    $script = Join-Path $Target $ScriptName

    if (-not (Test-Path -LiteralPath $script)) {
        Write-Fail "$ScriptName was not found in $Target."
        return $false
    }

    $arguments = @('/c', ('"' + $script + '"'))

    if ($ForAllUsers) {
        $arguments += '/allusers'
    }

    $menu = Invoke-Native -FilePath 'cmd.exe' -Arguments $arguments

    foreach ($line in @($menu.Lines)) {
        Write-Status ([string] $line)
    }

    if ($menu.ExitCode -ne 0) {
        Write-Fail "$ScriptName exited with code $($menu.ExitCode)."
        return $false
    }

    return $true
}

# Runs one menu script elevated through a UAC prompt.
function Invoke-MenuScriptElevated {
    param(
        [string] $Target,
        [string] $ScriptName,
        [bool] $ForAllUsers
    )

    $script = Join-Path $Target $ScriptName
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command') +
        @('& cmd.exe /c "\"' + $script + '\""' + $(if ($ForAllUsers) { ' /allusers' } else { '' }))

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        return ($process.ExitCode -eq 0)
    }
    catch {
        Write-Fail "Elevation was refused or failed: " + $_.Exception.Message
        return $false
    }
}

function Register-Menu {
    param(
        [string] $Target,
        [bool] $ForAllUsers
    )

    if (-not $ForAllUsers) {
        Write-Status 'Registering the Explorer context menu for the current user ...'
        return (Invoke-MenuScript -Target $Target -ScriptName 'install.bat' -ForAllUsers $false)
    }

    if (Test-IsElevated) {
        Write-Status 'Registering the Explorer context menu for all users ...'
        return (Invoke-MenuScript -Target $Target -ScriptName 'install.bat' -ForAllUsers $true)
    }

    Write-Status 'Registering for all users needs administrator rights; a UAC prompt will appear.'

    if (Invoke-MenuScriptElevated -Target $Target -ScriptName 'install.bat' -ForAllUsers $true) {
        Write-Status 'The menu was registered for all users.'
        return $true
    }

    Write-Fail 'The menu was not registered for all users.'
    return $false
}

function Unregister-Menu {
    param(
        [string] $Target,
        [bool] $ForAllUsers
    )

    if (-not $ForAllUsers) {
        Write-Status 'Removing the Explorer context menu for the current user ...'
        return (Invoke-MenuScript -Target $Target -ScriptName 'remove.bat' -ForAllUsers $false)
    }

    if (Test-IsElevated) {
        Write-Status 'Removing the Explorer context menu for all users ...'
        return (Invoke-MenuScript -Target $Target -ScriptName 'remove.bat' -ForAllUsers $true)
    }

    Write-Status 'Removing the entries for all users needs administrator rights; a UAC prompt will appear.'

    if (Invoke-MenuScriptElevated -Target $Target -ScriptName 'remove.bat' -ForAllUsers $true) {
        Write-Status 'The menu entries for all users were removed.'
        return $true
    }

    Write-Fail 'The menu entries for all users were not removed.'
    return $false
}

# ---------------------------------------------------------------------------
# Uninstall.
# ---------------------------------------------------------------------------

# True when $Child is $Parent or lives underneath it.
function Test-IsSameOrChildPath {
    param(
        [string] $Child,
        [string] $Parent
    )

    if ([string]::IsNullOrWhiteSpace($Parent)) {
        return $false
    }

    $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')

    if ($c -eq $p) {
        return $true
    }

    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Refuses an install folder that must never be mirrored into or deleted.
#
# This runs before anything destructive, because both the install step (a mirroring
# copy that prunes stale files) and the uninstall step (a recursive delete) would
# otherwise be able to damage a system or data folder.
#
# Refused: a drive or share root, the repository, the temp folder, well-known
# profile and system folders, and anything fewer than two levels below its root.
function Assert-SafeInstallDir {
    param([string] $Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Fail '-InstallDir is empty. Use the default folder instead.'
        return $false
    }

    $full = $null

    try {
        $full = [System.IO.Path]::GetFullPath($Target)
    }
    catch {
        Write-Fail "-InstallDir '$Target' is not a valid path."
        return $false
    }

    $normalized = $full.TrimEnd('\', '/')

    # A drive root or a share root, such as C:\ or \\server\share.
    $root = [System.IO.Path]::GetPathRoot($full)

    if (-not [string]::IsNullOrEmpty($root) -and
        ([string]::Equals($normalized, $root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase))) {
        Write-Fail "-InstallDir '$full' is a drive or share root, so installing there would touch the whole volume."
        Write-Host "[FileUnlocker] Use the default folder instead: $env:LOCALAPPDATA\Programs\FileUnlocker"
        return $false
    }

    # The repository, or the temp folder, or anything containing them.
    if ((Test-IsSameOrChildPath -Child $RepoRoot -Parent $full) -or
        (Test-IsSameOrChildPath -Child $env:TEMP -Parent $full)) {
        Write-Fail "-InstallDir '$full' would contain the repository or the temp folder, so a mirroring copy or a delete could remove your sources."
        Write-Host "[FileUnlocker] Use the default folder instead: $env:LOCALAPPDATA\Programs\FileUnlocker"
        return $false
    }

    # Anything inside the temp folder is scratch space: Windows or the user can clear
    # it at any time, so the install would not survive, and a delete there is hard to
    # reason about.
    if (Test-IsSameOrChildPath -Child $full -Parent $env:TEMP) {
        Write-Fail "-InstallDir '$full' is inside the temp folder, which can be cleared at any time, so the install would not last."
        Write-Host "[FileUnlocker] Use the default folder instead: $env:LOCALAPPDATA\Programs\FileUnlocker"
        return $false
    }

    # Well-known system and personal folders.
    $protected = @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:TEMP,
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:SystemDrive,
        ($env:HOMEDRIVE + $env:HOMEPATH),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )

    foreach ($candidate in $protected) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            $candidateFull = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        }
        catch {
            continue
        }

        if ([string]::Equals($normalized, $candidateFull, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Fail "-InstallDir '$full' is a system or personal folder, so installing there would mix the tool with other files."
            Write-Host "[FileUnlocker] Use the default folder instead: $env:LOCALAPPDATA\Programs\FileUnlocker"
            return $false
        }
    }

    # Nothing directly under a drive root: C:\FileUnlocker is refused, C:\Tools\FileUnlocker is fine.
    $rootTrimmed = if ([string]::IsNullOrEmpty($root)) { '' } else { $root.TrimEnd('\', '/') }
    $relative = $normalized

    if (-not [string]::IsNullOrEmpty($rootTrimmed) -and
        $normalized.StartsWith($rootTrimmed, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $normalized.Substring($rootTrimmed.Length)
    }

    $levels = @($relative.Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' })

    if ($levels.Count -lt 2) {
        Write-Fail "-InstallDir '$full' is too close to the root of the drive, which is never a good place for an install folder."
        Write-Host "[FileUnlocker] Use the default folder instead: $env:LOCALAPPDATA\Programs\FileUnlocker"
        return $false
    }

    return $true
}

function Invoke-Uninstall {
    param(
        [string] $Target,
        [bool] $ForAllUsers
    )

    # Before anything destructive: this function ends in a recursive delete.
    if (-not (Assert-SafeInstallDir -Target $Target)) {
        return 1
    }

    $exists = Test-Path -LiteralPath $Target

    if (-not $exists) {
        Write-Status "Nothing is installed in $Target; there is nothing to do."
        Write-SummaryLine 'uninstall' 'nothing to do'
        return 0
    }

    $menuOk = $true
    $menuWhere = 'skipped'

    if (Test-Path -LiteralPath (Join-Path $Target 'remove.bat')) {
        if ($ForAllUsers -and -not (Test-IsElevated)) {
            $menuWhere = 'all users (elevated)'
        }
        elseif ($ForAllUsers) {
            $menuWhere = 'all users'
        }
        else {
            $menuWhere = 'current user'
        }

        $menuOk = Unregister-Menu -Target $Target -ForAllUsers $ForAllUsers
    }
    else {
        Write-Warn "remove.bat was not found in $Target, so the menu entries were left alone."

        if ($ForAllUsers) {
            $menuWhere = 'all users (elevated)'
            $menuOk = Unregister-Menu -Target $Target -ForAllUsers $true
        }
    }

    Write-Status "Deleting $Target ..."

    try {
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Fail "Could not delete $Target : " + $_.Exception.Message
        return 1
    }

    if (-not (Test-Path -LiteralPath $Target)) {
        Write-Status 'The install folder was removed.'
    }

    if (-not $menuOk) {
        Write-Fail 'The install folder was removed, but the menu entries could not be fully removed.'
        return 1
    }

    Write-Host ''
    Write-Host '[FileUnlocker] uninstalled.'
    Write-Host "[FileUnlocker] install folder:  $Target (deleted)"
    Write-Host "[FileUnlocker] menu:            $menuWhere"
    Write-Host '[FileUnlocker] next steps:      nothing to do.'
    return 0
}

function Write-SummaryLine {
    param(
        [string] $Kind,
        [string] $Detail
    )

    Write-Host ''
    Write-Host ("[FileUnlocker] " + $Kind + ': ' + $Detail)
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

$tempCopy = $null
$staging = $null
$repoStatusBefore = $null
$script:exitCode = 0

try {
    Write-Status 'File Unlocker build and install'
    Write-Status "Repository: $RepoRoot"

    if (-not (Test-Path -LiteralPath $ProjectFile)) {
        throw "FileUnlocker.csproj was not found under $RepoRoot. Run this script from the repository."
    }

    # Taken before anything can exit, so the finally block always has a baseline.
    $repoStatusBefore = Get-RepoStatus

    if ($null -ne $repoStatusBefore) {
        Write-Status 'Snapshotting git status to prove the repository is untouched.'
    }

    # -----------------------------------------------------------------------
    # Uninstall never builds, so it does not need an SDK.
    # -----------------------------------------------------------------------
    if ($Uninstall) {
        # exit (not return) so the code is honoured; the finally block still runs.
        exit (Invoke-Uninstall -Target $InstallDir -ForAllUsers $AllUsers)
    }

    if ($Runtime -ne 'win-x64' -and $Runtime -ne 'win-arm64') {
        Write-Fail "-Runtime '$Runtime' is not supported. Use win-x64 or win-arm64."
        exit 1
    }

    $repoMajor = Get-RepoFrameworkMajor
    Write-Status "The project targets net$repoMajor.0-windows."

    $allowDownload = -not $NoDownload

    if ($NoDownload) {
        Write-Status '-NoDownload was given, so no SDK will be fetched.'
    }

    $sdk = Resolve-Sdk -RepoMajor $repoMajor -AllowDownload $allowDownload -CacheDir $SdkDir

    if ($null -eq $sdk) {
        Show-ManualSdkOptions
        exit 1
    }

    Write-Status ("Using " + $sdk.Reason + " at " + $sdk.Path)

    if ($sdk.Retargeted) {
        Write-Warn "This SDK is older than the project (net$repoMajor.0). Only the throwaway build copy is retargeted to $($sdk.Framework); the repository is not modified."
    }

    # -----------------------------------------------------------------------
    # Build from a throwaway copy.
    # -----------------------------------------------------------------------
    $tempRoot = Join-Path $env:TEMP ('FileUnlockerBuild_' + [System.Guid]::NewGuid().ToString('N'))
    $tempCopy = Join-Path $tempRoot 'src'
    $staging = Join-Path $tempRoot 'out'

    New-Item -ItemType Directory -Path $tempCopy -Force | Out-Null
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    New-BuildCopy -Destination $tempCopy

    if ($null -ne $sdk.Framework) {
        Set-CopyFramework -CopyRoot $tempCopy -Framework $sdk.Framework
    }

    Invoke-Publish -CopyRoot $tempCopy -StagingDir $staging -RuntimeId $Runtime `
        -SelfContained (-not $FrameworkDependent) -DotnetPath $sdk.Path

    Complete-Staging -StagingDir $staging

    # Confirm the copy's framework matches what the SDK said it used.
    $copyFramework = (Select-String -Path (Join-Path $tempCopy 'FileUnlocker\FileUnlocker.csproj') `
        -Pattern '<TargetFramework>([^<]+)</TargetFramework>').Matches[0].Groups[1].Value
    Write-Status "Built with target framework $copyFramework."

    # The install folder is about to receive files, so it must be safe first.
    if (-not (Assert-SafeInstallDir -Target $InstallDir)) {
        exit 1
    }

    # Prove the build runs BEFORE touching the install folder, so a build that cannot
    # start (a missing runtime for a framework-dependent build, for example) leaves
    # nothing half-installed behind.
    if (-not (Test-PublishedExe -Target $staging -FrameworkDependentBuild $FrameworkDependent.IsPresent `
            -What 'the build in the staging folder')) {
        Write-Status 'Nothing was installed.'
        exit 1
    }

    Install-Files -StagingDir $staging -Target $InstallDir

    # Final confirmation that the copy in the install folder runs too.
    if (-not (Test-PublishedExe -Target $InstallDir -FrameworkDependentBuild $FrameworkDependent.IsPresent `
            -What 'the installed executable')) {
        exit 1
    }

    # -----------------------------------------------------------------------
    # Register the menu.
    # -----------------------------------------------------------------------
    $menuWhere = 'skipped'

    if ($SkipInstall) {
        Write-Status '-SkipInstall was given, so the context menu was not touched.'
        $menuWhere = 'skipped'
    }
    else {
        if (-not (Register-Menu -Target $InstallDir -ForAllUsers $AllUsers.IsPresent)) {
            exit 1
        }

        $menuWhere = $(if ($AllUsers) { 'all users' } else { 'current user' })
    }

    $selfContained = -not $FrameworkDependent.IsPresent

    Write-Host ''
    Write-Host '[FileUnlocker] done.'
    Write-Host "[FileUnlocker] install folder:  $InstallDir"
    Write-Host "[FileUnlocker] framework:       $copyFramework"
    Write-Host ("[FileUnlocker] self-contained:  " + $selfContained)
    Write-Host "[FileUnlocker] menu:            $menuWhere"
    Write-Host '[FileUnlocker] next steps:'

    if ($menuWhere -eq 'skipped') {
        Write-Host "[FileUnlocker]   The context menu was not registered; run $InstallDir\install.bat when you want it."
    }
    else {
        Write-Host '[FileUnlocker]   Right-click a file or a folder in Explorer and choose Unlock.'
    }

    Write-Host "[FileUnlocker]   Command line: `"$InstallDir\FileUnlocker.exe`" `"C:\data\report.docx`""
    Write-Host "[FileUnlocker]   Silent mode:  `"$InstallDir\FileUnlocker.exe`" -silent `"C:\data`""
    Write-Host '[FileUnlocker]   Exit codes:   0 nothing locked or all closed, 1 usage, 2 not found,'
    Write-Host '[FileUnlocker]                 3 nothing could be closed, 4 still locked, 5 cancelled, 6 error.'
    Write-Host "[FileUnlocker]   To remove it: .\build-and-install.ps1 -Uninstall"

    $script:exitCode = 0
}
catch {
    # Never print an empty error: a native-command failure can carry an empty message,
    # so fall back to the exception type and the position instead of a bare "error:".
    $message = $_.Exception.Message

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $_.Exception.GetType().Name + ' with no message'
    }

    Write-Fail $message

    $inner = $_.Exception.InnerException

    if ($null -ne $inner -and -not [string]::IsNullOrWhiteSpace($inner.Message)) {
        Write-Host ("[FileUnlocker] caused by: " + $inner.GetType().Name + ': ' + $inner.Message)
    }

    if (-not $Quiet) {
        Write-Host ("[FileUnlocker] at " + $_.InvocationInfo.PositionMessage.Trim())
    }

    $script:exitCode = 1
}
finally {
    if ($null -ne $tempCopy) {
        $tempRoot = Split-Path -Parent $tempCopy

        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $repoStatusAfter = Get-RepoStatus

    if (-not (Test-RepoUnchanged -Before $repoStatusBefore -After $repoStatusAfter)) {
        Write-Warn 'The repository changed during this run. This is not expected; please report it.'
        Write-Host '[FileUnlocker] before:'
        Write-Host $repoStatusBefore
        Write-Host '[FileUnlocker] after:'
        Write-Host $repoStatusAfter
    }
    elseif ($null -ne $repoStatusBefore) {
        if (-not $Quiet) {
            Write-Host '[FileUnlocker] The repository is unchanged.'
        }
    }
}

# Only the script-scoped variable is meaningful here: earlier early exits set it and
# returned, so the finally block above ran and this single place decides the code.
exit $script:exitCode
