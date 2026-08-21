Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
    if ($exitCode -ne 0) { throw "$FailureMessage (exit code $exitCode)" }
}

function Invoke-EwspGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Invoke-EwspNative -FilePath 'git' -ArgumentList (@('-C', $RepositoryPath) + $Arguments)
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

function Get-EwspConfiguration {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    $configPath = Join-Path $LocalRoot 'config\repositories.psd1'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Repository configuration is missing: $configPath"
    }
    Import-PowerShellDataFile -LiteralPath $configPath
}

function Assert-EwspPrerequisites {
    param([switch]$RequireDocker)
    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        throw 'PowerShell 5.1 or newer is required.'
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not available. Install Git and retry.'
    }
    if ($RequireDocker) {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw 'Docker is not available. Install Docker Desktop and retry.'
        }
        $compose = Invoke-EwspNative 'docker' @('compose', 'version')
        if ($compose.ExitCode -ne 0) { throw 'Docker Compose is not available. Install or enable Docker Compose and retry.' }
        $engine = Invoke-EwspNative 'docker' @('info', '--format', '{{.ServerVersion}}')
        if ($engine.ExitCode -ne 0) { throw 'Docker Desktop is not available. Start Docker Desktop and retry.' }
    }
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
    param([Parameter(Mandatory = $true)][string]$Tag)
    $result = Invoke-EwspNative 'docker' @('image', 'inspect', $Tag)
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
        [Parameter(Mandatory = $true)][string]$Service
    )
    $idResult = Invoke-EwspNative 'docker' @('compose', 'ps', '-a', '-q', $Service) $LocalRoot
    if ($idResult.ExitCode -ne 0) {
        return [PSCustomObject]@{ Service = $Service; State = 'unavailable'; Health = 'unknown'; Id = $null }
    }
    $id = ($idResult.Output -join '').Trim()
    if (-not $id) { return [PSCustomObject]@{ Service = $Service; State = 'not created'; Health = 'n/a'; Id = $null } }
    $inspect = Invoke-EwspNative 'docker' @(
        'inspect', '--format', '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $id
    )
    if ($inspect.ExitCode -ne 0) {
        return [PSCustomObject]@{ Service = $Service; State = 'unknown'; Health = 'unknown'; Id = $id }
    }
    $parts = @(($inspect.Output -join '').Trim().Split('|'))
    [PSCustomObject]@{ Service = $Service; State = $parts[0]; Health = $parts[1]; Id = $id }
}

function Wait-EwspServices {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [int]$TimeoutSeconds = 180
    )
    $services = @('postgres', 'redis', 'minio', 'backend', 'dashboard')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $states = @($services | ForEach-Object { Get-EwspDockerServiceState $LocalRoot $_ })
        $failed = @($states | Where-Object { $_.State -in @('exited', 'dead') -or $_.Health -eq 'unhealthy' })
        if ($failed.Count -gt 0) {
            throw "A service failed readiness: $((@($failed | ForEach-Object { "$($_.Service)=$($_.State)/$($_.Health)" })) -join ', ')"
        }
        $ready = @($states | Where-Object { $_.State -eq 'running' -and $_.Health -eq 'healthy' })
        if ($ready.Count -eq $services.Count) { return $states }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out after $TimeoutSeconds seconds waiting for EWSP services to become healthy."
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

function Invoke-EwspSetup {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    Assert-EwspPrerequisites -RequireDocker
    $configuration = Get-EwspConfiguration $LocalRoot

    foreach ($repository in $configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        if (Test-Path -LiteralPath $path) {
            $identity = Test-EwspRepositoryIdentity $path $repository.ExpectedIdentity
            if (-not $identity.IdentityMatches) {
                throw "$path exists but does not match $($repository.ExpectedIdentity). $($identity.Error) No files were changed."
            }
        }
    }
    foreach ($repository in $configuration.Repositories) {
        $result = Ensure-EwspRepository $LocalRoot $repository
        Write-Host "$($result.Name): $($result.Action.ToLowerInvariant()) ($($result.Path))"
    }
    Ensure-EwspEnvironmentFile $LocalRoot
    Write-Host 'Setup complete. Existing repositories were not updated and Docker images were not rebuilt.' -ForegroundColor Green
}

function Invoke-EwspUpdate {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    Assert-EwspPrerequisites
    $configuration = Get-EwspConfiguration $LocalRoot
    foreach ($repository in $configuration.Repositories) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        $result = Update-EwspRepository $path $repository
        if ($result.Result -eq 'UPDATED') {
            Write-Host "$($repository.Name): updated by safe fast-forward." -ForegroundColor Green
        } elseif ($result.Result -eq 'UNCHANGED') {
            Write-Host "$($repository.Name): already up to date."
        } else {
            Write-Host "$($repository.Name): automatic update skipped ($($result.Reason))." -ForegroundColor Yellow
        }
    }
}

function Invoke-EwspStatus {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    Assert-EwspPrerequisites
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
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host 'Docker is not installed.' -ForegroundColor Yellow
        return
    }
    $engine = Invoke-EwspNative 'docker' @('info', '--format', '{{.ServerVersion}}')
    if ($engine.ExitCode -ne 0) {
        Write-Host 'Docker Desktop is not available.' -ForegroundColor Yellow
        return
    }
    foreach ($service in @('backend', 'dashboard', 'postgres', 'redis', 'minio')) {
        $state = Get-EwspDockerServiceState $LocalRoot $service
        Write-Host ("{0,-10} {1,-12} health={2}" -f $service, $state.State, $state.Health)
    }
}

