Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:EwspResolvedEnvironment = $null
$script:EwspKubernetesContext = 'docker-desktop'
$script:EwspKubernetesNamespace = 'ewsp'

function Invoke-EwspNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkingDirectory
    )

    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Pop-Location }
        $ErrorActionPreference = $previousErrorPreference
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-EwspNativeStreaming {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$FailureMessage = 'Command failed.'
    )

    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $FilePath @ArgumentList
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Pop-Location }
    }
    if ($exitCode -ne 0) {
        $exception = New-Object System.Exception("$FailureMessage (exit code $exitCode)")
        $exception.Data['ExitCode'] = $exitCode
        $exception.Data['Operation'] = "$FilePath $($ArgumentList -join ' ')"
        throw $exception
    }
}

function Invoke-EwspGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $gitPath = if ($script:EwspResolvedEnvironment -and $script:EwspResolvedEnvironment.Git.FilePath) {
        $script:EwspResolvedEnvironment.Git.FilePath
    } else { 'git' }
    Invoke-EwspNative -FilePath $gitPath -ArgumentList (@('-C', $RepositoryPath) + $Arguments)
}

function Get-EwspNormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-EwspPathsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    [string]::Equals(
        (Get-EwspNormalizedPath $Left),
        (Get-EwspNormalizedPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function ConvertTo-EwspRemoteIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $value = $RemoteUrl.Trim()
    if (-not $value) { return $null }

    if ($value.StartsWith('local:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $localPath = $value.Substring(6)
        return 'local:' + (Get-EwspNormalizedPath $localPath).ToLowerInvariant()
    }

    $githubPath = $null
    if ($value -match '^(?:[^@]+@)?github\.com:(?<path>.+)$') {
        $githubPath = $Matches.path
    } elseif ($value -match '^github\.com/(?<path>.+)$') {
        $githubPath = $Matches.path
    } else {
        $uri = $null
        if ([System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri) -and
            $uri.Host -and $uri.Host.Equals('github.com', [System.StringComparison]::OrdinalIgnoreCase)) {
            $githubPath = $uri.AbsolutePath.Trim('/')
        }
    }

    if ($githubPath) {
        $githubPath = $githubPath.Trim('/').TrimEnd('/')
        if ($githubPath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
            $githubPath = $githubPath.Substring(0, $githubPath.Length - 4)
        }
        $parts = @($githubPath.Split('/') | Where-Object { $_ })
        if ($parts.Count -eq 2) {
            return ("github.com/{0}/{1}" -f $parts[0], $parts[1]).ToLowerInvariant()
        }
        return $null
    }

    $fileUri = $null
    if ([System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$fileUri) -and $fileUri.IsFile) {
        return 'local:' + (Get-EwspNormalizedPath $fileUri.LocalPath).ToLowerInvariant()
    }
    if ([System.IO.Path]::IsPathRooted($value)) {
        return 'local:' + (Get-EwspNormalizedPath $value).ToLowerInvariant()
    }

    $fallback = $value.TrimEnd('/')
    if ($fallback.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $fallback = $fallback.Substring(0, $fallback.Length - 4)
    }
    return $fallback.ToLowerInvariant()
}

function Resolve-EwspRepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Repository
    )
    $workspaceRoot = Split-Path -Parent (Get-EwspNormalizedPath $LocalRoot)
    Get-EwspNormalizedPath (Join-Path $workspaceRoot $Repository.Directory)
}

function Test-EwspRepositoryIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$ExpectedIdentity
    )

    $expected = ConvertTo-EwspRemoteIdentity $ExpectedIdentity
    if (-not (Test-Path -LiteralPath $RepositoryPath)) {
        return [PSCustomObject]@{
            Exists = $false; IsDirectory = $false; IsGit = $false; RootMatches = $false
            IdentityMatches = $false; ExpectedIdentity = $expected; MatchingRemote = $null
            RemoteUrls = @(); Error = 'Directory is missing.'
        }
    }
    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        return [PSCustomObject]@{
            Exists = $true; IsDirectory = $false; IsGit = $false; RootMatches = $false
            IdentityMatches = $false; ExpectedIdentity = $expected; MatchingRemote = $null
            RemoteUrls = @(); Error = 'Expected path exists but is not a directory.'
        }
    }

    $inside = Invoke-EwspGit $RepositoryPath @('rev-parse', '--is-inside-work-tree')
    if ($inside.ExitCode -ne 0 -or ($inside.Output -join '').Trim() -ne 'true') {
        return [PSCustomObject]@{
            Exists = $true; IsDirectory = $true; IsGit = $false; RootMatches = $false
            IdentityMatches = $false; ExpectedIdentity = $expected; MatchingRemote = $null
            RemoteUrls = @(); Error = 'Directory is not a Git working tree.'
        }
    }

    $rootResult = Invoke-EwspGit $RepositoryPath @('rev-parse', '--show-toplevel')
    $root = ($rootResult.Output -join '').Trim()
    $rootMatches = $rootResult.ExitCode -eq 0 -and (Test-EwspPathsEqual $root $RepositoryPath)
    if (-not $rootMatches) {
        return [PSCustomObject]@{
            Exists = $true; IsDirectory = $true; IsGit = $true; RootMatches = $false
            IdentityMatches = $false; ExpectedIdentity = $expected; MatchingRemote = $null
            RemoteUrls = @(); Error = "Git root '$root' does not equal the expected directory."
        }
    }

    $remoteNames = Invoke-EwspGit $RepositoryPath @('remote')
    $urls = @()
    $matchingRemote = $null
    foreach ($remoteName in $remoteNames.Output) {
        if (-not $remoteName) { continue }
        $remoteUrls = Invoke-EwspGit $RepositoryPath @('remote', 'get-url', '--all', $remoteName)
        foreach ($url in $remoteUrls.Output) {
            if (-not $url) { continue }
            $identity = ConvertTo-EwspRemoteIdentity $url
            $urls += [PSCustomObject]@{ Remote = $remoteName; Url = $url; Identity = $identity }
            if ($identity -and $identity -eq $expected -and -not $matchingRemote) {
                $matchingRemote = $remoteName
            }
        }
    }

    $matches = [bool]$matchingRemote
    [PSCustomObject]@{
        Exists = $true; IsDirectory = $true; IsGit = $true; RootMatches = $true
        IdentityMatches = $matches; ExpectedIdentity = $expected; MatchingRemote = $matchingRemote
        RemoteUrls = $urls
        Error = if ($matches) { $null } else { "No configured remote matches '$expected'." }
    }
}

function Get-EwspRepositoryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$ExpectedIdentity,
        [Parameter(Mandatory = $true)][string]$ExpectedBranch,
        [switch]$Fetch
    )

    $identity = Test-EwspRepositoryIdentity $RepositoryPath $ExpectedIdentity
    if (-not $identity.Exists) {
        return [PSCustomObject]@{
            Path = $RepositoryPath; Presence = 'missing'; Identity = 'missing'; Branch = $null
            Commit = $null; ShortCommit = $null; Dirty = $false; Upstream = $null
            UpstreamRemote = $null; UpstreamIdentityMatches = $null
            Ahead = $null; Behind = $null; FetchError = $null; StatusError = $null; Classification = 'MISSING'
            IdentityDetail = $identity
        }
    }
    if (-not $identity.IdentityMatches) {
        return [PSCustomObject]@{
            Path = $RepositoryPath; Presence = 'present'; Identity = 'mismatch'; Branch = $null
            Commit = $null; ShortCommit = $null; Dirty = $false; Upstream = $null
            UpstreamRemote = $null; UpstreamIdentityMatches = $null
            Ahead = $null; Behind = $null; FetchError = $null; StatusError = $null; Classification = 'IDENTITY_MISMATCH'
            IdentityDetail = $identity
        }
    }

    $fetchError = $null
    if ($Fetch) {
        $fetchResult = Invoke-EwspGit $RepositoryPath @('fetch', '--quiet', '--all')
        if ($fetchResult.ExitCode -ne 0) { $fetchError = ($fetchResult.Output -join ' ').Trim() }
    }

    $commitResult = Invoke-EwspGit $RepositoryPath @('rev-parse', 'HEAD')
    $commit = if ($commitResult.ExitCode -eq 0) { ($commitResult.Output -join '').Trim() } else { $null }
    $shortCommit = if ($commit -and $commit.Length -ge 7) { $commit.Substring(0, 7) } else { $commit }

    $branchResult = Invoke-EwspGit $RepositoryPath @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $detached = $branchResult.ExitCode -ne 0
    $branch = if ($detached) { $null } else { ($branchResult.Output -join '').Trim() }

    $statusResult = Invoke-EwspGit $RepositoryPath @('status', '--porcelain=v1', '--untracked-files=all')
    $statusError = if ($statusResult.ExitCode -ne 0) { ($statusResult.Output -join ' ').Trim() } else { $null }
    # A failed status check must never allow a clean-image tag or an automatic update.
    $dirty = $statusResult.ExitCode -ne 0 -or $statusResult.Output.Count -gt 0

    $upstreamResult = Invoke-EwspGit $RepositoryPath @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $upstream = if ($upstreamResult.ExitCode -eq 0) { ($upstreamResult.Output -join '').Trim() } else { $null }
    $upstreamRemote = $null
    $upstreamIdentityMatches = $null
    if ($upstream -and $branch) {
        $remoteResult = Invoke-EwspGit $RepositoryPath @('config', '--get', "branch.$branch.remote")
        if ($remoteResult.ExitCode -eq 0) {
            $upstreamRemote = ($remoteResult.Output -join '').Trim()
        }
        if ($upstreamRemote) {
            $upstreamIdentityMatches = [bool]@($identity.RemoteUrls | Where-Object {
                $_.Remote -eq $upstreamRemote -and $_.Identity -eq $identity.ExpectedIdentity
            }).Count
        } else {
            $upstreamIdentityMatches = $false
        }
    }
    $ahead = $null
    $behind = $null
    if ($upstream) {
        $countResult = Invoke-EwspGit $RepositoryPath @('rev-list', '--left-right', '--count', "HEAD...$upstream")
        if ($countResult.ExitCode -eq 0) {
            $parts = @(($countResult.Output -join ' ').Trim() -split '\s+')
            if ($parts.Count -ge 2) {
                $ahead = [int]$parts[0]
                $behind = [int]$parts[1]
            }
        }
    }

    $classes = @()
    if ($dirty) { $classes += 'DIRTY' }
    if ($statusError) { $classes += 'STATUS_FAILED' }
    if ($detached) { $classes += 'DETACHED' }
    elseif ($branch -ne $ExpectedBranch) { $classes += 'WRONG_BRANCH' }
    if (-not $upstream) { $classes += 'NO_UPSTREAM' }
    elseif ($null -ne $ahead -and $null -ne $behind) {
        if ($ahead -eq 0 -and $behind -eq 0) { $classes += 'UP_TO_DATE' }
        elseif ($ahead -eq 0 -and $behind -gt 0) { $classes += 'BEHIND' }
        elseif ($ahead -gt 0 -and $behind -eq 0) { $classes += 'AHEAD' }
        else { $classes += 'DIVERGED' }
    }
    if ($upstream -and -not $upstreamIdentityMatches) { $classes += 'UPSTREAM_IDENTITY_MISMATCH' }
    if ($fetchError) { $classes += 'FETCH_FAILED' }

    [PSCustomObject]@{
        Path = $RepositoryPath; Presence = 'present'; Identity = 'verified'; Branch = $branch
        Commit = $commit; ShortCommit = $shortCommit; Dirty = $dirty; Upstream = $upstream
        UpstreamRemote = $upstreamRemote; UpstreamIdentityMatches = $upstreamIdentityMatches
        Ahead = $ahead; Behind = $behind; FetchError = $fetchError; StatusError = $statusError
        Classification = ($classes -join ' + '); IdentityDetail = $identity
    }
}

function Ensure-EwspRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Repository
    )

    $path = Resolve-EwspRepositoryPath $LocalRoot $Repository
    if (Test-Path -LiteralPath $path) {
        $identity = Test-EwspRepositoryIdentity $path $Repository.ExpectedIdentity
        if (-not $identity.IdentityMatches) {
            throw "$path exists but does not match $($Repository.ExpectedIdentity). $($identity.Error) No files were changed."
        }
        return [PSCustomObject]@{ Name = $Repository.Name; Path = $path; Action = 'Reused' }
    }

    $workspaceRoot = Split-Path -Parent (Get-EwspNormalizedPath $LocalRoot)
    if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
        throw "Workspace directory does not exist: $workspaceRoot"
    }
    Write-Host "Cloning $($Repository.Name) into $path ..."
    Invoke-EwspNativeStreaming -FilePath 'git' -ArgumentList @(
        'clone', '--origin', 'origin', '--branch', $Repository.PrimaryBranch,
        '--', $Repository.CloneUrl, $path
    ) -WorkingDirectory $workspaceRoot -FailureMessage "Clone failed for $($Repository.Name)"

    $verified = Test-EwspRepositoryIdentity $path $Repository.ExpectedIdentity
    if (-not $verified.IdentityMatches) {
        throw "The clone completed but repository identity verification failed for $path."
    }
    [PSCustomObject]@{ Name = $Repository.Name; Path = $path; Action = 'Cloned' }
}

function Update-EwspRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)]$Repository
    )

    $state = Get-EwspRepositoryState -RepositoryPath $RepositoryPath `
        -ExpectedIdentity $Repository.ExpectedIdentity -ExpectedBranch $Repository.PrimaryBranch -Fetch

    if ($state.Classification -eq 'MISSING' -or $state.Classification -eq 'IDENTITY_MISMATCH') {
        return [PSCustomObject]@{ Result = 'SKIPPED'; Reason = $state.Classification; State = $state }
    }
    $safeBehindOnly = -not $state.Dirty -and -not $state.StatusError -and -not $state.FetchError -and
        $state.Branch -eq $Repository.PrimaryBranch -and $state.Upstream -and
        $state.UpstreamIdentityMatches -and $state.Ahead -eq 0 -and $state.Behind -gt 0

    if ($safeBehindOnly) {
        Write-Host "Fast-forwarding $($Repository.Name) from $($state.Upstream) ..."
        $merge = Invoke-EwspGit $RepositoryPath @('merge', '--ff-only', $state.Upstream)
        if ($merge.ExitCode -ne 0) {
            throw "Fast-forward failed for $($Repository.Name): $($merge.Output -join ' ')"
        }
        $updated = Get-EwspRepositoryState -RepositoryPath $RepositoryPath `
            -ExpectedIdentity $Repository.ExpectedIdentity -ExpectedBranch $Repository.PrimaryBranch
        return [PSCustomObject]@{ Result = 'UPDATED'; Reason = 'Fast-forwarded'; State = $updated }
    }

    if (-not $state.Dirty -and $state.Ahead -eq 0 -and $state.Behind -eq 0 -and
        -not $state.StatusError -and -not $state.FetchError -and
        $state.Branch -eq $Repository.PrimaryBranch -and $state.Upstream -and
        $state.UpstreamIdentityMatches) {
        return [PSCustomObject]@{ Result = 'UNCHANGED'; Reason = 'Already up to date'; State = $state }
    }

    return [PSCustomObject]@{ Result = 'SKIPPED'; Reason = $state.Classification; State = $state }
}

function Get-EwspHostPlatform {
    $platform = $null
    if ($PSVersionTable.ContainsKey('Platform') -and $PSVersionTable.Platform) {
        $platform = [string]$PSVersionTable.Platform
    }

    $isWindows = $false
    $isLinux = $false
    $isMacOS = $false
    try {
        $isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows
        )
        $isLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Linux
        )
        $isMacOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX
        )
    } catch {
        $isWindows = $env:OS -eq 'Windows_NT'
    }

    $name = if ($isWindows) { 'Windows' } elseif ($isLinux) { 'Linux' } elseif ($isMacOS) { 'macOS' } else { 'Unknown' }
    $description = $null
    try { $description = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription } catch { }
    if (-not $description) { $description = [Environment]::OSVersion.VersionString }

    if ($isWindows) {
        try {
            $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $release = if ($windows.DisplayVersion) { $windows.DisplayVersion } else { $windows.ReleaseId }
            $edition = if ($windows.EditionID) { " $($windows.EditionID)" } else { '' }
            $description = "Windows$edition $release (build $($windows.CurrentBuildNumber))".Trim()
        } catch { }
    }

    $architecture = $null
    try { $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }

    [PSCustomObject]@{
        Name = $name
        Description = $description
        Version = [Environment]::OSVersion.Version.ToString()
        Architecture = $architecture
        PowerShellEdition = [string]$PSVersionTable.PSEdition
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellPlatform = $platform
        PowerShellHost = $Host.Name
    }
}

function Get-EwspDetectedVersion {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    if ($Result.ExitCode -ne 0) { return $null }
    $value = ($Result.Output -join ' ').Trim()
    $match = [regex]::Match($value, $Pattern)
    if (-not $match.Success) { return $null }
    $match.Groups['version'].Value
}

function Get-EwspRuntimeEnvironment {
    [CmdletBinding()]
    param(
        [scriptblock]$CommandResolver,
        [scriptblock]$CommandRunner
    )

    if (-not $CommandResolver) {
        $CommandResolver = { param($name) Get-Command $name -ErrorAction SilentlyContinue }
    }
    if (-not $CommandRunner) {
        $CommandRunner = { param($filePath, $arguments) Invoke-EwspNative $filePath $arguments }
    }

    $hostPlatform = Get-EwspHostPlatform
    $gitCommand = & $CommandResolver 'git'
    $gitAvailable = $null -ne $gitCommand
    $gitResult = if ($gitAvailable) { & $CommandRunner 'git' @('--version') } else { $null }
    $gitVersion = if ($gitResult) { Get-EwspDetectedVersion $gitResult '^git version (?<version>\S+)$' } else { $null }

    $dockerCommand = & $CommandResolver 'docker'
    $dockerAvailable = $null -ne $dockerCommand
    $dockerCliResult = if ($dockerAvailable) { & $CommandRunner 'docker' @('--version') } else { $null }
    $dockerCliVersion = if ($dockerCliResult) {
        Get-EwspDetectedVersion $dockerCliResult '^Docker version (?<version>[^,\s]+),'
    } else { $null }
    $engineResult = if ($dockerAvailable) {
        & $CommandRunner 'docker' @('version', '--format', '{{.Server.Version}}')
    } else { $null }
    $engineVersion = if ($engineResult -and $engineResult.ExitCode -eq 0) {
        ($engineResult.Output -join '').Trim()
    } else { $null }

    $compose = $null
    $composePrimaryResult = $null
    $composeLegacyResult = $null
    if ($dockerAvailable) {
        $composePrimaryResult = & $CommandRunner 'docker' @('compose', 'version', '--short')
        if ($composePrimaryResult.ExitCode -eq 0) {
            $version = Get-EwspDetectedVersion $composePrimaryResult '^(?<version>v?\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?)$'
            if ($version) {
                $compose = [PSCustomObject]@{
                    Available = $true; FilePath = 'docker'; PrefixArguments = @('compose')
                    DisplayName = 'docker compose'; Version = $version; Implementation = 'plugin'
                }
            }
        }
    }
    if (-not $compose) {
        $legacyCommand = & $CommandResolver 'docker-compose'
        if ($legacyCommand) {
            $composeLegacyResult = & $CommandRunner 'docker-compose' @('version', '--short')
            if ($composeLegacyResult.ExitCode -eq 0) {
                $version = Get-EwspDetectedVersion $composeLegacyResult '^(?<version>v?\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?)$'
                if ($version) {
                    $compose = [PSCustomObject]@{
                        Available = $true; FilePath = 'docker-compose'; PrefixArguments = @()
                        DisplayName = 'docker-compose'; Version = $version; Implementation = 'legacy'
                    }
                }
            }
        }
    }
    if (-not $compose) {
        $compose = [PSCustomObject]@{
            Available = $false; FilePath = $null; PrefixArguments = @()
            DisplayName = $null; Version = $null; Implementation = $null
        }
    }

    $environment = [PSCustomObject]@{
        Platform = $hostPlatform
        Git = [PSCustomObject]@{
            Available = $gitAvailable; FilePath = 'git'; Version = $gitVersion
            ProbeExitCode = if ($gitResult) { $gitResult.ExitCode } else { $null }
        }
        Docker = [PSCustomObject]@{
            Available = $dockerAvailable; FilePath = 'docker'; CliVersion = $dockerCliVersion
            CliProbeExitCode = if ($dockerCliResult) { $dockerCliResult.ExitCode } else { $null }
            EngineReachable = [bool]($engineResult -and $engineResult.ExitCode -eq 0 -and $engineVersion)
            EngineVersion = $engineVersion
            EngineProbeExitCode = if ($engineResult) { $engineResult.ExitCode } else { $null }
        }
        Compose = $compose
    }
    $script:EwspResolvedEnvironment = $environment
    $environment
}

function Protect-EwspDiagnosticText {
    param(
        [AllowNull()][string]$Text,
        [hashtable]$EnvironmentValues
    )
    if ($null -eq $Text) { return '' }
    $safeText = [regex]::Replace(
        $Text,
        '(?i)(PASSWORD|SECRET|TOKEN|ACCESS_KEY|PRIVATE_KEY)(\s*[:=]\s*)([^\s,;]+)',
        '$1$2<redacted>'
    )
    if ($EnvironmentValues) {
        $sensitiveNames = @($EnvironmentValues.Keys | Where-Object {
            $_ -match '(?i)(PASSWORD|SECRET|TOKEN|ACCESS_KEY|PRIVATE_KEY)'
        })
        foreach ($name in $sensitiveNames) {
            $value = [string]$EnvironmentValues[$name]
            if (-not [string]::IsNullOrEmpty($value)) {
                $safeText = [regex]::Replace($safeText, [regex]::Escape($value), '<redacted>')
            }
        }
    }
    $safeText
}

function Format-EwspEnvironmentSummary {
    param([Parameter(Mandatory = $true)]$EnvironmentInfo)
    $compose = if ($EnvironmentInfo.Compose.Available) {
        "$($EnvironmentInfo.Compose.DisplayName) $($EnvironmentInfo.Compose.Version)"
    } else { 'unavailable' }
    $parts = @(
        "OS: $($EnvironmentInfo.Platform.Description) [$($EnvironmentInfo.Platform.Architecture)]"
        "PowerShell: $($EnvironmentInfo.Platform.PowerShellEdition) $($EnvironmentInfo.Platform.PowerShellVersion)"
        "Git: $(if ($EnvironmentInfo.Git.Version) { $EnvironmentInfo.Git.Version } else { 'unavailable' })"
        "Docker CLI: $(if ($EnvironmentInfo.Docker.CliVersion) { $EnvironmentInfo.Docker.CliVersion } else { 'unavailable' })"
        "Docker Engine: $(if ($EnvironmentInfo.Docker.EngineVersion) { $EnvironmentInfo.Docker.EngineVersion } else { 'unreachable' })"
        "Compose: $compose"
    )
    if ($EnvironmentInfo.PSObject.Properties.Name -contains 'Kubernetes') {
        $kubernetes = $EnvironmentInfo.Kubernetes
        $parts += "kubectl: $(if ($kubernetes.ClientVersion) { $kubernetes.ClientVersion } else { 'unavailable' })"
        $parts += "Kubernetes context: $(if ($kubernetes.Context) { $kubernetes.Context } else { 'unavailable' })"
        $parts += "Kubernetes server: $(if ($kubernetes.ServerVersion) { $kubernetes.ServerVersion } else { 'unreachable' })"
    }
    $parts -join '; '
}

function Assert-EwspPrerequisites {
    [CmdletBinding()]
    param(
        [switch]$RequireDocker,
        $EnvironmentInfo
    )
    if (-not $EnvironmentInfo) { $EnvironmentInfo = Get-EwspRuntimeEnvironment }
    if ([Version]$EnvironmentInfo.Platform.PowerShellVersion -lt [Version]'5.1') {
        throw 'Prerequisite missing: PowerShell 5.1 or newer is required.'
    }
    if (-not $EnvironmentInfo.Git.Available) {
        throw 'Prerequisite missing: Git is not installed or is not available on PATH.'
    }
    if (-not $EnvironmentInfo.Git.Version) {
        throw 'Prerequisite detection failed: git --version returned an unrecognized result.'
    }
    if ($RequireDocker) {
        if (-not $EnvironmentInfo.Docker.Available) {
            throw 'Prerequisite missing: Docker CLI is not installed or is not available on PATH. Install Docker Desktop/Engine and retry.'
        }
        if (-not $EnvironmentInfo.Docker.CliVersion) {
            throw 'Prerequisite detection failed: docker --version returned an unrecognized result.'
        }
        if (-not $EnvironmentInfo.Compose.Available) {
            throw 'Unsupported Compose: neither docker compose nor docker-compose passed capability probing.'
        }
        if (-not $EnvironmentInfo.Docker.EngineReachable) {
            throw 'Docker Engine not running: the Docker CLI exists, but the server is not reachable. Start Docker Desktop/Engine and retry.'
        }
    }
    $EnvironmentInfo
}

function Invoke-EwspCompose {
    param(
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $composeFile = Join-Path $LocalRoot 'compose.yml'
    $allArguments = @($EnvironmentInfo.Compose.PrefixArguments) + @('-f', $composeFile) + $Arguments
    Invoke-EwspNative $EnvironmentInfo.Compose.FilePath $allArguments $LocalRoot
}

function Invoke-EwspComposeStreaming {
    param(
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    $composeFile = Join-Path $LocalRoot 'compose.yml'
    $allArguments = @($EnvironmentInfo.Compose.PrefixArguments) + @('-f', $composeFile) + $Arguments
    Invoke-EwspNativeStreaming $EnvironmentInfo.Compose.FilePath $allArguments $LocalRoot $FailureMessage
}

function Get-EwspConfiguration {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $configPath = Join-Path $LocalRoot 'config\repositories.psd1'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Repository configuration is missing: $configPath"
    }
    Import-PowerShellDataFile -LiteralPath $configPath
}

function Ensure-EwspEnvironmentFile {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $envPath = Join-Path $LocalRoot '.env'
    $examplePath = Join-Path $LocalRoot '.env.example'
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw '.env.example is missing.'
    }
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        Write-Host '.env already exists; preserving it.'
    } else {
        Copy-Item -LiteralPath $examplePath -Destination $envPath
        Write-Host 'Created .env from .env.example. Review local credentials before sharing the machine.'
    }
    $ignored = Invoke-EwspGit $LocalRoot @('check-ignore', '--quiet', '--', '.env')
    if ($ignored.ExitCode -ne 0) { throw '.env exists but is not ignored by Git. Refusing to continue.' }
}

function Read-EwspEnvironmentFile {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $values = @{}
    $envPath = Join-Path $LocalRoot '.env'
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
    $values
}

function Get-EwspEffectiveEnvironmentValues {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $values = Read-EwspEnvironmentFile $LocalRoot
    $knownNames = @(
        @($values.Keys) + @(
            'COMPOSE_PROJECT_NAME', 'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD',
            'POSTGRES_HOST_PORT', 'REDIS_HOST_PORT', 'MINIO_ROOT_USER', 'MINIO_ROOT_PASSWORD',
            'MINIO_BUCKET_NAME', 'MINIO_API_HOST_PORT', 'MINIO_CONSOLE_HOST_PORT',
            'BACKEND_HOST_PORT', 'SPRING_PROFILES_ACTIVE', 'JWT_SECRET',
            'EWSP_CORS_ALLOWED_ORIGINS', 'DASHBOARD_HOST_PORT'
        )
    ) | Sort-Object -Unique
    foreach ($name in $knownNames) {
        $processValue = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $processValue) { $values[$name] = $processValue }
    }
    $values
}

function Get-EwspConfiguredPorts {
    param([Parameter(Mandatory = $true)][hashtable]$EnvironmentValues)
    $definitions = @(
        @{ Name = 'Dashboard'; Service = 'dashboard'; ContainerPort = 80; EnvironmentName = 'DASHBOARD_HOST_PORT'; Default = 3000 },
        @{ Name = 'Backend'; Service = 'backend'; ContainerPort = 8080; EnvironmentName = 'BACKEND_HOST_PORT'; Default = 8080 },
        @{ Name = 'PostgreSQL'; Service = 'postgres'; ContainerPort = 5432; EnvironmentName = 'POSTGRES_HOST_PORT'; Default = 5432 },
        @{ Name = 'Redis'; Service = 'redis'; ContainerPort = 6379; EnvironmentName = 'REDIS_HOST_PORT'; Default = 6379 },
        @{ Name = 'MinIO API'; Service = 'minio'; ContainerPort = 9000; EnvironmentName = 'MINIO_API_HOST_PORT'; Default = 9000 },
        @{ Name = 'MinIO console'; Service = 'minio'; ContainerPort = 9001; EnvironmentName = 'MINIO_CONSOLE_HOST_PORT'; Default = 9001 }
    )
    @($definitions | ForEach-Object {
        $rawValue = if ($EnvironmentValues.ContainsKey($_.EnvironmentName)) {
            [string]$EnvironmentValues[$_.EnvironmentName]
        } else { [string]$_.Default }
        $port = 0
        if (-not [int]::TryParse($rawValue, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw "Invalid .env configuration: $($_.EnvironmentName) must be an integer from 1 through 65535."
        }
        [PSCustomObject]@{
            Name = $_.Name; Service = $_.Service; ContainerPort = $_.ContainerPort
            EnvironmentName = $_.EnvironmentName; Port = $port
        }
    })
}

function Assert-EwspEnvironmentConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$EnvironmentValues)
    $required = @(
        'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD',
        'MINIO_ROOT_USER', 'MINIO_ROOT_PASSWORD', 'MINIO_BUCKET_NAME', 'JWT_SECRET'
    )
    $missing = @($required | Where-Object {
        -not $EnvironmentValues.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$_])
    })
    if ($missing.Count -gt 0) {
        throw "Invalid/missing .env configuration: required setting names are missing or empty: $($missing -join ', '). Secret values were not printed."
    }

    if (-not $EnvironmentValues.ContainsKey('EWSP_CORS_ALLOWED_ORIGINS') -or
        [string]::IsNullOrWhiteSpace([string]$EnvironmentValues['EWSP_CORS_ALLOWED_ORIGINS'])) {
        throw 'Invalid/missing .env configuration: EWSP_CORS_ALLOWED_ORIGINS is missing or empty.'
    }

    $ports = @(Get-EwspConfiguredPorts $EnvironmentValues)
    $duplicates = @($ports | Group-Object Port | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        $detail = @($duplicates | ForEach-Object {
            "port $($_.Name) ($((@($_.Group | ForEach-Object Name)) -join ', '))"
        }) -join '; '
        throw "Invalid .env configuration: multiple EWSP services use the same host $detail."
    }
    $ports
}

function Get-EwspOccupiedTcpPorts {
    try {
        @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
            ForEach-Object Port | Sort-Object -Unique)
    } catch {
        throw "Port preflight could not inspect active TCP listeners: $($_.Exception.Message)"
    }
}

function Get-EwspProjectPublishedPorts {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][object[]]$PortConfiguration
    )
    $ports = @()
    foreach ($definition in $PortConfiguration) {
        $result = Invoke-EwspCompose $EnvironmentInfo $LocalRoot @(
            'port', $definition.Service, [string]$definition.ContainerPort
        )
        if ($result.ExitCode -ne 0) { continue }
        foreach ($line in $result.Output) {
            $match = [regex]::Match($line.Trim(), ':(?<port>\d+)$')
            if ($match.Success) { $ports += [int]$match.Groups['port'].Value }
        }
    }
    @($ports | Sort-Object -Unique)
}

function Assert-EwspPortAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$PortConfiguration,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$OccupiedPorts,
        [AllowEmptyCollection()][int[]]$ProjectPorts = @()
    )
    $conflicts = @($PortConfiguration | Where-Object {
        $_.Port -in $OccupiedPorts -and $_.Port -notin $ProjectPorts
    })
    if ($conflicts.Count -gt 0) {
        $detail = @($conflicts | ForEach-Object { "$($_.Name) requires host port $($_.Port)" }) -join '; '
        $exception = New-Object System.Exception(
            "Port collision detected: $detail. The port is in use outside the current EWSP Compose project. Stop or reconfigure the external listener, or change the matching *_HOST_PORT value in .env. No process was stopped."
        )
        $exception.Data['Category'] = 'PORT_COLLISION'
        $exception.Data['Component'] = ($conflicts.Name -join ', ')
        throw $exception
    }
    $true
}

function Invoke-EwspPortPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][object[]]$PortConfiguration
    )
    $occupied = @(Get-EwspOccupiedTcpPorts)
    $projectPorts = @(Get-EwspProjectPublishedPorts $LocalRoot $EnvironmentInfo $PortConfiguration)
    Assert-EwspPortAvailability $PortConfiguration $occupied $projectPorts | Out-Null
    [PSCustomObject]@{ OccupiedPorts = $occupied; ProjectPorts = $projectPorts }
}

function Get-EwspBuildInputHash {
    param(
        [Parameter(Mandatory = $true)]$ImageConfiguration,
        [Parameter(Mandatory = $true)][hashtable]$EnvironmentValues
    )
    $components = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($ImageConfiguration.BuildInputs | Sort-Object)) {
        $value = if ($EnvironmentValues.ContainsKey($name)) { [string]$EnvironmentValues[$name] } else { '' }
        $components.Add("input:$name=$value")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($components -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    $hash.Substring(0, 12)
}

function Assert-EwspApplicationBuildAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)]$Repository
    )

    foreach ($relativePath in @($Repository.Image.RequiredBuildFiles)) {
        $path = Join-Path $RepositoryPath $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$($Repository.Name) is missing required application-owned Docker asset '$relativePath' at '$path'. Run .\ewsp.ps1 update if the checkout is clean and behind, or update the sibling checkout manually. ewsp-local will not fall back to an orchestration-owned Dockerfile."
        }
    }
}

function Get-EwspImageDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Repository,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][hashtable]$EnvironmentValues,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    $image = $Repository.Image
    $buildInputHash = Get-EwspBuildInputHash $image $EnvironmentValues
    if ($State.Dirty) {
        $tag = "{0}:dirty-{1}-{2}" -f $image.RepositoryName, $State.ShortCommit, $SessionId
        $reusable = $false
    } else {
        $sourceHash = $State.Commit.Substring(0, 12)
        $tag = "{0}:{1}-{2}" -f $image.RepositoryName, $sourceHash, $buildInputHash
        $reusable = $true
    }
    [PSCustomObject]@{
        Service = $image.Service; EnvironmentName = $image.EnvironmentName; Tag = $tag
        BuildInputHash = $buildInputHash; Reusable = $reusable; Dirty = $State.Dirty
    }
}