function Invoke-EwspStart {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    Assert-EwspPrerequisites -RequireDocker
    if (-not (Test-Path -LiteralPath (Join-Path $LocalRoot '.env') -PathType Leaf)) {
        throw '.env is missing. Run .\ewsp.ps1 setup first.'
    }
    $configuration = Get-EwspConfiguration $LocalRoot
    $environmentValues = Read-EwspEnvironmentFile $LocalRoot
    $sessionId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $imageDescriptors = @()

    foreach ($repository in @($configuration.Repositories | Where-Object { $_.ContainsKey('Image') })) {
        $path = Resolve-EwspRepositoryPath $LocalRoot $repository
        $state = Get-EwspRepositoryState $path $repository.ExpectedIdentity $repository.PrimaryBranch
        if ($state.Classification -eq 'MISSING') { throw "$($repository.Name) is missing. Run .\ewsp.ps1 setup first." }
        if ($state.Classification -eq 'IDENTITY_MISMATCH') { throw "$path does not match the expected repository. No files were changed." }
        Assert-EwspApplicationBuildAssets $path $repository
        if ($state.Dirty) {
            Write-Host "$($repository.Name): dirty working tree; using a non-reusable session image." -ForegroundColor Yellow
        }
        $imageDescriptors += Get-EwspImageDescriptor $repository $state $environmentValues $sessionId
    }

    $tagEnvironment = @{}
    foreach ($descriptor in $imageDescriptors) { $tagEnvironment[$descriptor.EnvironmentName] = $descriptor.Tag }
    $previousEnvironment = Set-EwspProcessEnvironment $tagEnvironment
    try {
        foreach ($descriptor in $imageDescriptors) {
            $exists = Test-EwspDockerImageExists $descriptor.Tag
            $action = Resolve-EwspImageAction $descriptor $exists
            if ($action -eq 'REUSE') {
                Write-Host "$($descriptor.Service): reusing $($descriptor.Tag)" -ForegroundColor Green
                continue
            }
            Write-Host "$($descriptor.Service): building $($descriptor.Tag)"
            Invoke-EwspNativeStreaming 'docker' @('compose', 'build', $descriptor.Service) $LocalRoot `
                "Docker build failed for $($descriptor.Service)"
            if (-not (Test-EwspDockerImageExists $descriptor.Tag)) {
                throw "Build completed but image was not found: $($descriptor.Tag)"
            }
        }
        Write-Host 'Starting EWSP services ...'
        Invoke-EwspNativeStreaming 'docker' @('compose', 'up', '-d') $LocalRoot 'Docker Compose startup failed'
        $states = Wait-EwspServices $LocalRoot
        foreach ($state in $states) {
            Write-Host ("{0,-10} {1,-8} health={2}" -f $state.Service, $state.State, $state.Health)
        }
    } finally {
        Restore-EwspProcessEnvironment $previousEnvironment
    }

    $backendPort = if ($environmentValues.ContainsKey('BACKEND_HOST_PORT')) { $environmentValues.BACKEND_HOST_PORT } else { '8080' }
    $dashboardPort = if ($environmentValues.ContainsKey('DASHBOARD_HOST_PORT')) { $environmentValues.DASHBOARD_HOST_PORT } else { '3000' }
    $minioApiPort = if ($environmentValues.ContainsKey('MINIO_API_HOST_PORT')) { $environmentValues.MINIO_API_HOST_PORT } else { '9000' }
    $minioConsolePort = if ($environmentValues.ContainsKey('MINIO_CONSOLE_HOST_PORT')) { $environmentValues.MINIO_CONSOLE_HOST_PORT } else { '9001' }
    Write-Host ''
    Write-Host "Dashboard:     http://localhost:$dashboardPort"
    Write-Host "Backend:       http://localhost:$backendPort"
    Write-Host "Swagger:       http://localhost:$backendPort/swagger-ui/index.html"
    Write-Host "MinIO API:     http://localhost:$minioApiPort"
    Write-Host "MinIO Console: http://localhost:$minioConsolePort"
}

function Invoke-EwspStop {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)
    Assert-EwspPrerequisites -RequireDocker
    Invoke-EwspNativeStreaming 'docker' @('compose', 'down') $LocalRoot 'Docker Compose shutdown failed'
    Write-Host 'EWSP stopped. PostgreSQL and MinIO named volumes were preserved.' -ForegroundColor Green
}

function Show-EwspHelp {
    Write-Host @'
EWSP local orchestration

Usage:
  .\ewsp.ps1 setup   Verify prerequisites, clone only missing repositories, and create .env if absent.
  .\ewsp.ps1 update  Fetch and safely fast-forward clean behind-only repositories.
  .\ewsp.ps1 start   Build only required application images and start the verified Docker stack.
  .\ewsp.ps1 stop    Stop containers without deleting PostgreSQL or MinIO data.
  .\ewsp.ps1 status  Show concise Git and Docker state.
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
        'setup'  { Invoke-EwspSetup $LocalRoot }
        'update' { Invoke-EwspUpdate $LocalRoot }
        'start'  { Invoke-EwspStart $LocalRoot }
        'stop'   { Invoke-EwspStop $LocalRoot }
        'status' { Invoke-EwspStatus $LocalRoot }
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
    'Assert-EwspApplicationBuildAssets',
    'Get-EwspImageDescriptor',
    'Resolve-EwspImageAction'
)