function Test-EwspDockerImageExists {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        $EnvironmentInfo
    )
    $dockerPath = if ($EnvironmentInfo -and $EnvironmentInfo.Docker.FilePath) {
        $EnvironmentInfo.Docker.FilePath
    } else { 'docker' }
    $result = Invoke-EwspNative $dockerPath @('image', 'inspect', $Tag)
    $result.ExitCode -eq 0
}

function Resolve-EwspImageAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Descriptor,
        [Parameter(Mandatory = $true)][bool]$ImageExists
    )
    if ($Descriptor.Reusable -and $ImageExists) { return 'REUSE' }
    'BUILD'
}

function Set-EwspProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Values)
    $previous = @{}
    foreach ($key in $Values.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Values[$key], 'Process')
    }
    $previous
}

function Restore-EwspProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Previous)
    foreach ($key in $Previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $Previous[$key], 'Process')
    }
}

function Get-EwspDockerServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$Service,
        [Parameter(Mandatory = $true)]$EnvironmentInfo
    )
    $idResult = Invoke-EwspCompose $EnvironmentInfo $LocalRoot @('ps', '-a', '-q', $Service)
    if ($idResult.ExitCode -ne 0) {
        return [PSCustomObject]@{ Service = $Service; State = 'unavailable'; Health = 'unknown'; Id = $null }
    }
    $id = ($idResult.Output -join '').Trim()
    if (-not $id) { return [PSCustomObject]@{ Service = $Service; State = 'not created'; Health = 'n/a'; Id = $null } }
    $inspect = Invoke-EwspNative $EnvironmentInfo.Docker.FilePath @(
        'inspect', '--format', '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $id
    )
    if ($inspect.ExitCode -ne 0) {
        return [PSCustomObject]@{ Service = $Service; State = 'unknown'; Health = 'unknown'; Id = $id }
    }
    $parts = @(($inspect.Output -join '').Trim().Split('|'))
    [PSCustomObject]@{ Service = $Service; State = $parts[0]; Health = $parts[1]; Id = $id }
}

function Format-EwspServiceReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$States)
    $names = @{
        postgres = 'PostgreSQL'; redis = 'Redis'; minio = 'MinIO'; backend = 'Backend'; dashboard = 'Dashboard'
    }
    $backend = @($States | Where-Object Service -eq 'backend') | Select-Object -First 1
    @($States | ForEach-Object {
        $label = if ($names.ContainsKey($_.Service)) { $names[$_.Service] } else { $_.Service }
        $summary = if ($_.State -eq 'running' -and $_.Health -eq 'healthy') {
            'healthy'
        } elseif ($_.Health -eq 'unhealthy') {
            'unhealthy'
        } elseif ($_.State -in @('exited', 'dead')) {
            "$($_.State)"
        } elseif ($_.Service -eq 'dashboard' -and $backend -and
            -not ($backend.State -eq 'running' -and $backend.Health -eq 'healthy')) {
            'waiting on backend'
        } else {
            "waiting ($($_.State)/$($_.Health))"
        }
        "{0,-14} {1}" -f $label, $summary
    })
}

function New-EwspReadinessException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object[]]$States,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $summary = (Format-EwspServiceReadiness $States) -join [Environment]::NewLine
    $exception = New-Object System.Exception("$Message$([Environment]::NewLine)$summary")
    $exception.Data['Category'] = $Category
    $exception.Data['States'] = $States
    $exception
}

function Wait-EwspServices {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [int]$TimeoutSeconds = 180,
        [scriptblock]$StateProvider,
        [scriptblock]$SleepAction
    )
    if (-not $StateProvider) {
        $StateProvider = {
            param($service)
            Get-EwspDockerServiceState $LocalRoot $service $EnvironmentInfo
        }
    }
    if (-not $SleepAction) { $SleepAction = { Start-Sleep -Seconds 2 } }
    $services = @('postgres', 'redis', 'minio', 'backend', 'dashboard')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $states = @($services | ForEach-Object { & $StateProvider $_ })
        $failed = @($states | Where-Object { $_.State -in @('exited', 'dead') -or $_.Health -eq 'unhealthy' })
        if ($failed.Count -gt 0) {
            throw (New-EwspReadinessException 'One or more EWSP services failed readiness.' $states 'SERVICE_HEALTH_FAILURE')
        }
        $ready = @($states | Where-Object { $_.State -eq 'running' -and $_.Health -eq 'healthy' })
        if ($ready.Count -eq $services.Count) { return $states }
        & $SleepAction
    } while ([DateTime]::UtcNow -lt $deadline)
    throw (New-EwspReadinessException "Timed out after $TimeoutSeconds seconds waiting for EWSP services." $states 'HEALTH_TIMEOUT')
}

function Show-EwspServiceFailureDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][object[]]$States,
        [int]$TailLines = 40
    )
    Write-Host 'Service readiness at failure:' -ForegroundColor Yellow
    Format-EwspServiceReadiness $States | ForEach-Object { Write-Host "  $_" }
    $environmentValues = $null
    try {
        if (Test-Path -LiteralPath (Join-Path $LocalRoot '.env') -PathType Leaf) {
            $environmentValues = Get-EwspEffectiveEnvironmentValues $LocalRoot
        }
    } catch { }
    $diagnosticServices = @($States | Where-Object {
        -not ($_.State -eq 'running' -and $_.Health -eq 'healthy')
    } | Select-Object -First 3)
    foreach ($state in $diagnosticServices) {
        Write-Host "Recent $($state.Service) logs (last $TailLines lines):" -ForegroundColor Yellow
        $logs = Invoke-EwspCompose $EnvironmentInfo $LocalRoot @(
            'logs', '--no-color', '--tail', [string]$TailLines, $state.Service
        )
        if ($logs.ExitCode -eq 0 -and $logs.Output.Count -gt 0) {
            $safeLogs = Protect-EwspDiagnosticText ($logs.Output -join [Environment]::NewLine) $environmentValues
            Write-Host $safeLogs
        } else {
            Write-Host '  No service logs were available.'
        }
    }
}

function Show-EwspRepositoryState {
    param(
        [Parameter(Mandatory = $true)]$Repository,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$LocalRoot
    )
    $displayPath = Resolve-EwspRepositoryPath $LocalRoot $Repository
    Write-Host $Repository.Name
    Write-Host "  path: $displayPath"
    Write-Host "  presence: $($State.Presence)"
    Write-Host "  identity: $($State.Identity)"
    if ($State.Commit) {
        $branch = if ($State.Branch) { $State.Branch } else { '(detached)' }
        $working = if ($State.Dirty) { 'dirty' } else { 'clean' }
        Write-Host "  branch: $branch"
        Write-Host "  commit: $($State.ShortCommit)"
        Write-Host "  working tree: $working"
        Write-Host "  upstream: $(if ($State.Upstream) { $State.Upstream } else { 'none' })"
        Write-Host "  ahead/behind: $(if ($null -ne $State.Ahead) { "$($State.Ahead)/$($State.Behind)" } else { 'n/a' })"
    }
    Write-Host "  classification: $($State.Classification)"
    if ($State.FetchError) { Write-Host '  warning: remote fetch failed; counts may be stale' -ForegroundColor Yellow }
    if ($State.StatusError) { Write-Host '  warning: Git working-tree status failed; treating the repository as dirty' -ForegroundColor Yellow }
}

function Initialize-EwspRepositories {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Configuration
    )
    foreach ($repository in $Configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        if (Test-Path -LiteralPath $path) {
            $identity = Test-EwspRepositoryIdentity $path $repository.ExpectedIdentity
            if (-not $identity.IdentityMatches) {
                throw "$path exists but does not match $($repository.ExpectedIdentity). $($identity.Error) No files were changed."
            }
        }
    }
    $results = @()
    foreach ($repository in $Configuration.Repositories) {
        $result = Ensure-EwspRepository $LocalRoot $repository
        $results += $result
        Write-Host ("      {0,-14} {1}" -f $result.Name, $result.Action.ToLowerInvariant())
    }
    $results
}

function Invoke-EwspRepositoryUpdates {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Configuration
    )
    $results = @()
    foreach ($repository in $Configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        $result = Update-EwspRepository $path $repository
        $results += [PSCustomObject]@{ Repository = $repository; Result = $result }
        if ($result.Result -eq 'UPDATED') {
            Write-Host ("      {0,-14} updated by safe fast-forward" -f $repository.Name) -ForegroundColor Green
        } elseif ($result.Result -eq 'UNCHANGED') {
            Write-Host ("      {0,-14} already up to date" -f $repository.Name)
        } else {
            Write-Host ("      {0,-14} update skipped: {1}" -f $repository.Name, $result.Reason) -ForegroundColor Yellow
        }
    }
    $results
}

function Assert-EwspComposeConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo
    )
    $composePath = Join-Path $LocalRoot 'compose.yml'
    if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) {
        throw "Compose validation failure: compose.yml is missing at '$composePath'."
    }
    $result = Invoke-EwspCompose $EnvironmentInfo $LocalRoot @('config', '--quiet')
    if ($result.ExitCode -ne 0) {
        $reason = Protect-EwspDiagnosticText ($result.Output -join ' ')
        $exception = New-Object System.Exception("Compose validation failure: $reason")
        $exception.Data['Category'] = 'COMPOSE_VALIDATION_FAILURE'
        $exception.Data['ExitCode'] = $result.ExitCode
        $exception.Data['Operation'] = "$($EnvironmentInfo.Compose.DisplayName) -f compose.yml config --quiet"
        throw $exception
    }
}

function New-EwspImagePlan {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][hashtable]$EnvironmentValues
    )
    $sessionId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $descriptors = @()
    $repositoryStates = @()
    foreach ($repository in $Configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        $state = Get-EwspRepositoryState $path $repository.ExpectedIdentity $repository.PrimaryBranch
        $repositoryStates += [PSCustomObject]@{ Repository = $repository; Path = $path; State = $state }
        if (-not $repository.ContainsKey('Image')) { continue }
        if ($state.Classification -eq 'MISSING') { throw "$($repository.Name) is missing. Run .\ewsp.ps1 setup first." }
        if ($state.Classification -eq 'IDENTITY_MISMATCH') {
            throw "$path does not match the expected repository. No files were changed."
        }
        Assert-EwspApplicationBuildAssets $path $repository
        if ($state.Dirty) {
            Write-Host "      $($repository.Name): dirty; using a non-reusable session image" -ForegroundColor Yellow
        }
        $descriptors += Get-EwspImageDescriptor $repository $state $EnvironmentValues $sessionId
    }
    [PSCustomObject]@{ Descriptors = $descriptors; RepositoryStates = $repositoryStates; SessionId = $sessionId }
}

function Invoke-EwspImageBuilds {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [Parameter(Mandatory = $true)][object[]]$Descriptors
    )
    foreach ($descriptor in $Descriptors) {
        $exists = Test-EwspDockerImageExists $descriptor.Tag $EnvironmentInfo
        $action = Resolve-EwspImageAction $descriptor $exists
        if ($action -eq 'REUSE') {
            Write-Host ("      {0,-10} reuse {1}" -f $descriptor.Service, $descriptor.Tag) -ForegroundColor Green
            continue
        }
        Write-Host ("      {0,-10} build {1}" -f $descriptor.Service, $descriptor.Tag)
        try {
            Invoke-EwspComposeStreaming $EnvironmentInfo $LocalRoot @('build', $descriptor.Service) `
                "Docker image build failed for $($descriptor.Service)"
        } catch {
            $_.Exception.Data['Category'] = 'IMAGE_BUILD_FAILURE'
            $_.Exception.Data['Component'] = $descriptor.Service
            throw
        }
        if (-not (Test-EwspDockerImageExists $descriptor.Tag $EnvironmentInfo)) {
            $exception = New-Object System.Exception("Build completed but image was not found: $($descriptor.Tag)")
            $exception.Data['Category'] = 'IMAGE_BUILD_FAILURE'
            $exception.Data['Component'] = $descriptor.Service
            throw $exception
        }
    }
}

function Invoke-EwspServiceStart {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo
    )
    try {
        Invoke-EwspComposeStreaming $EnvironmentInfo $LocalRoot @('up', '-d') 'Docker Compose service startup failed'
    } catch {
        $_.Exception.Data['Category'] = 'SERVICE_START_FAILURE'
        $_.Exception.Data['Component'] = 'Docker Compose project'
        throw
    }
}

function Get-EwspLocalUrls {
    param([Parameter(Mandatory = $true)][hashtable]$EnvironmentValues)
    $ports = @(Get-EwspConfiguredPorts $EnvironmentValues)
    $byService = @{}
    foreach ($port in $ports) {
        if (-not $byService.ContainsKey($port.Service)) { $byService[$port.Service] = @{} }
        $byService[$port.Service][[string]$port.ContainerPort] = $port.Port
    }
    $backendPort = $byService.backend['8080']
    $dashboardPort = $byService.dashboard['80']
    $minioApiPort = $byService.minio['9000']
    $minioConsolePort = $byService.minio['9001']
    [PSCustomObject]@{
        Dashboard = "http://localhost:$dashboardPort"
        DashboardComplaints = "http://localhost:$dashboardPort/complaints"
        DashboardMissingAsset = "http://localhost:$dashboardPort/assets/ewsp-missing-verification.js"
        DashboardBackendHealth = "http://localhost:$dashboardPort/api/health"
        Backend = "http://localhost:$backendPort"
        BackendHealth = "http://localhost:$backendPort/api/health"
        Swagger = "http://localhost:$backendPort/swagger-ui/index.html"
        OpenApi = "http://localhost:$backendPort/v3/api-docs"
        MinioApi = "http://localhost:$minioApiPort"
        MinioLive = "http://localhost:$minioApiPort/minio/health/live"
        MinioConsole = "http://localhost:$minioConsolePort"
    }
}

function Assert-EwspEndpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Urls,
        [scriptblock]$Probe
    )
    if (-not $Probe) {
        $Probe = {
            param($uri)
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 20
                [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Error = $null }
            } catch {
                $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                [PSCustomObject]@{ StatusCode = $status; Error = $_.Exception.Message }
            }
        }
    }
    $checks = @(
        @{ Name = 'Dashboard'; Uri = $Urls.Dashboard; ExpectedStatus = 200 },
        @{ Name = 'Dashboard route'; Uri = $Urls.DashboardComplaints; ExpectedStatus = 200 },
        @{ Name = 'Dashboard missing asset'; Uri = $Urls.DashboardMissingAsset; ExpectedStatus = 404 },
        @{ Name = 'Dashboard backend proxy'; Uri = $Urls.DashboardBackendHealth; ExpectedStatus = 200 },
        @{ Name = 'Backend health'; Uri = $Urls.BackendHealth; ExpectedStatus = 200 },
        @{ Name = 'Swagger UI'; Uri = $Urls.Swagger; ExpectedStatus = 200 },
        @{ Name = 'OpenAPI'; Uri = $Urls.OpenApi; ExpectedStatus = 200 },
        @{ Name = 'MinIO'; Uri = $Urls.MinioLive; ExpectedStatus = 200 }
    )
    foreach ($check in $checks) {
        $result = & $Probe $check.Uri
        if ($result.StatusCode -ne $check.ExpectedStatus) {
            $reason = if ($result.Error) { Protect-EwspDiagnosticText $result.Error } else { "HTTP $($result.StatusCode)" }
            $exception = New-Object System.Exception("Endpoint verification failure: $($check.Name) at $($check.Uri) did not return HTTP $($check.ExpectedStatus). Detected: $reason")
            $exception.Data['Category'] = 'ENDPOINT_VERIFICATION_FAILURE'
            $exception.Data['Component'] = $check.Name
            $exception.Data['Operation'] = "HTTP GET $($check.Uri)"
            throw $exception
        }
        Write-Host ("      {0,-24} HTTP {1}" -f $check.Name, $check.ExpectedStatus)
    }
}

function Get-EwspFailureNextAction {
    param([string]$Category, [string]$Phase, [string]$Command = 'up')
    $retry = ".\ewsp.ps1 $Command"
    switch ($Category) {
        'PREREQUISITE_MISSING' { return "Install or expose the named prerequisite on PATH, then rerun $retry. No automatic installation was attempted." }
        'DOCKER_ENGINE_UNREACHABLE' { return "Start Docker Desktop/Engine, wait until it is ready, and rerun $retry." }
        'UNSUPPORTED_COMPOSE' { return 'Enable the Docker Compose plugin or install a compatible docker-compose command, then retry.' }
        'WRONG_REPOSITORY_IDENTITY' { return 'Move or rename the unexpected sibling directory yourself, then rerun .\ewsp.ps1 up. It was not overwritten.' }
        'REQUIRED_DOCKER_ASSET_MISSING' { return 'Safely update the named sibling checkout, or resolve its Git state manually if automatic update was skipped; then retry.' }
        'INVALID_ENV_CONFIGURATION' { return 'Correct only the named setting in .env and rerun .\ewsp.ps1 up. Existing secret values were not printed.' }
        'PORT_COLLISION' { return 'Stop or reconfigure the external listener, or change the corresponding host port in .env; then rerun .\ewsp.ps1 up.' }
        'IMAGE_BUILD_FAILURE' { return 'Review the bounded build output above, fix the application build issue, and rerun .\ewsp.ps1 up.' }
        'SERVICE_START_FAILURE' { return 'Run .\ewsp.ps1 status and inspect logs with the detected Compose invocation for the named service, then retry.' }
        'SERVICE_HEALTH_FAILURE' { return 'Review the service table and bounded logs above, correct the failing dependency/service, and retry.' }
        'HEALTH_TIMEOUT' { return 'Review the waiting services and bounded logs above; use .\ewsp.ps1 status before retrying.' }
        'COMPOSE_VALIDATION_FAILURE' { return 'Correct compose.yml or the named environment setting, then rerun .\ewsp.ps1 up.' }
        'ENDPOINT_VERIFICATION_FAILURE' { return 'Inspect the named endpoint and service logs, then rerun .\ewsp.ps1 up.' }
        'KUBECTL_MISSING' { return 'Install kubectl or expose it on PATH, then rerun the Kubernetes command.' }
        'KUBERNETES_WRONG_CONTEXT' { return "Review the reported context and explicitly select '$script:EwspKubernetesContext' yourself before retrying. No context was switched automatically." }
        'KUBERNETES_API_UNREACHABLE' { return 'Start Docker Desktop Kubernetes, wait for its API to become ready, and retry. The cluster was not reset.' }
        'KUBERNETES_NODE_NOT_READY' { return 'Wait for the Docker Desktop Kubernetes node to become Ready and retry; inspect Docker Desktop diagnostics if it remains NotReady.' }
        'KUBERNETES_STORAGE_UNAVAILABLE' { return "Restore the default 'standard' StorageClass backed by rancher.io/local-path, then retry without deleting existing PVCs." }
        'KUBERNETES_MANIFEST_INVALID' { return 'Correct the reported source or rendered manifest contract and rerun k8s-up. No placeholder Secret was applied.' }
        'KUBERNETES_APPLY_FAILURE' { return 'Review the named resource and bounded Kubernetes diagnostics, correct the manifest or cluster condition, and rerun k8s-up.' }
        'KUBERNETES_READINESS_FAILURE' { return 'Review the bounded Pod, event, and PVC diagnostics, correct the evidenced condition, and rerun k8s-up.' }
        'KUBERNETES_VERIFICATION_FAILURE' { return 'Review the named in-cluster check and workload logs, then rerun k8s-up.' }
        'KUBERNETES_PORT_CONFLICT' { return 'Stop or reconfigure the external listener, or change DASHBOARD_HOST_PORT in .env. No unrelated process was stopped.' }
        default {
            if ($Phase -eq 'REPOSITORY_UPDATE') { return 'Resolve the reported Git state manually only if the required application assets are unavailable.' }
            return "Correct the reported condition and rerun $retry. Existing source changes and persistent volumes were preserved."
        }
    }
}

function New-EwspUpFailureException {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$FriendlyPhase,
        [Parameter(Mandatory = $true)][System.Exception]$Cause,
        $EnvironmentInfo,
        [Parameter(Mandatory = $true)][object]$CompletedPhases,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RemainingPhases,
        [string]$Operation,
        [string]$Component,
        [string]$WorkflowName = 'up'
    )
    if ($Cause.Data.Contains('Category')) {
        $category = [string]$Cause.Data['Category']
    } else {
        $category = switch ($Phase) {
            'ENVIRONMENT_DETECTION' {
                if ($Cause.Message -like '*Docker Engine not running*') { 'DOCKER_ENGINE_UNREACHABLE' }
                elseif ($Cause.Message -like '*Unsupported Compose*') { 'UNSUPPORTED_COMPOSE' }
                else { 'PREREQUISITE_MISSING' }
            }
            'REPOSITORY_SETUP' {
                if ($Cause.Message -like '*does not match*') { 'WRONG_REPOSITORY_IDENTITY' }
                elseif ($Cause.Message -like '*missing*') { 'REPOSITORY_MISSING' }
                else { 'REPOSITORY_SETUP_FAILURE' }
            }
            'REPOSITORY_UPDATE' { 'REPOSITORY_UPDATE_FAILURE' }
            'CONFIGURATION' { 'INVALID_ENV_CONFIGURATION' }
            'BUILD_PREFLIGHT' {
                if ($Cause.Message -like '*required application-owned Docker asset*') { 'REQUIRED_DOCKER_ASSET_MISSING' }
                else { 'BUILD_PREFLIGHT_FAILURE' }
            }
            default { $Phase }
        }
    }
    $exitCode = if ($Cause.Data.Contains('ExitCode')) { [string]$Cause.Data['ExitCode'] } else { 'n/a' }
    if ($Cause.Data.Contains('Operation')) { $Operation = [string]$Cause.Data['Operation'] }
    if ($Cause.Data.Contains('Component')) { $Component = [string]$Cause.Data['Component'] }
    if (-not $Operation) { $Operation = $FriendlyPhase }
    if (-not $Component) { $Component = 'EWSP workspace' }
    $environmentSummary = if ($EnvironmentInfo) {
        Format-EwspEnvironmentSummary $EnvironmentInfo
    } else { Format-EwspEnvironmentSummary ([PSCustomObject]@{
        Platform = Get-EwspHostPlatform
        Git = [PSCustomObject]@{ Version = $null }
        Docker = [PSCustomObject]@{ CliVersion = $null; EngineVersion = $null }
        Compose = [PSCustomObject]@{ Available = $false }
    }) }
    $succeeded = if ($CompletedPhases.Count -gt 0) { $CompletedPhases -join ', ' } else { 'none' }
    $notAttempted = if ($RemainingPhases.Count -gt 0) { $RemainingPhases -join ', ' } else { 'none' }
    $reason = Protect-EwspDiagnosticText $Cause.Message
    $nextAction = if ($Cause.Data.Contains('NextAction')) {
        [string]$Cause.Data['NextAction']
    } else { Get-EwspFailureNextAction $category $Phase $WorkflowName }
    $message = @(
        "EWSP $WorkflowName failed."
        "Phase: $Phase ($FriendlyPhase)"
        "Category: $category"
        "Component: $Component"
        "Operation: $(Protect-EwspDiagnosticText $Operation)"
        "Exit code: $exitCode"
        "Detected environment: $environmentSummary"
        "Succeeded before failure: $succeeded"
        "Not attempted afterward: $notAttempted"
        "Reason: $reason"
        "Safe next action: $nextAction"
    ) -join [Environment]::NewLine
    $exception = New-Object System.Exception($message, $Cause)
    $exception.Data['Category'] = $category
    $exception.Data['Phase'] = $Phase
    $exception.Data['ExitCode'] = $exitCode
    $exception
}

function Invoke-EwspUpPhase {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][object]$CompletedPhases,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RemainingPhases,
        $EnvironmentInfo,
        [string]$Operation,
        [string]$Component,
        [string]$WorkflowName = 'up'
    )
    Write-Host "[$Index/$Total] $FriendlyName..." -ForegroundColor Cyan
    try {
        $result = & $Action
        $CompletedPhases.Add($Phase) | Out-Null
        $result
    } catch {
        if (-not $EnvironmentInfo -and $script:EwspResolvedEnvironment) {
            $EnvironmentInfo = $script:EwspResolvedEnvironment
        }
        throw (New-EwspUpFailureException $Phase $FriendlyName $_.Exception $EnvironmentInfo `
            $CompletedPhases $RemainingPhases $Operation $Component $WorkflowName)
    }
}

function Show-EwspEnvironmentDetails {
    param([Parameter(Mandatory = $true)]$EnvironmentInfo)
    Write-Host "      OS           $($EnvironmentInfo.Platform.Description) [$($EnvironmentInfo.Platform.Architecture)]"
    Write-Host "      PowerShell   $($EnvironmentInfo.Platform.PowerShellEdition) $($EnvironmentInfo.Platform.PowerShellVersion)"
    Write-Host "      Git          $($EnvironmentInfo.Git.Version)"
    Write-Host "      Docker CLI   $($EnvironmentInfo.Docker.CliVersion)"
    Write-Host "      Docker Engine $($EnvironmentInfo.Docker.EngineVersion)"
    Write-Host "      Compose      $($EnvironmentInfo.Compose.DisplayName) $($EnvironmentInfo.Compose.Version)"
}

function Show-EwspReadySummary {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][object[]]$States
    )
    Write-Host ''
    Write-Host 'SUCCESS' -ForegroundColor Green
    Write-Host 'EWSP is ready.' -ForegroundColor Green
    Write-Host ''
    Show-EwspEnvironmentDetails $Context.Environment
    Write-Host '      Repositories'
    foreach ($entry in $Context.ImagePlan.RepositoryStates) {
        $state = $entry.State
        Write-Host ("        {0,-14} {1}  {2}" -f $entry.Repository.Name, $state.ShortCommit, $state.Classification)
    }
    Write-Host '      Services'
    Format-EwspServiceReadiness $States | ForEach-Object { Write-Host "        $_" }
    Write-Host ''
    Write-Host "Dashboard:     $($Context.Urls.Dashboard)"
    Write-Host "Backend:       $($Context.Urls.Backend)"
    Write-Host "Swagger:       $($Context.Urls.Swagger)"
    Write-Host "MinIO Console: $($Context.Urls.MinioConsole)"
    Write-Host ''
    Write-Host 'Next: .\ewsp.ps1 status | .\ewsp.ps1 update | .\ewsp.ps1 stop'
}

function Invoke-EwspSetup {
    param([Parameter(Mandatory = $true)][string]$LocalRoot, $EnvironmentInfo)
    $EnvironmentInfo = Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $EnvironmentInfo
    $configuration = Get-EwspConfiguration $LocalRoot
    Initialize-EwspRepositories $LocalRoot $configuration | Out-Null
    Ensure-EwspEnvironmentFile $LocalRoot
    Write-Host 'Setup complete. Existing repositories were not updated and Docker images were not rebuilt.' -ForegroundColor Green
}

function Invoke-EwspUpdate {
    param([Parameter(Mandatory = $true)][string]$LocalRoot, $EnvironmentInfo)
    $EnvironmentInfo = Assert-EwspPrerequisites -EnvironmentInfo $EnvironmentInfo
    $configuration = Get-EwspConfiguration $LocalRoot
    Invoke-EwspRepositoryUpdates $LocalRoot $configuration | Out-Null
}

function Invoke-EwspStatus {
    param([Parameter(Mandatory = $true)][string]$LocalRoot, $EnvironmentInfo)
    if (-not $EnvironmentInfo) { $EnvironmentInfo = Get-EwspRuntimeEnvironment }
    $EnvironmentInfo = Assert-EwspPrerequisites -EnvironmentInfo $EnvironmentInfo
    $configuration = Get-EwspConfiguration $LocalRoot
    Write-Host 'Repositories'
    Write-Host '------------'
    foreach ($repository in $configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        $state = Get-EwspRepositoryState $path $repository.ExpectedIdentity $repository.PrimaryBranch -Fetch
        Show-EwspRepositoryState $repository $state $LocalRoot
    }
    Write-Host ''
    Write-Host ".env: $(if (Test-Path -LiteralPath (Join-Path $LocalRoot '.env') -PathType Leaf) { 'present' } else { 'missing' })"
    Write-Host ''
    Write-Host 'Docker services'
    Write-Host '---------------'
    if (-not $EnvironmentInfo.Docker.Available) {
        Write-Host 'Docker CLI is not installed or is not on PATH.' -ForegroundColor Yellow
        return
    }
    if (-not $EnvironmentInfo.Docker.EngineReachable) {
        Write-Host 'Docker CLI is installed, but Docker Engine is not reachable.' -ForegroundColor Yellow
        return
    }
    if (-not $EnvironmentInfo.Compose.Available) {
        Write-Host 'Neither docker compose nor docker-compose is supported by this environment.' -ForegroundColor Yellow
        return
    }
    foreach ($service in @('backend', 'dashboard', 'postgres', 'redis', 'minio')) {
        $state = Get-EwspDockerServiceState $LocalRoot $service $EnvironmentInfo
        Write-Host ("{0,-10} {1,-12} health={2}" -f $service, $state.State, $state.Health)
    }
}

function Invoke-EwspStart {
    param([Parameter(Mandatory = $true)][string]$LocalRoot, $EnvironmentInfo)
    $EnvironmentInfo = Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $EnvironmentInfo
    if (-not (Test-Path -LiteralPath (Join-Path $LocalRoot '.env') -PathType Leaf)) {
        throw '.env is missing. Run .\ewsp.ps1 setup first.'
    }
    $configuration = Get-EwspConfiguration $LocalRoot
    $environmentValues = Get-EwspEffectiveEnvironmentValues $LocalRoot
    $ports = @(Assert-EwspEnvironmentConfiguration $environmentValues)
    Assert-EwspComposeConfiguration $LocalRoot $EnvironmentInfo
    $imagePlan = New-EwspImagePlan $LocalRoot $configuration $environmentValues
    Invoke-EwspPortPreflight $LocalRoot $EnvironmentInfo $ports | Out-Null
    $tagEnvironment = @{}
    foreach ($descriptor in $imagePlan.Descriptors) { $tagEnvironment[$descriptor.EnvironmentName] = $descriptor.Tag }
    $previousEnvironment = Set-EwspProcessEnvironment $tagEnvironment
    try {
        Invoke-EwspImageBuilds $LocalRoot $EnvironmentInfo $imagePlan.Descriptors
        Write-Host 'Starting EWSP services ...'
        Invoke-EwspServiceStart $LocalRoot $EnvironmentInfo
        try {
            $states = @(Wait-EwspServices $LocalRoot $EnvironmentInfo)
        } catch {
            if ($_.Exception.Data.Contains('States')) {
                Show-EwspServiceFailureDiagnostics $LocalRoot $EnvironmentInfo $_.Exception.Data['States']
            }
            throw
        }
        Format-EwspServiceReadiness $states | ForEach-Object { Write-Host $_ }
    } finally {
        Restore-EwspProcessEnvironment $previousEnvironment
    }
    $urls = Get-EwspLocalUrls $environmentValues
    Write-Host ''
    Write-Host "Dashboard:     $($urls.Dashboard)"
    Write-Host "Backend:       $($urls.Backend)"
    Write-Host "Swagger:       $($urls.Swagger)"
    Write-Host "MinIO API:     $($urls.MinioApi)"
    Write-Host "MinIO Console: $($urls.MinioConsole)"
}

function Invoke-EwspUp {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $phaseNames = @(
        'ENVIRONMENT_DETECTION', 'REPOSITORY_SETUP', 'REPOSITORY_UPDATE', 'CONFIGURATION',
        'BUILD_PREFLIGHT', 'IMAGE_BUILD', 'SERVICE_START', 'HEALTH_WAIT', 'FINAL_VERIFICATION'
    )
    $completed = New-Object System.Collections.Generic.List[string]
    $context = @{
        Environment = $null; Configuration = $null; EnvironmentValues = $null; Ports = $null
        ImagePlan = $null; PreviousTagEnvironment = $null; Urls = $null; States = $null
    }
    $total = $phaseNames.Count

    Invoke-EwspUpPhase 1 $total $phaseNames[0] 'Detecting environment' {
        $context.Environment = Get-EwspRuntimeEnvironment
        Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $context.Environment | Out-Null
        Show-EwspEnvironmentDetails $context.Environment
    } $completed $phaseNames[1..($total - 1)] $context.Environment 'Detect required commands and capabilities' 'Local development environment' | Out-Null

    Invoke-EwspUpPhase 2 $total $phaseNames[1] 'Preparing repositories' {
        $context.Configuration = Get-EwspConfiguration $LocalRoot
        Initialize-EwspRepositories $LocalRoot $context.Configuration | Out-Null
    } $completed $phaseNames[2..($total - 1)] $context.Environment 'Validate or clone sibling repositories' 'EWSP workspace' | Out-Null

    Invoke-EwspUpPhase 3 $total $phaseNames[2] 'Safely updating repositories' {
        Invoke-EwspRepositoryUpdates $LocalRoot $context.Configuration | Out-Null
    } $completed $phaseNames[3..($total - 1)] $context.Environment 'Fetch and safe fast-forward' 'EWSP repositories' | Out-Null

    Invoke-EwspUpPhase 4 $total $phaseNames[3] 'Preparing configuration' {
        Ensure-EwspEnvironmentFile $LocalRoot
        $context.EnvironmentValues = Get-EwspEffectiveEnvironmentValues $LocalRoot
        $context.Ports = @(Assert-EwspEnvironmentConfiguration $context.EnvironmentValues)
        Write-Host '      .env ready; required setting names validated (secret values hidden)'
    } $completed $phaseNames[4..($total - 1)] $context.Environment 'Create/preserve and validate .env' 'Local configuration' | Out-Null

    Invoke-EwspUpPhase 5 $total $phaseNames[4] 'Running build preflight' {
        Assert-EwspComposeConfiguration $LocalRoot $context.Environment
        $context.ImagePlan = New-EwspImagePlan $LocalRoot $context.Configuration $context.EnvironmentValues
        Invoke-EwspPortPreflight $LocalRoot $context.Environment $context.Ports | Out-Null
        Write-Host '      Compose, application Docker assets, paths, and host ports are ready'
    } $completed $phaseNames[5..($total - 1)] $context.Environment 'Validate Compose, build assets, paths, and ports' 'Docker build preflight' | Out-Null

    $tagEnvironment = @{}
    foreach ($descriptor in $context.ImagePlan.Descriptors) { $tagEnvironment[$descriptor.EnvironmentName] = $descriptor.Tag }
    $context.PreviousTagEnvironment = Set-EwspProcessEnvironment $tagEnvironment
    try {
        Invoke-EwspUpPhase 6 $total $phaseNames[5] 'Preparing application images' {
            Invoke-EwspImageBuilds $LocalRoot $context.Environment $context.ImagePlan.Descriptors
        } $completed $phaseNames[6..($total - 1)] $context.Environment 'Build or reuse application images' 'Application images' | Out-Null

        Invoke-EwspUpPhase 7 $total $phaseNames[6] 'Starting services' {
            Invoke-EwspServiceStart $LocalRoot $context.Environment
            Write-Host '      Docker Compose accepted the service start request'
        } $completed $phaseNames[7..($total - 1)] $context.Environment 'Compose up -d' 'EWSP services' | Out-Null

        Invoke-EwspUpPhase 8 $total $phaseNames[7] 'Waiting for service health' {
            try {
                $context.States = @(Wait-EwspServices $LocalRoot $context.Environment)
            } catch {
                if ($_.Exception.Data.Contains('States')) {
                    Show-EwspServiceFailureDiagnostics $LocalRoot $context.Environment $_.Exception.Data['States']
                }
                throw
            }
            Format-EwspServiceReadiness $context.States | ForEach-Object { Write-Host "      $_" }
        } $completed @($phaseNames[8]) $context.Environment 'Wait for five healthy services' 'EWSP services' | Out-Null

        Invoke-EwspUpPhase 9 $total $phaseNames[8] 'Verifying local endpoints' {
            $context.Urls = Get-EwspLocalUrls $context.EnvironmentValues
            Assert-EwspEndpoints $context.Urls
        } $completed @() $context.Environment 'Verify dashboard, backend, Swagger, OpenAPI, and MinIO endpoints' 'EWSP endpoints' | Out-Null
    } finally {
        if ($context.PreviousTagEnvironment) { Restore-EwspProcessEnvironment $context.PreviousTagEnvironment }
    }
    Show-EwspReadySummary $context $context.States
}

function New-EwspKubernetesException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Category,
        [string]$Component = 'Kubernetes environment',
        [string]$Operation = 'kubectl'
    )
    $exception = New-Object System.Exception($Message)
    $exception.Data['Category'] = $Category
    $exception.Data['Component'] = $Component
    $exception.Data['Operation'] = $Operation
    $exception
}

function Invoke-EwspKubectl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [scriptblock]$CommandRunner
    )
    if ($CommandRunner) { return (& $CommandRunner 'kubectl' $Arguments) }
    Invoke-EwspNative 'kubectl' $Arguments
}

function Invoke-EwspKubectlStreaming {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    Invoke-EwspNativeStreaming 'kubectl' $Arguments $null $FailureMessage
}

function Get-EwspKubernetesEnvironment {
    [CmdletBinding()]
    param(
        $RuntimeEnvironment,
        [scriptblock]$CommandResolver,
        [scriptblock]$CommandRunner
    )
    if (-not $RuntimeEnvironment) { $RuntimeEnvironment = Get-EwspRuntimeEnvironment }
    if (-not $CommandResolver) {
        $CommandResolver = { param($name) Get-Command $name -ErrorAction SilentlyContinue }
    }
    $available = $null -ne (& $CommandResolver 'kubectl')
    $clientVersion = $null
    $context = $null
    $apiReachable = $false
    $serverVersion = $null
    $nodes = @()
    $namespaceExists = $false
    $storageClass = $null

    if ($available) {
        $clientResult = Invoke-EwspKubectl @('version', '--client', '-o', 'json') $CommandRunner
        if ($clientResult.ExitCode -eq 0) {
            try { $clientVersion = (($clientResult.Output -join "`n") | ConvertFrom-Json).clientVersion.gitVersion } catch { }
        }
        $contextResult = Invoke-EwspKubectl @('config', 'current-context') $CommandRunner
        if ($contextResult.ExitCode -eq 0) { $context = ($contextResult.Output -join '').Trim() }
        if ($context -eq $script:EwspKubernetesContext) {
            $versionResult = Invoke-EwspKubectl @('version', '-o', 'json') $CommandRunner
            if ($versionResult.ExitCode -eq 0) {
                try {
                    $versionObject = ($versionResult.Output -join "`n") | ConvertFrom-Json
                    $serverVersion = $versionObject.serverVersion.gitVersion
                    $apiReachable = -not [string]::IsNullOrWhiteSpace([string]$serverVersion)
                } catch { }
            }
            if ($apiReachable) {
                $nodeResult = Invoke-EwspKubectl @('get', 'nodes', '-o', 'json') $CommandRunner
                if ($nodeResult.ExitCode -eq 0) {
                    try {
                        $nodeObject = ($nodeResult.Output -join "`n") | ConvertFrom-Json
                        $nodes = @($nodeObject.items | ForEach-Object {
                            $condition = @($_.status.conditions | Where-Object type -eq 'Ready')
                            [PSCustomObject]@{
                                Name = $_.metadata.name
                                Ready = [bool]($condition.Count -gt 0 -and $condition[0].status -eq 'True')
                                Version = $_.status.nodeInfo.kubeletVersion
                                ContainerRuntime = $_.status.nodeInfo.containerRuntimeVersion
                            }
                        })
                    } catch { }
                }
                $namespaceResult = Invoke-EwspKubectl @('get', 'namespace', $script:EwspKubernetesNamespace, '-o', 'name') $CommandRunner
                $namespaceExists = $namespaceResult.ExitCode -eq 0
                $storageResult = Invoke-EwspKubectl @('get', 'storageclass', 'standard', '-o', 'json') $CommandRunner
                if ($storageResult.ExitCode -eq 0) {
                    try {
                        $storageObject = ($storageResult.Output -join "`n") | ConvertFrom-Json
                        $defaultValue = $storageObject.metadata.annotations.'storageclass.kubernetes.io/is-default-class'
                        $storageClass = [PSCustomObject]@{
                            Name = $storageObject.metadata.name
                            Provisioner = $storageObject.provisioner
                            ReclaimPolicy = $storageObject.reclaimPolicy
                            VolumeBindingMode = $storageObject.volumeBindingMode
                            Default = $defaultValue -eq 'true'
                        }
                    } catch { }
                }
            }
        }
    }

    $kubernetes = [PSCustomObject]@{
        Available = $available
        ClientVersion = $clientVersion
        Context = $context
        ExpectedContext = $script:EwspKubernetesContext
        ApiReachable = $apiReachable
        ServerVersion = $serverVersion
        Nodes = @($nodes)
        NamespaceExists = $namespaceExists
        Namespace = $script:EwspKubernetesNamespace
        StorageClass = $storageClass
        DockerDesktopKind = [bool]($nodes.Count -eq 1 -and $nodes[0].Name -eq 'desktop-control-plane' -and $nodes[0].ContainerRuntime -like 'containerd://*')
    }
    $RuntimeEnvironment | Add-Member -NotePropertyName Kubernetes -NotePropertyValue $kubernetes -Force
    $script:EwspResolvedEnvironment = $RuntimeEnvironment
    $RuntimeEnvironment
}

function Assert-EwspKubernetesEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [switch]$RequireDocker
    )
    $kubernetes = $EnvironmentInfo.Kubernetes
    if (-not $kubernetes.Available) {
        throw (New-EwspKubernetesException 'Prerequisite missing: kubectl is not installed or is not available on PATH.' 'KUBECTL_MISSING' 'kubectl' 'kubectl version --client')
    }
    if (-not $kubernetes.ClientVersion) {
        throw (New-EwspKubernetesException 'kubectl client version could not be detected.' 'KUBECTL_MISSING' 'kubectl' 'kubectl version --client -o json')
    }
    if ($kubernetes.Context -ne $kubernetes.ExpectedContext) {
        $actual = if ($kubernetes.Context) { $kubernetes.Context } else { '<none>' }
        throw (New-EwspKubernetesException "Refusing Kubernetes deployment: current context is '$actual'; expected '$($kubernetes.ExpectedContext)'. No context was switched." 'KUBERNETES_WRONG_CONTEXT' 'Kubernetes context' 'kubectl config current-context')
    }
    if (-not $kubernetes.ApiReachable) {
        throw (New-EwspKubernetesException "Kubernetes API for context '$($kubernetes.Context)' is not reachable." 'KUBERNETES_API_UNREACHABLE' 'Kubernetes API' 'kubectl version -o json')
    }
    if ($kubernetes.Nodes.Count -eq 0 -or @($kubernetes.Nodes | Where-Object { -not $_.Ready }).Count -gt 0) {
        $state = if ($kubernetes.Nodes.Count) {
            @($kubernetes.Nodes | ForEach-Object { "$($_.Name)=$(if ($_.Ready) { 'Ready' } else { 'NotReady' })" }) -join ', '
        } else { 'no nodes returned' }
        throw (New-EwspKubernetesException "Kubernetes node readiness check failed: $state." 'KUBERNETES_NODE_NOT_READY' 'Kubernetes nodes' 'kubectl get nodes')
    }
    if (-not $kubernetes.DockerDesktopKind) {
        throw (New-EwspKubernetesException "Refusing Kubernetes deployment: context '$($kubernetes.Context)' is not the verified single-node Docker Desktop kind cluster (expected Ready node desktop-control-plane using containerd)." 'KUBERNETES_WRONG_CONTEXT' 'Kubernetes cluster identity' 'kubectl get nodes -o json')
    }
    $storage = $kubernetes.StorageClass
    if (-not $storage -or $storage.Name -ne 'standard' -or $storage.Provisioner -ne 'rancher.io/local-path' -or -not $storage.Default) {
        throw (New-EwspKubernetesException "Required default StorageClass 'standard' backed by rancher.io/local-path is unavailable." 'KUBERNETES_STORAGE_UNAVAILABLE' 'Kubernetes storage' 'kubectl get storageclass standard')
    }
    if ($RequireDocker) {
        if (-not $EnvironmentInfo.Docker.Available) {
            throw (New-EwspKubernetesException 'Docker CLI is required for local Kubernetes image resolution.' 'PREREQUISITE_MISSING' 'Docker CLI' 'docker --version')
        }
        if (-not $EnvironmentInfo.Docker.EngineReachable) {
            throw (New-EwspKubernetesException 'Docker Engine is not reachable; Docker Desktop local images cannot be prepared.' 'DOCKER_ENGINE_UNREACHABLE' 'Docker Engine' 'docker version')
        }
    }
    $EnvironmentInfo
}

function Show-EwspKubernetesEnvironment {
    param([Parameter(Mandatory = $true)]$EnvironmentInfo)
    $kubernetes = $EnvironmentInfo.Kubernetes
    Write-Host "      kubectl      $($kubernetes.ClientVersion)"
    Write-Host "      context      $($kubernetes.Context) (expected $($kubernetes.ExpectedContext))"
    Write-Host "      server       $($kubernetes.ServerVersion)"
    foreach ($node in $kubernetes.Nodes) {
        Write-Host ("      node         {0} {1} [{2}]" -f $node.Name, $(if ($node.Ready) { 'Ready' } else { 'NotReady' }), $node.Version)
    }
    Write-Host "      namespace    $($kubernetes.Namespace) ($(if ($kubernetes.NamespaceExists) { 'present' } else { 'absent' }))"
    Write-Host "      storage      $($kubernetes.StorageClass.Name) [$($kubernetes.StorageClass.Provisioner)]"
    Write-Host "      Docker       $($EnvironmentInfo.Docker.EngineVersion)"
}

function Get-EwspKubernetesPaths {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $temporaryRoot = Join-Path $LocalRoot '.tmp\k8s'
    [PSCustomObject]@{
        SourceRoot = Join-Path $LocalRoot 'k8s'
        TemporaryRoot = $temporaryRoot
        RenderedRoot = Join-Path $temporaryRoot 'rendered'
        BackendRendered = Join-Path $temporaryRoot 'rendered\backend-deployment.yaml'
        DashboardRendered = Join-Path $temporaryRoot 'rendered\dashboard-deployment.yaml'
        Secret = Join-Path $temporaryRoot 'secrets.local.json'
        PortForwardState = Join-Path $temporaryRoot 'port-forward.json'
        PortForwardOutput = Join-Path $temporaryRoot 'port-forward.out.log'
        PortForwardError = Join-Path $temporaryRoot 'port-forward.err.log'
    }
}

function Assert-EwspSafeTemporaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $safeRoot = [IO.Path]::GetFullPath((Join-Path $LocalRoot '.tmp')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Temporary Kubernetes path escaped the ignored .tmp directory: $target"
    }
    $target
}

function Clear-EwspKubernetesRenderedArtifacts {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $paths = Get-EwspKubernetesPaths $LocalRoot
    $renderedRoot = Assert-EwspSafeTemporaryPath $LocalRoot $paths.RenderedRoot
    if (Test-Path -LiteralPath $renderedRoot) { Remove-Item -LiteralPath $renderedRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $renderedRoot -Force | Out-Null
    $paths
}

function New-EwspKubernetesSecretArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][hashtable]$EnvironmentValues,
        [switch]$SkipAcl
    )
    $required = @('POSTGRES_USER', 'POSTGRES_PASSWORD', 'MINIO_ROOT_USER', 'MINIO_ROOT_PASSWORD', 'JWT_SECRET')
    $missing = @($required | Where-Object {
        -not $EnvironmentValues.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$_])
    })
    if ($missing.Count) {
        throw (New-EwspKubernetesException "Required Kubernetes Secret settings are missing or empty: $($missing -join ', '). Values were not printed." 'INVALID_ENV_CONFIGURATION' 'Kubernetes Secret' 'Read .env')
    }
    $paths = Get-EwspKubernetesPaths $LocalRoot
    $secretPath = Assert-EwspSafeTemporaryPath $LocalRoot $paths.Secret
    New-Item -ItemType Directory -Path (Split-Path -Parent $secretPath) -Force | Out-Null
    $data = [ordered]@{}
    foreach ($key in $required) {
        $data[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$EnvironmentValues[$key]))
    }
    $secret = [ordered]@{
        apiVersion = 'v1'; kind = 'Secret'
        metadata = [ordered]@{
            name = 'ewsp-infrastructure-secrets'; namespace = $script:EwspKubernetesNamespace
            labels = [ordered]@{ 'app.kubernetes.io/component' = 'infrastructure'; 'app.kubernetes.io/part-of' = 'ewsp' }
        }
        type = 'Opaque'; data = $data
    }
    try {
        [IO.File]::WriteAllText($secretPath, ($secret | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $ignored = Invoke-EwspNative 'git' @('-C', $LocalRoot, 'check-ignore', '--quiet', '--', '.tmp/k8s/secrets.local.json')
        if ($ignored.ExitCode -ne 0) { throw 'Temporary Kubernetes Secret artifact is not ignored by Git.' }
        if (-not $SkipAcl -and (Get-EwspHostPlatform).Name -eq 'Windows') {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $aclResult = Invoke-EwspNative 'icacls' @($secretPath, '/inheritance:r', '/grant:r', "${identity}:(F)")
            if ($aclResult.ExitCode -ne 0) { throw 'Failed to restrict the temporary Kubernetes Secret artifact ACL.' }
        }
    } catch {
        if (Test-Path -LiteralPath $secretPath -PathType Leaf) { Remove-Item -LiteralPath $secretPath -Force }
        throw
    }
    $secretPath
}

function Remove-EwspKubernetesSecretArtifact {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $path = Assert-EwspSafeTemporaryPath $LocalRoot (Get-EwspKubernetesPaths $LocalRoot).Secret
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}

function New-EwspKubernetesRenderedManifests {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$BackendImage,
        [Parameter(Mandatory = $true)][string]$DashboardImage,
        [scriptblock]$CommandRunner
    )
    foreach ($image in @($BackendImage, $DashboardImage)) {
        if ($image -match ':latest$' -or $image -match 'replace-with-ewsp-local-tag') {
            throw (New-EwspKubernetesException "Invalid resolved application image '$image'." 'KUBERNETES_MANIFEST_INVALID' 'Application images' 'Resolve source-aware image tags')
        }
    }
    $paths = Clear-EwspKubernetesRenderedArtifacts $LocalRoot
    $sources = @(
        @{ Name = 'backend'; Source = Join-Path $paths.SourceRoot 'backend\deployment.yaml'; Destination = $paths.BackendRendered; Image = $BackendImage },
        @{ Name = 'dashboard'; Source = Join-Path $paths.SourceRoot 'dashboard\deployment.yaml'; Destination = $paths.DashboardRendered; Image = $DashboardImage }
    )
    foreach ($item in $sources) {
        $before = (Get-FileHash -LiteralPath $item.Source -Algorithm SHA256).Hash
        $result = Invoke-EwspKubectl @('set', 'image', '-f', $item.Source, "$($item.Name)=$($item.Image)", '--local', '-o', 'yaml') $CommandRunner
        if ($result.ExitCode -ne 0) {
            $reason = Protect-EwspDiagnosticText ($result.Output -join ' ')
            throw (New-EwspKubernetesException "Failed to render $($item.Name) Deployment: $reason" 'KUBERNETES_MANIFEST_INVALID' $item.Name 'kubectl set image --local')
        }
        $content = ($result.Output -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
        if ($content -match 'replace-with-ewsp-local-tag' -or -not $content.Contains($item.Image)) {
            throw (New-EwspKubernetesException "Rendered $($item.Name) Deployment did not contain the exact resolved image." 'KUBERNETES_MANIFEST_INVALID' $item.Name 'kubectl set image --local')
        }
        [IO.File]::WriteAllText($item.Destination, $content, [Text.UTF8Encoding]::new($false))
        $after = (Get-FileHash -LiteralPath $item.Source -Algorithm SHA256).Hash
        if ($before -ne $after) { throw "Source manifest changed while rendering: $($item.Source)" }
    }
    [PSCustomObject]@{ Backend = $paths.BackendRendered; Dashboard = $paths.DashboardRendered; Root = $paths.RenderedRoot }
}

function Get-EwspKubernetesApplyPlan {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$Rendered,
        [Parameter(Mandatory = $true)][string]$SecretPath
    )
    $root = Join-Path $LocalRoot 'k8s'
    @(
        [PSCustomObject]@{ Stage = 'NAMESPACE'; Scope = 'Infrastructure'; Files = @((Join-Path $root 'namespace.yaml')) },
        [PSCustomObject]@{ Stage = 'CONFIGMAPS'; Scope = 'Infrastructure'; Files = @((Join-Path $root 'config\postgres-configmap.yaml'), (Join-Path $root 'backend\configmap.yaml')) },
        [PSCustomObject]@{ Stage = 'SECRET'; Scope = 'Infrastructure'; Files = @($SecretPath) },
        [PSCustomObject]@{ Stage = 'POSTGRES'; Scope = 'Infrastructure'; Files = @((Join-Path $root 'postgres\service.yaml'), (Join-Path $root 'postgres\statefulset.yaml')) },
        [PSCustomObject]@{ Stage = 'REDIS'; Scope = 'Infrastructure'; Files = @((Join-Path $root 'redis\service.yaml'), (Join-Path $root 'redis\deployment.yaml')) },
        [PSCustomObject]@{ Stage = 'MINIO'; Scope = 'Infrastructure'; Files = @((Join-Path $root 'minio\service.yaml'), (Join-Path $root 'minio\statefulset.yaml')) },
        [PSCustomObject]@{ Stage = 'BACKEND'; Scope = 'Application'; Files = @((Join-Path $root 'backend\service.yaml'), $Rendered.Backend) },
        [PSCustomObject]@{ Stage = 'DASHBOARD'; Scope = 'Application'; Files = @((Join-Path $root 'dashboard\service.yaml'), $Rendered.Dashboard) }
    )
}

function Assert-EwspKubernetesManifestSet {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][object[]]$ApplyPlan,
        [Parameter(Mandatory = $true)][string]$BackendImage,
        [Parameter(Mandatory = $true)][string]$DashboardImage,
        [scriptblock]$CommandRunner
    )
    $files = @($ApplyPlan | ForEach-Object { $_.Files })
    $examplePath = [IO.Path]::GetFullPath((Join-Path $LocalRoot 'k8s\config\secrets.example.yaml'))
    if (@($files | Where-Object { [IO.Path]::GetFullPath($_) -eq $examplePath }).Count) {
        throw (New-EwspKubernetesException 'Placeholder secrets.example.yaml must never be part of the apply plan.' 'KUBERNETES_MANIFEST_INVALID' 'Kubernetes Secret' 'Build apply plan')
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw (New-EwspKubernetesException "Manifest is missing: $file" 'KUBERNETES_MANIFEST_INVALID' 'Manifest set' 'Validate manifest paths')
        }
        if ([IO.Path]::GetFullPath($file) -ne [IO.Path]::GetFullPath((Join-Path $LocalRoot 'k8s\namespace.yaml')) -and
            ([IO.File]::ReadAllText($file)) -notmatch '(?m)(namespace:\s*ewsp|"namespace"\s*:\s*"ewsp")') {
            throw (New-EwspKubernetesException "Manifest does not explicitly target namespace ewsp: $file" 'KUBERNETES_MANIFEST_INVALID' 'Manifest namespace' 'Validate namespace references')
        }
    }
    $combined = ($files | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
    if ($combined -match 'replace-with-ewsp-local-tag' -or -not $combined.Contains($BackendImage) -or -not $combined.Contains($DashboardImage)) {
        throw (New-EwspKubernetesException 'Rendered manifest set contains an unresolved image placeholder or lacks an exact resolved image.' 'KUBERNETES_MANIFEST_INVALID' 'Application manifests' 'Validate rendered images')
    }
    foreach ($requiredText in @(
        'namespace: ewsp', 'name: ewsp-infrastructure-secrets', 'name: postgres-config', 'name: backend-config',
        'storage: 5Gi', 'storage: 10Gi', 'medium: Memory', 'sizeLimit: 128Mi',
        'imagePullPolicy: IfNotPresent', 'app.kubernetes.io/part-of: ewsp'
    )) {
        if (-not $combined.Contains($requiredText)) {
            throw (New-EwspKubernetesException "Manifest contract is missing '$requiredText'." 'KUBERNETES_MANIFEST_INVALID' 'Manifest set' 'Validate Kubernetes source contract')
        }
    }
    if ($combined -match '(?m)^\s*type:\s*(NodePort|LoadBalancer)\s*$' -or $combined -match '(?m)^\s*image:\s*\S+:latest\s*$') {
        throw (New-EwspKubernetesException 'Manifest set contains a public Service type or latest image tag.' 'KUBERNETES_MANIFEST_INVALID' 'Manifest set' 'Validate local-only service and image policy')
    }
    foreach ($name in @('postgres', 'redis', 'minio', 'backend', 'dashboard')) {
        $serviceFile = @($files | Where-Object { $_ -like "*\$name\service.yaml" })
        $workloadFile = @($files | Where-Object { $_ -like "*\$name\deployment.yaml" -or $_ -like "*\$name\statefulset.yaml" -or $_ -like "*\${name}-deployment.yaml" })
        if (-not $serviceFile.Count -or -not $workloadFile.Count) {
            throw (New-EwspKubernetesException "Service/workload pair is incomplete for $name." 'KUBERNETES_MANIFEST_INVALID' $name 'Validate Service and workload inventory')
        }
        $serviceText = [IO.File]::ReadAllText($serviceFile[0])
        $workloadText = [IO.File]::ReadAllText($workloadFile[0])
        $escapedName = [regex]::Escape($name)
        $serviceSelector = "(?ms)^  selector:\s*\r?\n    app\.kubernetes\.io/name: $escapedName\s*\r?\n    app\.kubernetes\.io/part-of: ewsp\s*$"
        $workloadSelector = "(?ms)^  selector:\s*\r?\n    matchLabels:\s*\r?\n      app\.kubernetes\.io/name: $escapedName\s*\r?\n      app\.kubernetes\.io/part-of: ewsp\s*$"
        if ($serviceText -notmatch $serviceSelector -or $workloadText -notmatch $workloadSelector) {
            throw (New-EwspKubernetesException "Service selector does not match the $name workload identity." 'KUBERNETES_MANIFEST_INVALID' $name 'Validate Service selectors')
        }
    }
    $arguments = @('apply', '--dry-run=client', '--validate=true')
    foreach ($file in $files) { $arguments += @('-f', $file) }
    $result = Invoke-EwspKubectl $arguments $CommandRunner
    if ($result.ExitCode -ne 0) {
        $reason = Protect-EwspDiagnosticText ($result.Output -join ' ')
        throw (New-EwspKubernetesException "Strict client manifest validation failed: $reason" 'KUBERNETES_MANIFEST_INVALID' 'Manifest set' 'kubectl apply --dry-run=client --validate=true')
    }
    $true
}

function Invoke-EwspKubernetesApplyStages {
    param(
        [Parameter(Mandatory = $true)][object[]]$ApplyPlan,
        [Parameter(Mandatory = $true)][ValidateSet('Infrastructure', 'Application')][string]$Scope
    )
    foreach ($stage in @($ApplyPlan | Where-Object Scope -eq $Scope)) {
        Write-Host "      $($stage.Stage.ToLowerInvariant())"
        foreach ($file in $stage.Files) {
            try {
                Invoke-EwspKubectlStreaming @('apply', '-f', $file) "Kubernetes apply failed for $($stage.Stage)"
            } catch {
                $_.Exception.Data['Category'] = 'KUBERNETES_APPLY_FAILURE'
                $_.Exception.Data['Component'] = $stage.Stage.ToLowerInvariant()
                throw
            }
        }
    }
}

function Get-EwspKubernetesWorkloadDefinitions {
    @(
        [PSCustomObject]@{ Name = 'postgres'; DisplayName = 'PostgreSQL'; ControllerType = 'statefulset'; ControllerKind = 'StatefulSet' },
        [PSCustomObject]@{ Name = 'redis'; DisplayName = 'Redis'; ControllerType = 'deployment'; ControllerKind = 'Deployment' },
        [PSCustomObject]@{ Name = 'minio'; DisplayName = 'MinIO'; ControllerType = 'statefulset'; ControllerKind = 'StatefulSet' },
        [PSCustomObject]@{ Name = 'backend'; DisplayName = 'Backend'; ControllerType = 'deployment'; ControllerKind = 'Deployment' },
        [PSCustomObject]@{ Name = 'dashboard'; DisplayName = 'Dashboard'; ControllerType = 'deployment'; ControllerKind = 'Deployment' }
    )
}

function Get-EwspKubernetesPodReason {
    param($Pod)
    if (-not $Pod) { return 'Missing' }
    $containerStatuses = if ($Pod.status.PSObject.Properties['containerStatuses']) { @($Pod.status.containerStatuses) } else { @() }
    foreach ($status in $containerStatuses) {
        $state = if ($status.PSObject.Properties['state']) { $status.state } else { $null }
        $lastState = if ($status.PSObject.Properties['lastState']) { $status.lastState } else { $null }
        $waiting = if ($state -and $state.PSObject.Properties['waiting']) { $state.waiting } else { $null }
        $terminated = if ($state -and $state.PSObject.Properties['terminated']) { $state.terminated } else { $null }
        $lastTerminated = if ($lastState -and $lastState.PSObject.Properties['terminated']) { $lastState.terminated } else { $null }
        if ($waiting -and $waiting.reason) { return [string]$waiting.reason }
        if ($terminated -and $terminated.reason) { return [string]$terminated.reason }
        if ($lastTerminated -and $lastTerminated.reason -eq 'OOMKilled') { return 'OOMKilled' }
    }
    $conditions = if ($Pod.status.PSObject.Properties['conditions']) { @($Pod.status.conditions) } else { @() }
    $scheduled = @($conditions | Where-Object type -eq 'PodScheduled')
    if ($scheduled.Count -and $scheduled[0].status -eq 'False') {
        return "$(if ($scheduled[0].reason) { $scheduled[0].reason } else { 'Unschedulable' }): $($scheduled[0].message)".Trim()
    }
    if ($Pod.status.PSObject.Properties['phase'] -and $Pod.status.phase) { return [string]$Pod.status.phase }
    'Unknown'
}

function Get-EwspKubernetesWorkloadSnapshot {
    param([scriptblock]$CommandRunner)
    $snapshots = @()
    foreach ($definition in Get-EwspKubernetesWorkloadDefinitions) {
        $controllerResult = Invoke-EwspKubectl @('get', $definition.ControllerType, $definition.Name, '-n', $script:EwspKubernetesNamespace, '-o', 'json') $CommandRunner
        $controller = $null
        if ($controllerResult.ExitCode -eq 0) {
            try { $controller = ($controllerResult.Output -join "`n") | ConvertFrom-Json } catch { }
        }
        $podResult = Invoke-EwspKubectl @('get', 'pods', '-n', $script:EwspKubernetesNamespace, '-l', "app.kubernetes.io/name=$($definition.Name)", '-o', 'json') $CommandRunner
        $pod = $null
        if ($podResult.ExitCode -eq 0) {
            try {
                $podList = ($podResult.Output -join "`n") | ConvertFrom-Json
                $pods = @($podList.items | Sort-Object { $_.metadata.creationTimestamp } -Descending | Select-Object -First 1)
                if ($pods.Count) { $pod = $pods[0] }
            } catch { }
        }
        $containers = @()
        if ($pod -and $pod.spec.PSObject.Properties['containers']) { $containers = @($pod.spec.containers) }
        $statuses = @()
        if ($pod -and $pod.status.PSObject.Properties['containerStatuses']) { $statuses = @($pod.status.containerStatuses) }
        $container = if ($containers.Count) { $containers[0] } else { $null }
        $containerStatus = if ($statuses.Count) { $statuses[0] } else { $null }
        $desired = if ($controller) { [int]$controller.spec.replicas } else { 0 }
        $readyReplicas = if ($controller -and $controller.status.PSObject.Properties['readyReplicas']) { [int]$controller.status.readyReplicas } else { 0 }
        $snapshots += [PSCustomObject]@{
            Name = $definition.Name
            DisplayName = $definition.DisplayName
            ControllerType = $definition.ControllerKind
            ControllerExists = $null -ne $controller
            Desired = $desired
            ReadyReplicas = $readyReplicas
            Ready = [bool]($controller -and $desired -eq 1 -and $readyReplicas -eq 1 -and $containerStatus -and $containerStatus.ready)
            PodName = if ($pod) { $pod.metadata.name } else { $null }
            PodPhase = if ($pod -and $pod.status.PSObject.Properties['phase']) { $pod.status.phase } elseif ($pod) { 'Unknown' } else { 'Missing' }
            Restarts = if ($containerStatus -and $containerStatus.PSObject.Properties['restartCount']) { [int]$containerStatus.restartCount } else { 0 }
            Reason = Get-EwspKubernetesPodReason $pod
            Image = if ($container) { $container.image } elseif ($controller) { $controller.spec.template.spec.containers[0].image } else { $null }
            ImageId = if ($containerStatus -and $containerStatus.PSObject.Properties['imageID']) { $containerStatus.imageID } else { $null }
        }
    }
    $snapshots
}

function Get-EwspKubernetesPvcSnapshot {
    param([scriptblock]$CommandRunner)
    $result = Invoke-EwspKubectl @('get', 'pvc', '-n', $script:EwspKubernetesNamespace, '-o', 'json') $CommandRunner
    if ($result.ExitCode -ne 0) { return @() }
    try {
        $object = ($result.Output -join "`n") | ConvertFrom-Json
        @($object.items | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.metadata.name
                Status = $_.status.phase
                Capacity = if ($_.status.PSObject.Properties['capacity']) { $_.status.capacity.storage } else { '<pending>' }
                StorageClass = $_.spec.storageClassName
                Volume = $_.spec.volumeName
            }
        })
    } catch { @() }
}

function Get-EwspKubernetesServiceSnapshot {
    param([scriptblock]$CommandRunner)
    $result = Invoke-EwspKubectl @('get', 'services', '-n', $script:EwspKubernetesNamespace, '-o', 'json') $CommandRunner
    if ($result.ExitCode -ne 0) { return @() }
    try {
        $object = ($result.Output -join "`n") | ConvertFrom-Json
        @($object.items | ForEach-Object {
            [PSCustomObject]@{ Name = $_.metadata.name; Type = $_.spec.type; Ports = @($_.spec.ports.port) }
        })
    } catch { @() }
}

function Show-EwspKubernetesFailureDiagnostics {
    param(
        [hashtable]$EnvironmentValues,
        [scriptblock]$CommandRunner
    )
    Write-Host ''
    Write-Host 'Kubernetes diagnostics (bounded)' -ForegroundColor Yellow
    $snapshots = @(Get-EwspKubernetesWorkloadSnapshot $CommandRunner)
    foreach ($snapshot in $snapshots) {
        if ($snapshot.Ready) { continue }
        Write-Host ("  {0,-10} controller={1} desired={2} ready={3} pod={4} phase={5} restarts={6} reason={7} image={8}" -f `
            $snapshot.Name, $(if ($snapshot.ControllerExists) { $snapshot.ControllerType } else { 'Missing' }), `
            $snapshot.Desired, $snapshot.ReadyReplicas, $(if ($snapshot.PodName) { $snapshot.PodName } else { '<none>' }), `
            $snapshot.PodPhase, $snapshot.Restarts, $snapshot.Reason, $(if ($snapshot.Image) { $snapshot.Image } else { '<none>' }))
        if ($snapshot.PodName) {
            $logs = Invoke-EwspKubectl @('logs', '-n', $script:EwspKubernetesNamespace, $snapshot.PodName, '--tail=40') $CommandRunner
            if ($logs.ExitCode -eq 0 -and $logs.Output.Count) {
                Write-Host '    recent logs:'
                @($logs.Output | Select-Object -Last 40) | ForEach-Object {
                    Write-Host "      $(Protect-EwspDiagnosticText ([string]$_) $EnvironmentValues)"
                }
            }
            $events = Invoke-EwspKubectl @('get', 'events', '-n', $script:EwspKubernetesNamespace, '--field-selector', "involvedObject.name=$($snapshot.PodName)", '--sort-by=.lastTimestamp', '-o', 'custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message', '--no-headers') $CommandRunner
            if ($events.ExitCode -eq 0 -and $events.Output.Count) {
                Write-Host '    recent events:'
                @($events.Output | Select-Object -Last 12) | ForEach-Object {
                    Write-Host "      $(Protect-EwspDiagnosticText ([string]$_) $EnvironmentValues)"
                }
            }
        }
    }
    foreach ($pvc in @(Get-EwspKubernetesPvcSnapshot $CommandRunner)) {
        if ($pvc.Status -ne 'Bound') {
            Write-Host "  PVC $($pvc.Name): status=$($pvc.Status) capacity=$($pvc.Capacity) storageClass=$($pvc.StorageClass)"
        }
    }
}

function Wait-EwspKubernetesWorkloads {
    param(
        [hashtable]$EnvironmentValues,
        [scriptblock]$CommandRunner
    )
    $waits = @(
        @{ Type = 'statefulset'; Name = 'postgres'; Timeout = '180s' },
        @{ Type = 'deployment'; Name = 'redis'; Timeout = '120s' },
        @{ Type = 'statefulset'; Name = 'minio'; Timeout = '180s' },
        @{ Type = 'deployment'; Name = 'backend'; Timeout = '240s' },
        @{ Type = 'deployment'; Name = 'dashboard'; Timeout = '120s' }
    )
    try {
        foreach ($wait in $waits) {
            $result = Invoke-EwspKubectl @('rollout', 'status', "$($wait.Type)/$($wait.Name)", '-n', $script:EwspKubernetesNamespace, "--timeout=$($wait.Timeout)") $CommandRunner
            if ($result.ExitCode -ne 0) {
                $reason = Protect-EwspDiagnosticText ($result.Output -join ' ') $EnvironmentValues
                throw "Rollout failed for $($wait.Name): $reason"
            }
            Write-Host "      $($wait.Name) Ready"
        }
        foreach ($claim in @('postgres-data-postgres-0', 'minio-data-minio-0')) {
            $result = Invoke-EwspKubectl @('wait', '-n', $script:EwspKubernetesNamespace, '--for=jsonpath={.status.phase}=Bound', "pvc/$claim", '--timeout=120s') $CommandRunner
            if ($result.ExitCode -ne 0) { throw "PVC did not become Bound: $claim" }
            Write-Host "      $claim Bound"
        }
        $snapshots = @(Get-EwspKubernetesWorkloadSnapshot $CommandRunner)
        $notReady = @($snapshots | Where-Object { -not $_.Ready })
        if ($notReady.Count) { throw "Workloads remained non-ready: $(@($notReady.Name) -join ', ')" }
    } catch {
        Show-EwspKubernetesFailureDiagnostics $EnvironmentValues $CommandRunner
        $exception = New-EwspKubernetesException $_.Exception.Message 'KUBERNETES_READINESS_FAILURE' 'EWSP workloads' 'Wait for Kubernetes rollouts and PVC binding'
        throw $exception
    }
    Get-EwspKubernetesWorkloadSnapshot $CommandRunner
}

function Wait-EwspKubernetesInfrastructure {
    param(
        [hashtable]$EnvironmentValues,
        [scriptblock]$CommandRunner
    )
    try {
        foreach ($target in @('statefulset/postgres', 'deployment/redis', 'statefulset/minio')) {
            $result = Invoke-EwspKubectl @('rollout', 'status', $target, '-n', $script:EwspKubernetesNamespace, '--timeout=180s') $CommandRunner
            if ($result.ExitCode -ne 0) { throw "Infrastructure rollout failed for $target." }
        }
        foreach ($claim in @('postgres-data-postgres-0', 'minio-data-minio-0')) {
            $result = Invoke-EwspKubectl @('wait', '-n', $script:EwspKubernetesNamespace, '--for=jsonpath={.status.phase}=Bound', "pvc/$claim", '--timeout=120s') $CommandRunner
            if ($result.ExitCode -ne 0) { throw "PVC did not become Bound: $claim" }
        }
        Write-Host '      PostgreSQL, Redis, MinIO, and persistent claims are Ready'
    } catch {
        Show-EwspKubernetesFailureDiagnostics $EnvironmentValues $CommandRunner
        throw (New-EwspKubernetesException $_.Exception.Message 'KUBERNETES_READINESS_FAILURE' 'Kubernetes infrastructure' 'Wait for infrastructure rollouts and PVC binding')
    }
    $true
}

function Assert-EwspKubernetesCommandResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Check,
        [string]$ExpectedText
    )
    $output = ($Result.Output -join "`n").Trim()
    if ($Result.ExitCode -ne 0 -or ($ExpectedText -and -not $output.Contains($ExpectedText))) {
        throw (New-EwspKubernetesException "Kubernetes verification failed for $Check." 'KUBERNETES_VERIFICATION_FAILURE' $Check $Check)
    }
    $output
}

function Assert-EwspKubernetesFunctionality {
    param([scriptblock]$CommandRunner)
    $postgres = Invoke-EwspKubectl @('exec', '-n', $script:EwspKubernetesNamespace, 'postgres-0', '--', 'sh', '-c', 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"') $CommandRunner
    Assert-EwspKubernetesCommandResult $postgres 'PostgreSQL pg_isready' 'accepting connections' | Out-Null
    $redisSnapshot = @(Get-EwspKubernetesWorkloadSnapshot $CommandRunner | Where-Object Name -eq 'redis')[0]
    $redis = Invoke-EwspKubectl @('exec', '-n', $script:EwspKubernetesNamespace, $redisSnapshot.PodName, '--', 'redis-cli', 'ping') $CommandRunner
    Assert-EwspKubernetesCommandResult $redis 'Redis PING' 'PONG' | Out-Null
    foreach ($path in @('/minio/health/live', '/minio/health/ready')) {
        $minio = Invoke-EwspKubectl @('exec', '-n', $script:EwspKubernetesNamespace, 'minio-0', '--', 'curl', '-fsS', '-o', '/dev/null', '-w', '%{http_code}', "http://localhost:9000$path") $CommandRunner
        Assert-EwspKubernetesCommandResult $minio "MinIO $path" '200' | Out-Null
    }
    $snapshots = @(Get-EwspKubernetesWorkloadSnapshot $CommandRunner)
    $backendPod = @($snapshots | Where-Object Name -eq 'backend')[0].PodName
    $dashboardPod = @($snapshots | Where-Object Name -eq 'dashboard')[0].PodName
    $dns = Invoke-EwspKubectl @('exec', '-n', $script:EwspKubernetesNamespace, $backendPod, '--', 'getent', 'hosts', 'postgres', 'redis', 'minio', 'backend') $CommandRunner
    Assert-EwspKubernetesCommandResult $dns 'Kubernetes DNS contracts' 'postgres.ewsp.svc.cluster.local' | Out-Null
    foreach ($check in @(
        @{ Name = 'Backend health'; Args = @('exec', '-n', $script:EwspKubernetesNamespace, $backendPod, '--', 'curl', '-fsS', 'http://backend:8080/api/health'); Expected = 'UP' },
        @{ Name = 'Dashboard root'; Args = @('exec', '-n', $script:EwspKubernetesNamespace, $dashboardPod, '--', 'wget', '-q', '-O', '/dev/null', 'http://dashboard/'); Expected = $null },
        @{ Name = 'Dashboard backend proxy'; Args = @('exec', '-n', $script:EwspKubernetesNamespace, $dashboardPod, '--', 'wget', '-q', '-O', '-', 'http://dashboard/api/health'); Expected = 'UP' }
    )) {
        $result = Invoke-EwspKubectl $check.Args $CommandRunner
        Assert-EwspKubernetesCommandResult $result $check.Name $check.Expected | Out-Null
        Write-Host "      $($check.Name) passed"
    }
    Write-Host '      PostgreSQL, Redis, MinIO, and Kubernetes DNS checks passed'
    $true
}

function Resolve-EwspKubernetesPortForwardAction {
    param(
        [bool]$ManagedProcessActive,
        [bool]$ManagedProbeHealthy,
        [bool]$PortOccupied
    )
    if ($ManagedProcessActive -and $ManagedProbeHealthy) { return 'REUSE' }
    if ($PortOccupied -and -not $ManagedProcessActive) { return 'CONFLICT' }
    'START'
}

function Test-EwspKubernetesDashboardEndpoint {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$Path = '/'
    )
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$Port$Path" -TimeoutSec 3
        [PSCustomObject]@{ Success = [int]$response.StatusCode -eq 200; StatusCode = [int]$response.StatusCode; Content = [string]$response.Content }
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        [PSCustomObject]@{ Success = $false; StatusCode = $status; Content = '' }
    }
}

function Test-EwspKubernetesWebSocketUpgrade {
    param([Parameter(Mandatory = $true)][int]$Port)
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $cancellation = New-Object System.Threading.CancellationTokenSource
    $cancellation.CancelAfter([TimeSpan]::FromSeconds(5))
    try {
        $socket.ConnectAsync([Uri]"ws://localhost:$Port/ws", $cancellation.Token).GetAwaiter().GetResult()
        $connected = $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open
        if ($connected) {
            $socket.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'EWSP verification', [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
        $connected
    } catch { $false } finally {
        $socket.Dispose()
        $cancellation.Dispose()
    }
}

function Get-EwspManagedKubernetesPortForward {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [scriptblock]$ProcessProvider,
        [scriptblock]$Probe
    )
    $paths = Get-EwspKubernetesPaths $LocalRoot
    if (-not (Test-Path -LiteralPath $paths.PortForwardState -PathType Leaf)) {
        return [PSCustomObject]@{ Active = $false; Healthy = $false; Process = $null; State = $null; Url = $null }
    }
    try { $state = Get-Content -Raw -LiteralPath $paths.PortForwardState | ConvertFrom-Json } catch {
        return [PSCustomObject]@{ Active = $false; Healthy = $false; Process = $null; State = $null; Url = $null }
    }
    if (-not $ProcessProvider) {
        $ProcessProvider = { param($id) Get-Process -Id $id -ErrorAction SilentlyContinue }
    }
    $process = & $ProcessProvider ([int]$state.ProcessId)
    $active = $false
    if ($process) {
        try {
            $active = $process.ProcessName -eq 'kubectl' -and
                [string]$process.StartTime.ToUniversalTime().Ticks -eq [string]$state.StartTimeUtcTicks -and
                $state.Namespace -eq $script:EwspKubernetesNamespace -and $state.Service -eq 'dashboard'
        } catch { $active = $false }
    }
    $healthy = $false
    if ($active) {
        if ($Probe) { $healthy = [bool](& $Probe ([int]$state.LocalPort)) }
        else { $healthy = (Test-EwspKubernetesDashboardEndpoint ([int]$state.LocalPort)).Success }
    }
    [PSCustomObject]@{
        Active = $active; Healthy = $healthy; Process = $process; State = $state
        Url = if ($active) { "http://localhost:$($state.LocalPort)" } else { $null }
    }
}

function Assert-EwspKubernetesAccessPortAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $managed = Get-EwspManagedKubernetesPortForward $LocalRoot
    $occupied = @(Get-EwspOccupiedTcpPorts) -contains $Port
    $action = Resolve-EwspKubernetesPortForwardAction $managed.Active $managed.Healthy $occupied
    if ($action -eq 'CONFLICT') {
        throw (New-EwspKubernetesException "Dashboard port $Port is occupied by a process not managed by EWSP Kubernetes orchestration. It was not stopped." 'KUBERNETES_PORT_CONFLICT' 'Dashboard access' "Listen on localhost:$Port")
    }
    $action
}

function Stop-EwspKubernetesPortForward {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [switch]$Quiet
    )
    $paths = Get-EwspKubernetesPaths $LocalRoot
    $managed = Get-EwspManagedKubernetesPortForward $LocalRoot
    if ($managed.Active) {
        Stop-Process -Id $managed.Process.Id -ErrorAction Stop
        $managed.Process.WaitForExit(5000) | Out-Null
        if (-not $Quiet) { Write-Host "Stopped EWSP-managed dashboard port-forward (PID $($managed.Process.Id))." }
    } elseif (-not $Quiet) {
        Write-Host 'No active EWSP-managed dashboard port-forward.'
    }
    if (Test-Path -LiteralPath $paths.PortForwardState) { Remove-Item -LiteralPath $paths.PortForwardState -Force }
    $managed.Active
}

function Start-EwspKubernetesPortForward {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $paths = Get-EwspKubernetesPaths $LocalRoot
    $managed = Get-EwspManagedKubernetesPortForward $LocalRoot
    $occupied = @(Get-EwspOccupiedTcpPorts) -contains $Port
    $action = Resolve-EwspKubernetesPortForwardAction $managed.Active $managed.Healthy $occupied
    if ($action -eq 'REUSE') {
        Write-Host "      reused managed dashboard port-forward (PID $($managed.Process.Id))"
        return $managed
    }
    if ($action -eq 'CONFLICT') {
        throw (New-EwspKubernetesException "Dashboard port $Port is occupied by a process not managed by EWSP Kubernetes orchestration. It was not stopped." 'KUBERNETES_PORT_CONFLICT' 'Dashboard access' "kubectl port-forward service/dashboard $Port`:80")
    }
    if ($managed.Active) { Stop-EwspKubernetesPortForward $LocalRoot -Quiet | Out-Null }
    New-Item -ItemType Directory -Path $paths.TemporaryRoot -Force | Out-Null
    foreach ($log in @($paths.PortForwardOutput, $paths.PortForwardError)) {
        $safeLog = Assert-EwspSafeTemporaryPath $LocalRoot $log
        if (Test-Path -LiteralPath $safeLog) { Remove-Item -LiteralPath $safeLog -Force }
    }
    $kubectl = Get-Command kubectl -ErrorAction Stop
    $arguments = @('port-forward', '-n', $script:EwspKubernetesNamespace, 'service/dashboard', "$Port`:80")
    $startArguments = @{
        FilePath = $kubectl.Source; ArgumentList = $arguments; PassThru = $true
        RedirectStandardOutput = $paths.PortForwardOutput; RedirectStandardError = $paths.PortForwardError
    }
    if ((Get-EwspHostPlatform).Name -eq 'Windows') { $startArguments.WindowStyle = 'Hidden' }
    $process = Start-Process @startArguments
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $healthy = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { break }
        $probe = Test-EwspKubernetesDashboardEndpoint $Port
        if ($probe.Success) { $healthy = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $healthy) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
        $reason = if (Test-Path -LiteralPath $paths.PortForwardError) {
            Protect-EwspDiagnosticText ((Get-Content -LiteralPath $paths.PortForwardError -Tail 20) -join ' ')
        } else { 'dashboard endpoint did not become reachable' }
        throw (New-EwspKubernetesException "Managed dashboard port-forward failed: $reason" 'KUBERNETES_PORT_CONFLICT' 'Dashboard access' "kubectl port-forward service/dashboard $Port`:80")
    }
    $state = [ordered]@{
        ProcessId = $process.Id
        StartTimeUtcTicks = [string]$process.StartTime.ToUniversalTime().Ticks
        Namespace = $script:EwspKubernetesNamespace
        Service = 'dashboard'
        LocalPort = $Port
        RemotePort = 80
        StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($paths.PortForwardState, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host "      started managed dashboard port-forward (PID $($process.Id))"
    Get-EwspManagedKubernetesPortForward $LocalRoot
}

function Assert-EwspKubernetesDashboardAccess {
    param([Parameter(Mandatory = $true)][int]$Port)
    $root = Test-EwspKubernetesDashboardEndpoint $Port '/'
    $route = Test-EwspKubernetesDashboardEndpoint $Port '/complaints'
    $api = Test-EwspKubernetesDashboardEndpoint $Port '/api/health'
    $missing = Test-EwspKubernetesDashboardEndpoint $Port '/assets/ewsp-missing-verification.js'
    $webSocket = Test-EwspKubernetesWebSocketUpgrade $Port
    if (-not $root.Success -or -not $route.Success -or $root.Content -cne $route.Content -or
        -not $api.Success -or $api.Content -notmatch 'UP' -or $missing.StatusCode -ne 404 -or -not $webSocket) {
        throw (New-EwspKubernetesException 'Dashboard port-forward verification failed for the SPA, missing asset, backend proxy, or WebSocket upgrade.' 'KUBERNETES_VERIFICATION_FAILURE' 'Dashboard access' "http://localhost:$Port")
    }
    Write-Host '      dashboard / and /complaints: HTTP 200 (same SPA shell)'
    Write-Host '      dashboard missing asset: HTTP 404'
    Write-Host '      dashboard /api/health: HTTP 200'
    Write-Host '      dashboard /ws: WebSocket upgraded'
    $true
}

function Get-EwspRunningKubernetesImage {
    param(
        [Parameter(Mandatory = $true)][string]$Deployment,
        [scriptblock]$CommandRunner
    )
    $result = Invoke-EwspKubectl @('get', 'deployment', $Deployment, '-n', $script:EwspKubernetesNamespace, '-o', 'json') $CommandRunner
    if ($result.ExitCode -ne 0) { return $null }
    try { (($result.Output -join "`n") | ConvertFrom-Json).spec.template.spec.containers[0].image } catch { $null }
}

function Show-EwspKubernetesStatusSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)]$EnvironmentInfo,
        [scriptblock]$CommandRunner
    )
    $kubernetes = $EnvironmentInfo.Kubernetes
    Write-Host 'Environment'
    Write-Host '-----------'
    Write-Host "Context: $($kubernetes.Context)"
    Write-Host "Server:  $($kubernetes.ServerVersion)"
    foreach ($node in $kubernetes.Nodes) { Write-Host "Node:    $($node.Name) $(if ($node.Ready) { 'Ready' } else { 'NotReady' })" }
    Write-Host ''
    Write-Host 'Applications'
    Write-Host '------------'
    $snapshots = @(Get-EwspKubernetesWorkloadSnapshot $CommandRunner)
    foreach ($snapshot in $snapshots) {
        $state = if (-not $snapshot.ControllerExists) { 'Missing' } elseif ($snapshot.Desired -eq 0) { 'Stopped' } elseif ($snapshot.Ready) { 'Ready' } else { $snapshot.Reason }
        Write-Host ("{0,-10} {1,-11} {2,-18} ready={3}/{4} restarts={5} image={6}" -f `
            $snapshot.Name, $snapshot.ControllerType, $(if ($snapshot.PodName) { $snapshot.PodName } else { '<none>' }), `
            $snapshot.ReadyReplicas, $snapshot.Desired, $snapshot.Restarts, $(if ($snapshot.Image) { $snapshot.Image } else { '<none>' }))
        if ($state -notin @('Ready', 'Stopped')) { Write-Host "             state=$state" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host 'Storage'
    Write-Host '-------'
    $pvcs = @(Get-EwspKubernetesPvcSnapshot $CommandRunner)
    foreach ($name in @('postgres-data-postgres-0', 'minio-data-minio-0')) {
        $pvc = @($pvcs | Where-Object Name -eq $name)
        if ($pvc.Count) { Write-Host ("{0,-28} {1,-8} {2}" -f $name, $pvc[0].Status, $pvc[0].Capacity) }
        else { Write-Host ("{0,-28} Missing" -f $name) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host 'Services'
    Write-Host '--------'
    $services = @(Get-EwspKubernetesServiceSnapshot $CommandRunner)
    foreach ($name in @('postgres', 'redis', 'minio', 'backend', 'dashboard')) {
        $service = @($services | Where-Object Name -eq $name)
        if ($service.Count) { Write-Host ("{0,-10} {1,-10} ports={2}" -f $name, $service[0].Type, (@($service[0].Ports) -join ',')) }
        else { Write-Host ("{0,-10} Missing" -f $name) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host 'Access'
    Write-Host '------'
    $forward = Get-EwspManagedKubernetesPortForward $LocalRoot
    if ($forward.Active -and $forward.Healthy) { Write-Host "Dashboard: active $($forward.Url) (PID $($forward.Process.Id))" }
    elseif ($forward.Active) { Write-Host "Dashboard: managed process active but endpoint unhealthy (PID $($forward.Process.Id))" -ForegroundColor Yellow }
    else { Write-Host 'Dashboard: inactive' }
    [PSCustomObject]@{ Workloads = $snapshots; Pvcs = $pvcs; Services = $services; PortForward = $forward }
}

function Invoke-EwspKubernetesStatus {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $environment = Get-EwspKubernetesEnvironment
    Assert-EwspKubernetesEnvironment $environment -RequireDocker | Out-Null
    Show-EwspKubernetesStatusSnapshot $LocalRoot $environment | Out-Null
}

function Wait-EwspKubernetesPodsStopped {
    param(
        [int]$TimeoutSeconds = 120,
        [scriptblock]$CommandRunner,
        [scriptblock]$SleepAction
    )
    if (-not $SleepAction) { $SleepAction = { Start-Sleep -Milliseconds 500 } }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-EwspKubectl @('get', 'pods', '-n', $script:EwspKubernetesNamespace, '-l', 'app.kubernetes.io/part-of=ewsp', '-o', 'json') $CommandRunner
        if ($result.ExitCode -ne 0) { throw 'Unable to inspect EWSP Pods while stopping workloads.' }
        try {
            $podList = (($result.Output -join "`n") | ConvertFrom-Json)
            $count = @($podList.items).Count
        } catch { $count = -1 }
        if ($count -eq 0) { return $true }
        & $SleepAction
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for EWSP Pods to stop; $count Pod(s) remain."
}

function Invoke-EwspKubernetesStop {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $environment = Get-EwspKubernetesEnvironment
    Assert-EwspKubernetesEnvironment $environment -RequireDocker | Out-Null
    Stop-EwspKubernetesPortForward $LocalRoot | Out-Null
    foreach ($target in @(
        @{ Type = 'deployment'; Names = @('dashboard', 'backend', 'redis') },
        @{ Type = 'statefulset'; Names = @('minio', 'postgres') }
    )) {
        foreach ($name in $target.Names) {
            $result = Invoke-EwspKubectl @('get', $target.Type, $name, '-n', $script:EwspKubernetesNamespace, '-o', 'name')
            if ($result.ExitCode -eq 0) {
                Invoke-EwspKubectlStreaming @('scale', $target.Type, $name, '-n', $script:EwspKubernetesNamespace, '--replicas=0') "Failed to stop Kubernetes workload $name"
            }
        }
    }
    Wait-EwspKubernetesPodsStopped | Out-Null
    $pvcs = @(Get-EwspKubernetesPvcSnapshot)
    Write-Host 'EWSP Kubernetes workloads stopped. Services, configuration, Secret, and PVCs were preserved.' -ForegroundColor Green
    foreach ($pvc in $pvcs) { Write-Host "  PVC $($pvc.Name): $($pvc.Status) $($pvc.Capacity)" }
}

function Invoke-EwspKubernetesUp {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $phaseNames = @(
        'K8S_ENVIRONMENT', 'REPOSITORY_STATE', 'IMAGE_RESOLUTION', 'SECRET_PREPARATION',
        'MANIFEST_VALIDATION', 'INFRASTRUCTURE_APPLY', 'APPLICATION_APPLY', 'READINESS_WAIT',
        'FINAL_VERIFICATION', 'ACCESS_SETUP'
    )
    $completed = New-Object System.Collections.Generic.List[string]
    $context = @{
        Environment = $null; Configuration = $null; EnvironmentValues = $null; Ports = $null
        ImagePlan = $null; PreviousTagEnvironment = $null; SecretPath = $null; Rendered = $null
        ApplyPlan = $null; States = $null; PortForward = $null; DashboardPort = $null
        OldBackendImage = $null; OldDashboardImage = $null
    }
    $total = $phaseNames.Count

    Invoke-EwspUpPhase 1 $total $phaseNames[0] 'Detecting Kubernetes environment' {
        $runtime = Get-EwspRuntimeEnvironment
        Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $runtime | Out-Null
        $context.Environment = Get-EwspKubernetesEnvironment -RuntimeEnvironment $runtime
        Assert-EwspKubernetesEnvironment $context.Environment -RequireDocker | Out-Null
        Show-EwspKubernetesEnvironment $context.Environment
    } $completed $phaseNames[1..($total - 1)] $context.Environment 'Detect kubectl, Docker Desktop Kubernetes, nodes, namespace, and storage' 'Kubernetes environment' -WorkflowName 'k8s-up' | Out-Null

    Invoke-EwspUpPhase 2 $total $phaseNames[1] 'Checking repository state' {
        if (-not (Test-Path -LiteralPath (Join-Path $LocalRoot '.env') -PathType Leaf)) {
            throw '.env is missing. Run .\ewsp.ps1 setup first; no Kubernetes resources were changed.'
        }
        $context.Configuration = Get-EwspConfiguration $LocalRoot
        $context.EnvironmentValues = Get-EwspEffectiveEnvironmentValues $LocalRoot
        $context.Ports = @(Assert-EwspEnvironmentConfiguration $context.EnvironmentValues)
        foreach ($repository in @($context.Configuration.Repositories | Where-Object { $_.ContainsKey('Image') })) {
            $path = Resolve-EwspRepositoryPath $LocalRoot $repository
            $state = Get-EwspRepositoryState $path $repository.ExpectedIdentity $repository.PrimaryBranch
            if ($state.Classification -eq 'MISSING' -or $state.Classification -eq 'IDENTITY_MISMATCH') {
                throw "$($repository.Name) repository state is $($state.Classification). No files were changed."
            }
            Assert-EwspApplicationBuildAssets $path $repository
            Write-Host ("      {0,-14} {1} {2}" -f $repository.Name, $state.ShortCommit, $(if ($state.Dirty) { 'dirty' } else { 'clean' }))
        }
    } $completed $phaseNames[2..($total - 1)] $context.Environment 'Validate sibling identities, source state, Docker assets, and .env' 'EWSP repositories' -WorkflowName 'k8s-up' | Out-Null

    Invoke-EwspUpPhase 3 $total $phaseNames[2] 'Resolving and preparing application images' {
        $context.ImagePlan = New-EwspImagePlan $LocalRoot $context.Configuration $context.EnvironmentValues
        $tagEnvironment = @{}
        foreach ($descriptor in $context.ImagePlan.Descriptors) {
            if ($descriptor.Tag -match ':latest$') { throw "Resolved image must not use latest: $($descriptor.Tag)" }
            $tagEnvironment[$descriptor.EnvironmentName] = $descriptor.Tag
            Write-Host "      resolved $($descriptor.Service): $($descriptor.Tag)"
        }
        $context.PreviousTagEnvironment = Set-EwspProcessEnvironment $tagEnvironment
        Invoke-EwspImageBuilds $LocalRoot $context.Environment $context.ImagePlan.Descriptors
    } $completed $phaseNames[3..($total - 1)] $context.Environment 'Resolve, reuse, or build source-aware local images' 'Application images' -WorkflowName 'k8s-up' | Out-Null

    try {
        Invoke-EwspUpPhase 4 $total $phaseNames[3] 'Preparing local Kubernetes Secret' {
            $context.SecretPath = New-EwspKubernetesSecretArtifact $LocalRoot $context.EnvironmentValues
            Write-Host '      generated ignored local Secret artifact; values hidden'
        } $completed $phaseNames[4..($total - 1)] $context.Environment 'Generate real local Secret from .env' 'Kubernetes Secret' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 5 $total $phaseNames[4] 'Rendering and validating manifests' {
            $backendDescriptor = @($context.ImagePlan.Descriptors | Where-Object Service -eq 'backend')[0]
            $dashboardDescriptor = @($context.ImagePlan.Descriptors | Where-Object Service -eq 'dashboard')[0]
            $context.Rendered = New-EwspKubernetesRenderedManifests $LocalRoot $backendDescriptor.Tag $dashboardDescriptor.Tag
            $context.ApplyPlan = @(Get-EwspKubernetesApplyPlan $LocalRoot $context.Rendered $context.SecretPath)
            Assert-EwspKubernetesManifestSet $LocalRoot $context.ApplyPlan $backendDescriptor.Tag $dashboardDescriptor.Tag | Out-Null
            $dashboardPort = @($context.Ports | Where-Object Service -eq 'dashboard')[0].Port
            $context.DashboardPort = [int]$dashboardPort
            Assert-EwspKubernetesAccessPortAvailable $LocalRoot $context.DashboardPort | Out-Null
            Write-Host "      strict validation passed; rendered manifests: $($context.Rendered.Root)"
        } $completed $phaseNames[5..($total - 1)] $context.Environment 'Render exact images and run strict client validation' 'Kubernetes manifests' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 6 $total $phaseNames[5] 'Reconciling Kubernetes infrastructure' {
            Invoke-EwspKubernetesApplyStages $context.ApplyPlan 'Infrastructure'
            Remove-EwspKubernetesSecretArtifact $LocalRoot
            $context.SecretPath = $null
            Wait-EwspKubernetesInfrastructure $context.EnvironmentValues | Out-Null
        } $completed $phaseNames[6..($total - 1)] $context.Environment 'Apply namespace, ConfigMaps, Secret, PostgreSQL, Redis, and MinIO' 'Kubernetes infrastructure' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 7 $total $phaseNames[6] 'Reconciling Kubernetes applications' {
            $context.OldBackendImage = Get-EwspRunningKubernetesImage 'backend'
            $context.OldDashboardImage = Get-EwspRunningKubernetesImage 'dashboard'
            Invoke-EwspKubernetesApplyStages $context.ApplyPlan 'Application'
            foreach ($descriptor in $context.ImagePlan.Descriptors) {
                $old = if ($descriptor.Service -eq 'backend') { $context.OldBackendImage } else { $context.OldDashboardImage }
                if ($old -eq $descriptor.Tag) {
                    Write-Host "      $($descriptor.Service): reuse/reconcile $($descriptor.Tag)" -ForegroundColor Green
                } else {
                    Write-Host "      $($descriptor.Service): old image=$(if ($old) { $old } else { '<none>' })"
                    Write-Host "      $($descriptor.Service): new image=$($descriptor.Tag)" -ForegroundColor Green
                }
            }
        } $completed $phaseNames[7..($total - 1)] $context.Environment 'Apply exact backend and dashboard images' 'Kubernetes applications' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 8 $total $phaseNames[7] 'Waiting for Kubernetes readiness' {
            $context.States = @(Wait-EwspKubernetesWorkloads $context.EnvironmentValues)
        } $completed $phaseNames[8..($total - 1)] $context.Environment 'Wait for five workloads and two PVCs' 'EWSP workloads' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 9 $total $phaseNames[8] 'Verifying Kubernetes functionality' {
            Assert-EwspKubernetesFunctionality | Out-Null
        } $completed @($phaseNames[9]) $context.Environment 'Verify infrastructure, DNS, backend, and dashboard inside Kubernetes' 'EWSP Kubernetes services' -WorkflowName 'k8s-up' | Out-Null

        Invoke-EwspUpPhase 10 $total $phaseNames[9] 'Preparing dashboard access' {
            $context.PortForward = Start-EwspKubernetesPortForward $LocalRoot $context.DashboardPort
            Assert-EwspKubernetesDashboardAccess $context.DashboardPort | Out-Null
        } $completed @() $context.Environment 'Start or reuse managed dashboard port-forward' 'Dashboard access' -WorkflowName 'k8s-up' | Out-Null
    } finally {
        if ($context.SecretPath) {
            try { Remove-EwspKubernetesSecretArtifact $LocalRoot } catch {
                Write-Warning 'Temporary Kubernetes Secret cleanup failed. Remove .tmp\k8s\secrets.local.json manually without displaying it.'
            }
        }
        if ($context.PreviousTagEnvironment) { Restore-EwspProcessEnvironment $context.PreviousTagEnvironment }
    }

    Write-Host ''
    Write-Host 'EWSP Kubernetes is ready.' -ForegroundColor Green
    Write-Host "Dashboard: http://localhost:$($context.DashboardPort)"
    Write-Host 'Next: .\ewsp.ps1 k8s-status | .\ewsp.ps1 k8s-stop'
}

function Invoke-EwspStop {
    param([Parameter(Mandatory = $true)][string]$LocalRoot, $EnvironmentInfo)
    $EnvironmentInfo = Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $EnvironmentInfo
    Invoke-EwspComposeStreaming $EnvironmentInfo $LocalRoot @('down') 'Docker Compose shutdown failed'
    Write-Host 'EWSP stopped. PostgreSQL and MinIO named volumes were preserved.' -ForegroundColor Green
}

function Show-EwspHelp {
    Write-Host @'
EWSP local orchestration

Usage:
  .\ewsp.ps1 up      Safely prepare/update the workspace, build, start, verify, and summarize EWSP.
  .\ewsp.ps1 k8s-up  Reconcile EWSP on Docker Desktop Kubernetes and open dashboard access.
  .\ewsp.ps1 setup   Verify prerequisites, clone only missing repositories, and create .env if absent.
  .\ewsp.ps1 update  Fetch and safely fast-forward clean behind-only repositories.
  .\ewsp.ps1 start   Build only required application images and start the verified Docker stack.
  .\ewsp.ps1 stop    Stop containers without deleting PostgreSQL or MinIO data.
  .\ewsp.ps1 status  Show concise Git and Docker state.
  .\ewsp.ps1 k8s-status  Show Kubernetes workloads, storage, services, images, and dashboard access.
  .\ewsp.ps1 k8s-stop    Stop Kubernetes workloads and managed access while preserving PVC data.
  .\ewsp.ps1 help    Show this help.
'@
}

function Invoke-EwspCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$LocalRoot
    )
    switch ($Command.ToLowerInvariant()) {
        'up'     { Invoke-EwspUp $LocalRoot }
        'k8s-up' { Invoke-EwspKubernetesUp $LocalRoot }
        'setup'  { Invoke-EwspSetup $LocalRoot }
        'update' { Invoke-EwspUpdate $LocalRoot }
        'start'  { Invoke-EwspStart $LocalRoot }
        'stop'   { Invoke-EwspStop $LocalRoot }
        'status' { Invoke-EwspStatus $LocalRoot }
        'k8s-status' { Invoke-EwspKubernetesStatus $LocalRoot }
        'k8s-stop' { Invoke-EwspKubernetesStop $LocalRoot }
        'help'   { Show-EwspHelp }
        default  { throw "Unknown command '$Command'. Run .\ewsp.ps1 help for usage." }
    }
}

Export-ModuleMember -Function @(
    'Invoke-EwspCommand',
    'ConvertTo-EwspRemoteIdentity',
    'Test-EwspRepositoryIdentity',
    'Get-EwspRepositoryState',
    'Ensure-EwspRepository',
    'Update-EwspRepository',
    'Get-EwspRuntimeEnvironment',
    'Assert-EwspPrerequisites',
    'Protect-EwspDiagnosticText',
    'Assert-EwspEnvironmentConfiguration',
    'Get-EwspConfiguredPorts',
    'Assert-EwspPortAvailability',
    'Assert-EwspApplicationBuildAssets',
    'Get-EwspImageDescriptor',
    'Resolve-EwspImageAction',
    'Format-EwspServiceReadiness',
    'Wait-EwspServices',
    'Assert-EwspEndpoints',
    'New-EwspUpFailureException',
    'New-EwspKubernetesException',
    'Get-EwspKubernetesEnvironment',
    'Assert-EwspKubernetesEnvironment',
    'New-EwspKubernetesSecretArtifact',
    'Remove-EwspKubernetesSecretArtifact',
    'New-EwspKubernetesRenderedManifests',
    'Get-EwspKubernetesApplyPlan',
    'Assert-EwspKubernetesManifestSet',
    'Get-EwspKubernetesPodReason',
    'Get-EwspKubernetesWorkloadSnapshot',
    'Get-EwspKubernetesPvcSnapshot',
    'Get-EwspKubernetesServiceSnapshot',
    'Resolve-EwspKubernetesPortForwardAction',
    'Get-EwspManagedKubernetesPortForward',
    'Stop-EwspKubernetesPortForward',
    'Wait-EwspKubernetesPodsStopped',
    'Invoke-EwspKubernetesUp',
    'Invoke-EwspKubernetesStatus',
    'Invoke-EwspKubernetesStop'
)
