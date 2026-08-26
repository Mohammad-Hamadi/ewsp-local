[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$localRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $localRoot 'scripts\Ewsp.Local.psm1') -Force -DisableNameChecking
$script:PassCount = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
    $script:PassCount++
    Write-Host "PASS: $Message"
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if (-not $Actual.Contains($Expected)) { throw "$Message Expected '$Actual' to contain '$Expected'." }
    $script:PassCount++
    Write-Host "PASS: $Message"
}

function Assert-NotContains {
    param([string]$Actual, [string]$Unexpected, [string]$Message)
    if ($Actual.Contains($Unexpected)) { throw "$Message Expected '$Actual' not to contain '$Unexpected'." }
    $script:PassCount++
    Write-Host "PASS: $Message"
}

function Assert-ThrowsContains {
    param([scriptblock]$Action, [string]$Expected, [string]$Message)
    $actual = $null
    try { & $Action } catch { $actual = $_.Exception.Message }
    if (-not $actual) { throw "$Message Expected an exception containing '$Expected', but no exception was thrown." }
    Assert-Contains $actual $Expected $Message
}

function Assert-ThrowsCategory {
    param([scriptblock]$Action, [string]$Expected, [string]$Message)
    $actual = $null
    try { & $Action } catch { if ($_.Exception.Data.Contains('Category')) { $actual = [string]$_.Exception.Data['Category'] } }
    if (-not $actual) { throw "$Message Expected exception category '$Expected', but none was returned." }
    Assert-Equal $actual $Expected $Message
}

function New-FakeNativeResult {
    param([int]$ExitCode, [string[]]$Output = @())
    [PSCustomObject]@{ ExitCode = $ExitCode; Output = @($Output) }
}

function Get-FakeEnvironment {
    param([hashtable]$AvailableCommands, [hashtable]$Results)
    $resolver = {
        param($name)
        if ($AvailableCommands.ContainsKey($name) -and $AvailableCommands[$name]) {
            [PSCustomObject]@{ Name = $name; Source = $name }
        }
    }.GetNewClosure()
    $runner = {
        param($filePath, $arguments)
        $key = "$filePath|$((@($arguments)) -join ' ')"
        if ($Results.ContainsKey($key)) { return $Results[$key] }
        New-FakeNativeResult 1 @("unsupported fake command: $key")
    }.GetNewClosure()
    Get-EwspRuntimeEnvironment -CommandResolver $resolver -CommandRunner $runner
}

function Invoke-TestGit {
    param([string]$Path, [string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $Path @Arguments 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "Test Git command failed in $Path`: git $($Arguments -join ' ')" }
}

function Invoke-TestGitRaw {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @Arguments 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { throw "Test Git command failed: git $($Arguments -join ' ')" }
}

function New-TestRemote {
    param([string]$BasePath, [string]$Name)
    $remote = Join-Path $BasePath "$Name.git"
    $seed = Join-Path $BasePath "$Name-seed"
    Invoke-TestGitRaw @('init', '--bare', $remote)
    Invoke-TestGitRaw @('init', '-b', 'main', $seed)
    Set-Content -LiteralPath (Join-Path $seed 'README.md') -Value "# $Name"
    Invoke-TestGit $seed @('add', 'README.md')
    Invoke-TestGit $seed @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'initial')
    Invoke-TestGit $seed @('remote', 'add', 'origin', $remote)
    Invoke-TestGit $seed @('push', '-u', 'origin', 'main')
    [PSCustomObject]@{ Remote = $remote; Seed = $seed }
}

$testBase = Join-Path $localRoot '.tmp\orchestration-tests'
$testRoot = Join-Path $testBase ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    Assert-Equal (ConvertTo-EwspRemoteIdentity 'https://github.com/Owner/Repo.git/') 'github.com/owner/repo' 'HTTPS GitHub normalization'
    Assert-Equal (ConvertTo-EwspRemoteIdentity 'git@github.com:OWNER/REPO.git') 'github.com/owner/repo' 'SSH GitHub normalization'

    $primaryResults = @{
        'git|--version' = New-FakeNativeResult 0 @('git version 2.52.0.windows.1')
        'docker|--version' = New-FakeNativeResult 0 @('Docker version 29.5.3, build test')
        'docker|version --format {{.Server.Version}}' = New-FakeNativeResult 0 @('29.5.3')
        'docker|compose version --short' = New-FakeNativeResult 0 @('5.1.4')
    }
    $primaryEnvironment = Get-FakeEnvironment @{ git = $true; docker = $true; 'docker-compose' = $true } $primaryResults
    Assert-Equal $primaryEnvironment.Platform.PowerShellEdition $PSVersionTable.PSEdition 'environment detection records PowerShell edition'
    Assert-Equal $primaryEnvironment.Platform.PowerShellVersion $PSVersionTable.PSVersion.ToString() 'environment detection records PowerShell version'
    Assert-Equal $primaryEnvironment.Git.Version '2.52.0.windows.1' 'environment detection records Git version'
    Assert-Equal $primaryEnvironment.Docker.CliVersion '29.5.3' 'environment detection records Docker CLI version'
    Assert-Equal $primaryEnvironment.Docker.EngineReachable $true 'environment detection records reachable Docker Engine'
    Assert-Equal $primaryEnvironment.Docker.EngineVersion '29.5.3' 'environment detection records Docker Engine version'
    Assert-Equal $primaryEnvironment.Compose.DisplayName 'docker compose' 'docker compose capability is selected first'
    Assert-Equal $primaryEnvironment.Compose.Version '5.1.4' 'docker compose version is recorded'

    $missingGitEnvironment = Get-FakeEnvironment @{ git = $false; docker = $false; 'docker-compose' = $false } @{}
    Assert-Equal $missingGitEnvironment.Git.Available $false 'missing Git command is detected'
    Assert-ThrowsContains { Assert-EwspPrerequisites -EnvironmentInfo $missingGitEnvironment | Out-Null } `
        'Git is not installed' 'missing Git reports a prerequisite failure'

    $fallbackResults = @{
        'git|--version' = New-FakeNativeResult 0 @('git version 2.52.0')
        'docker|--version' = New-FakeNativeResult 0 @('Docker version 29.5.3, build test')
        'docker|version --format {{.Server.Version}}' = New-FakeNativeResult 0 @('29.5.3')
        'docker|compose version --short' = New-FakeNativeResult 1 @('compose is not a docker command')
        'docker-compose|version --short' = New-FakeNativeResult 0 @('1.29.2')
    }
    $fallbackEnvironment = Get-FakeEnvironment @{ git = $true; docker = $true; 'docker-compose' = $true } $fallbackResults
    Assert-Equal $fallbackEnvironment.Compose.DisplayName 'docker-compose' 'legacy docker-compose is selected when plugin capability fails'
    Assert-Equal $fallbackEnvironment.Compose.Version '1.29.2' 'legacy Compose version is recorded'

    $missingDockerEnvironment = Get-FakeEnvironment @{ git = $true; docker = $false; 'docker-compose' = $false } @{
        'git|--version' = New-FakeNativeResult 0 @('git version 2.52.0')
    }
    Assert-Equal $missingDockerEnvironment.Docker.Available $false 'missing Docker CLI is detected'
    Assert-ThrowsContains { Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $missingDockerEnvironment | Out-Null } `
        'Docker CLI is not installed' 'missing Docker CLI reports a prerequisite failure'

    $engineDownResults = @{
        'git|--version' = New-FakeNativeResult 0 @('git version 2.52.0')
        'docker|--version' = New-FakeNativeResult 0 @('Docker version 29.5.3, build test')
        'docker|version --format {{.Server.Version}}' = New-FakeNativeResult 1 @('cannot connect')
        'docker|compose version --short' = New-FakeNativeResult 0 @('5.1.4')
    }
    $engineDownEnvironment = Get-FakeEnvironment @{ git = $true; docker = $true; 'docker-compose' = $false } $engineDownResults
    Assert-Equal $engineDownEnvironment.Docker.EngineReachable $false 'unreachable Docker Engine is detected separately from CLI availability'
    Assert-ThrowsContains { Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $engineDownEnvironment | Out-Null } `
        'Docker Engine not running' 'unreachable Docker Engine has precise remediation'

    $noComposeResults = @{
        'git|--version' = New-FakeNativeResult 0 @('git version 2.52.0')
        'docker|--version' = New-FakeNativeResult 0 @('Docker version 29.5.3, build test')
        'docker|version --format {{.Server.Version}}' = New-FakeNativeResult 0 @('29.5.3')
        'docker|compose version --short' = New-FakeNativeResult 1 @('unsupported')
        'docker-compose|version --short' = New-FakeNativeResult 1 @('unsupported')
    }
    $noComposeEnvironment = Get-FakeEnvironment @{ git = $true; docker = $true; 'docker-compose' = $true } $noComposeResults
    Assert-Equal $noComposeEnvironment.Compose.Available $false 'absence of both Compose capabilities is detected'
    Assert-ThrowsContains { Assert-EwspPrerequisites -RequireDocker -EnvironmentInfo $noComposeEnvironment | Out-Null } `
        'neither docker compose nor docker-compose' 'missing Compose implementations report unsupported Compose'

    $setupRemote = New-TestRemote $testRoot 'setup-remote'
    $setupWorkspace = Join-Path $testRoot 'setup-workspace'
    $setupLocal = Join-Path $setupWorkspace 'ewsp-local'
    New-Item -ItemType Directory -Path $setupLocal -Force | Out-Null
    $setupRepository = @{
        Name = 'setup-app'; Directory = 'setup-app'
        ExpectedIdentity = ConvertTo-EwspRemoteIdentity $setupRemote.Remote
        CloneUrl = $setupRemote.Remote; PrimaryBranch = 'main'
    }
    $firstSetup = Ensure-EwspRepository $setupLocal $setupRepository
    $secondSetup = Ensure-EwspRepository $setupLocal $setupRepository
    Assert-Equal $firstSetup.Action 'Cloned' 'missing repository clones once'
    Assert-Equal $secondSetup.Action 'Reused' 'second setup reuses existing clone'

    $wrongRemote = New-TestRemote $testRoot 'wrong-remote'
    $wrongPath = Join-Path $setupWorkspace 'wrong-app'
    Invoke-TestGitRaw @('clone', '--branch', 'main', $wrongRemote.Remote, $wrongPath)
    $wrongRepository = @{
        Name = 'wrong-app'; Directory = 'wrong-app'
        ExpectedIdentity = ConvertTo-EwspRemoteIdentity $setupRemote.Remote
        CloneUrl = $setupRemote.Remote; PrimaryBranch = 'main'
    }
    $wrongProtected = $false
    try { Ensure-EwspRepository $setupLocal $wrongRepository | Out-Null } catch { $wrongProtected = $true }
    Assert-Equal $wrongProtected $true 'wrong repository is refused without overwrite'

    $nonGitPath = Join-Path $setupWorkspace 'non-git-app'
    New-Item -ItemType Directory -Path $nonGitPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nonGitPath 'sentinel.txt') -Value 'preserve me'
    $nonGitRepository = @{
        Name = 'non-git-app'; Directory = 'non-git-app'
        ExpectedIdentity = ConvertTo-EwspRemoteIdentity $setupRemote.Remote
        CloneUrl = $setupRemote.Remote; PrimaryBranch = 'main'
    }
    $nonGitProtected = $false
    try { Ensure-EwspRepository $setupLocal $nonGitRepository | Out-Null } catch { $nonGitProtected = $true }
    Assert-Equal $nonGitProtected $true 'non-Git directory is refused without overwrite'
    Assert-Equal (Get-Content -Raw (Join-Path $nonGitPath 'sentinel.txt')).Trim() 'preserve me' 'non-Git directory contents are preserved'

    $envLocal = Join-Path $testRoot 'environment-local'
    New-Item -ItemType Directory -Path $envLocal -Force | Out-Null
    Invoke-TestGitRaw @('init', '-b', 'main', $envLocal)
    Set-Content -LiteralPath (Join-Path $envLocal '.gitignore') -Value ".env`n"
    Set-Content -LiteralPath (Join-Path $envLocal '.env.example') -Value "TEST_VALUE=example`n"
    $module = Get-Module 'Ewsp.Local'
    & $module { param($root) Ensure-EwspEnvironmentFile $root } $envLocal
    Set-Content -LiteralPath (Join-Path $envLocal '.env') -Value "TEST_VALUE=preserved`n"
    & $module { param($root) Ensure-EwspEnvironmentFile $root } $envLocal
    Assert-Contains (Get-Content -Raw (Join-Path $envLocal '.env')) 'TEST_VALUE=preserved' 'existing .env is preserved'
    $preserveOutput = (& $module { param($root) Ensure-EwspEnvironmentFile $root } $envLocal 6>&1 | Out-String)
    Assert-NotContains $preserveOutput 'TEST_VALUE=preserved' 'environment setup does not print preserved values'
    Assert-Equal (Protect-EwspDiagnosticText 'JWT_SECRET=do-not-print POSTGRES_PASSWORD=also-private') `
        'JWT_SECRET=<redacted> POSTGRES_PASSWORD=<redacted>' 'diagnostic redaction hides secret values'
    Assert-NotContains (Protect-EwspDiagnosticText 'connection failed for opaque-secret-value' `
        @{ JWT_SECRET = 'opaque-secret-value' }) 'opaque-secret-value' 'diagnostic redaction removes configured secret values from logs'

    $validEnvironment = @{
        POSTGRES_DB = 'ewsp'; POSTGRES_USER = 'ewsp'; POSTGRES_PASSWORD = 'private-value'
        MINIO_ROOT_USER = 'minio'; MINIO_ROOT_PASSWORD = 'private-value'; MINIO_BUCKET_NAME = 'evidence'
        JWT_SECRET = 'private-value'
        EWSP_CORS_ALLOWED_ORIGINS = 'http://localhost:3000'
    }
    $configuredPorts = @(Assert-EwspEnvironmentConfiguration $validEnvironment)
    Assert-Equal $configuredPorts.Count 6 'environment validation resolves all six host ports'
    Assert-Equal (@($configuredPorts | Where-Object Name -eq 'Backend')[0].Port) 8080 'environment validation applies backend port default'
    Assert-ThrowsContains { Assert-EwspEnvironmentConfiguration @{} | Out-Null } `
        'required setting names' 'missing environment settings identify names without values'

    Assert-Equal (Assert-EwspPortAvailability $configuredPorts @() @()) $true 'free configured ports pass preflight'
    Assert-ThrowsContains { Assert-EwspPortAvailability $configuredPorts @(8080) @() | Out-Null } `
        'Backend requires host port 8080' 'external occupied port is identified before startup'
    Assert-Equal (Assert-EwspPortAvailability $configuredPorts @(8080) @(8080)) $true `
        'port held by the current EWSP project is accepted'

    $stateRemote = New-TestRemote $testRoot 'state-remote'
    $stateWorkspace = Join-Path $testRoot 'state-workspace'
    $stateLocal = Join-Path $stateWorkspace 'ewsp-local'
    $stateWork = Join-Path $stateWorkspace 'state-app'
    $statePeer = Join-Path $stateWorkspace 'state-peer'
    New-Item -ItemType Directory -Path $stateLocal -Force | Out-Null
    Invoke-TestGitRaw @('clone', '--branch', 'main', $stateRemote.Remote, $stateWork)
    Invoke-TestGitRaw @('clone', '--branch', 'main', $stateRemote.Remote, $statePeer)
    $stateRepository = @{
        Name = 'state-app'; Directory = 'state-app'
        ExpectedIdentity = ConvertTo-EwspRemoteIdentity $stateRemote.Remote
        CloneUrl = $stateRemote.Remote; PrimaryBranch = 'main'
    }

    $upToDate = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $upToDate.Classification 'UP_TO_DATE' 'up-to-date classification'

    Add-Content -LiteralPath (Join-Path $statePeer 'README.md') -Value 'peer behind test'
    Invoke-TestGit $statePeer @('add', 'README.md')
    Invoke-TestGit $statePeer @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'remote advance')
    Invoke-TestGit $statePeer @('push', 'origin', 'main')
    $behind = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $behind.Classification 'BEHIND' 'behind classification'
    $fastForward = Update-EwspRepository $stateWork $stateRepository
    Assert-Equal $fastForward.Result 'UPDATED' 'behind-only clean repository fast-forwards'

    Invoke-TestGit $stateWork @('switch', '-c', 'review-wrong-branch')
    $wrongBranch = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $wrongBranch.Classification 'WRONG_BRANCH' 'wrong-branch classification'
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'SKIPPED' 'wrong branch is not updated'
    Invoke-TestGit $stateWork @('switch', 'main')

    Invoke-TestGit $stateWork @('switch', '--detach')
    $detached = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $detached.Classification 'DETACHED' 'detached-HEAD classification'
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'SKIPPED' 'detached HEAD is not updated'
    Invoke-TestGit $stateWork @('switch', 'main')

    Invoke-TestGit $stateWork @('switch', '-c', 'review-no-upstream')
    $noUpstream = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $noUpstream.Classification 'NO_UPSTREAM' 'missing-upstream classification'
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'SKIPPED' 'missing upstream is not updated'
    Invoke-TestGit $stateWork @('switch', 'main')

    Add-Content -LiteralPath (Join-Path $statePeer 'README.md') -Value 'fetch failure safety test'
    Invoke-TestGit $statePeer @('add', 'README.md')
    Invoke-TestGit $statePeer @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'remote advance before failed fetch')
    Invoke-TestGit $statePeer @('push', 'origin', 'main')
    Invoke-TestGit $stateWork @('fetch', 'origin')
    Invoke-TestGit $stateWork @('remote', 'add', 'broken', (Join-Path $testRoot 'missing-remote.git'))
    $fetchFailed = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $fetchFailed.Classification 'BEHIND' 'stale behind state remains visible after fetch failure'
    Assert-Contains $fetchFailed.Classification 'FETCH_FAILED' 'fetch-failure classification'
    $headBeforeFetchFailure = (& git -C $stateWork rev-parse HEAD).Trim()
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'SKIPPED' 'fetch failure prevents automatic update'
    Assert-Equal ((& git -C $stateWork rev-parse HEAD).Trim()) $headBeforeFetchFailure 'fetch-failed update preserves HEAD'
    Invoke-TestGit $stateWork @('remote', 'remove', 'broken')
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'UPDATED' 'safe update resumes after fetch succeeds'

    $alternateRemote = Join-Path $testRoot 'alternate-upstream.git'
    $alternatePeer = Join-Path $testRoot 'alternate-peer'
    Invoke-TestGitRaw @('clone', '--bare', $stateRemote.Remote, $alternateRemote)
    Invoke-TestGitRaw @('clone', '--branch', 'main', $alternateRemote, $alternatePeer)
    Add-Content -LiteralPath (Join-Path $alternatePeer 'README.md') -Value 'unexpected upstream advance'
    Invoke-TestGit $alternatePeer @('add', 'README.md')
    Invoke-TestGit $alternatePeer @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'unexpected upstream advance')
    Invoke-TestGit $alternatePeer @('push', 'origin', 'main')
    Invoke-TestGit $stateWork @('remote', 'add', 'alternate', $alternateRemote)
    Invoke-TestGit $stateWork @('fetch', 'alternate')
    Invoke-TestGit $stateWork @('config', 'branch.main.remote', 'alternate')
    Invoke-TestGit $stateWork @('config', 'branch.main.merge', 'refs/heads/main')
    $unexpectedUpstream = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $unexpectedUpstream.Classification 'BEHIND' 'unexpected upstream can appear behind-only'
    Assert-Contains $unexpectedUpstream.Classification 'UPSTREAM_IDENTITY_MISMATCH' 'unexpected-upstream identity classification'
    $headBeforeUnexpectedUpstream = (& git -C $stateWork rev-parse HEAD).Trim()
    Assert-Equal (Update-EwspRepository $stateWork $stateRepository).Result 'SKIPPED' 'unexpected upstream is not updated'
    Assert-Equal ((& git -C $stateWork rev-parse HEAD).Trim()) $headBeforeUnexpectedUpstream 'unexpected-upstream update preserves HEAD'
    Invoke-TestGit $stateWork @('config', 'branch.main.remote', 'origin')
    Invoke-TestGit $stateWork @('config', 'branch.main.merge', 'refs/heads/main')

    Add-Content -LiteralPath (Join-Path $stateWork 'README.md') -Value 'local ahead test'
    Invoke-TestGit $stateWork @('add', 'README.md')
    Invoke-TestGit $stateWork @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'local advance')
    $ahead = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $ahead.Classification 'AHEAD' 'ahead classification'

    Add-Content -LiteralPath (Join-Path $statePeer 'README.md') -Value 'remote divergence test'
    Invoke-TestGit $statePeer @('add', 'README.md')
    Invoke-TestGit $statePeer @('-c', 'user.name=EWSP Test', '-c', 'user.email=ewsp-test@example.invalid', 'commit', '-m', 'remote diverge')
    Invoke-TestGit $statePeer @('push', 'origin', 'main')
    $diverged = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $diverged.Classification 'DIVERGED' 'diverged classification'

    Set-Content -LiteralPath (Join-Path $stateWork 'untracked.txt') -Value 'developer work'
    $dirty = Get-EwspRepositoryState $stateWork $stateRepository.ExpectedIdentity 'main' -Fetch
    Assert-Contains $dirty.Classification 'DIRTY' 'dirty classification'
    $headBeforeSkip = (& git -C $stateWork rev-parse HEAD).Trim()
    $skipped = Update-EwspRepository $stateWork $stateRepository
    $headAfterSkip = (& git -C $stateWork rev-parse HEAD).Trim()
    Assert-Equal $skipped.Result 'SKIPPED' 'dirty diverged repository is not updated'
    Assert-Equal $headAfterSkip $headBeforeSkip 'skipped update preserves HEAD'

    $imageRepository = @{
        Name = 'image-app'
        Image = @{
            Service = 'image-app'; RepositoryName = 'ewsp-image-test'; EnvironmentName = 'EWSP_TEST_IMAGE'
            RequiredBuildFiles = @('Dockerfile', '.dockerignore'); BuildInputs = @('BUILD_VARIANT')
        }
    }
    $cleanImageState = [PSCustomObject]@{
        Dirty = $false; Commit = '0123456789abcdef0123456789abcdef01234567'; ShortCommit = '0123456'
    }
    $dirtyImageState = [PSCustomObject]@{
        Dirty = $true; Commit = '0123456789abcdef0123456789abcdef01234567'; ShortCommit = '0123456'
    }
    $imageEnvironment = @{ BUILD_VARIANT = 'default' }
    $cleanImageA = Get-EwspImageDescriptor $imageRepository $cleanImageState $imageEnvironment 'session-a'
    $cleanImageARepeat = Get-EwspImageDescriptor $imageRepository $cleanImageState $imageEnvironment 'session-b'
    Assert-Equal $cleanImageA.Tag $cleanImageARepeat.Tag 'clean image identity is stable across sessions'
    Assert-Equal (Resolve-EwspImageAction $cleanImageA $true) 'REUSE' 'existing clean image is reused'
    Assert-Equal (Resolve-EwspImageAction $cleanImageA $false) 'BUILD' 'missing clean image is built'

    $changedCommitState = [PSCustomObject]@{
        Dirty = $false; Commit = 'fedcba9876543210fedcba9876543210fedcba98'; ShortCommit = 'fedcba9'
    }
    $cleanImageCommitChanged = Get-EwspImageDescriptor $imageRepository $changedCommitState $imageEnvironment 'session-c'
    if ($cleanImageCommitChanged.Tag -eq $cleanImageA.Tag) { throw 'Application commit change did not change clean image identity.' }
    Write-Host 'PASS: application commit changes clean image identity'

    $changedEnvironment = @{ BUILD_VARIANT = 'alternate' }
    $cleanImageInputChanged = Get-EwspImageDescriptor $imageRepository $cleanImageState $changedEnvironment 'session-d'
    if ($cleanImageInputChanged.Tag -eq $cleanImageA.Tag) { throw 'Build input change did not change image identity.' }
    Write-Host 'PASS: declared build input changes image identity'

    $dirtyImage = Get-EwspImageDescriptor $imageRepository $dirtyImageState $imageEnvironment 'session-dirty'
    Assert-Equal $dirtyImage.Reusable $false 'dirty image is non-reusable'
    Assert-Equal (Resolve-EwspImageAction $dirtyImage $true) 'BUILD' 'dirty image builds even if a same-tag image exists'
    Assert-Contains $dirtyImage.Tag 'dirty-0123456-session-dirty' 'dirty image tag identifies dirty session'

    $productionConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $localRoot 'config\repositories.psd1')
    $backendImageConfig = @($productionConfig.Repositories | Where-Object Name -eq 'ewsp-backend')[0].Image
    $dashboardRepositoryConfig = @($productionConfig.Repositories | Where-Object Name -eq 'ewsp-dashboard')[0]
    $dashboardImageConfig = $dashboardRepositoryConfig.Image
    Assert-Contains ($backendImageConfig.RequiredBuildFiles -join '|') 'Dockerfile' 'backend requires its repository Dockerfile'
    Assert-Contains ($backendImageConfig.RequiredBuildFiles -join '|') '.dockerignore' 'backend requires its repository Docker ignore file'
    Assert-Contains ($dashboardImageConfig.RequiredBuildFiles -join '|') 'Dockerfile' 'dashboard requires its repository Dockerfile'
    Assert-Contains ($dashboardImageConfig.RequiredBuildFiles -join '|') '.dockerignore' 'dashboard requires its repository Docker ignore file'
    Assert-Contains ($dashboardImageConfig.RequiredBuildFiles -join '|') 'nginx.conf' 'dashboard requires its repository Nginx configuration'
    Assert-Equal @($dashboardImageConfig.BuildInputs).Count 0 'dashboard identity has no orchestration build inputs'
    $dashboardIdentityA = Get-EwspImageDescriptor $dashboardRepositoryConfig $cleanImageState `
        @{ VITE_API_BASE_URL = 'http://localhost:8080'; VITE_WS_URL = 'ws://localhost:8080/ws' } 'dashboard-a'
    $dashboardIdentityB = Get-EwspImageDescriptor $dashboardRepositoryConfig $cleanImageState `
        @{ VITE_API_BASE_URL = 'http://localhost:18080'; VITE_WS_URL = 'ws://localhost:18080/ws' } 'dashboard-b'
    Assert-Equal $dashboardIdentityA.Tag $dashboardIdentityB.Tag 'dashboard API and WebSocket URLs do not affect image identity'

    $missingAssetPath = Join-Path $testRoot 'missing-build-assets'
    New-Item -ItemType Directory -Path $missingAssetPath -Force | Out-Null
    $missingAssetMessage = $null
    try { Assert-EwspApplicationBuildAssets $missingAssetPath $imageRepository } catch { $missingAssetMessage = $_.Exception.Message }
    Assert-Contains $missingAssetMessage "missing required application-owned Docker asset 'Dockerfile'" 'missing Dockerfile identifies the required application-owned asset'
    Assert-Contains $missingAssetMessage '.\ewsp.ps1 update' 'missing Dockerfile suggests the safe update command'
    Assert-Contains $missingAssetMessage 'will not fall back' 'missing Dockerfile refuses an orchestration-owned fallback'

    $composeConfiguration = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'compose.yml')
    Assert-Contains $composeConfiguration 'context: ../ewsp-backend' 'backend uses its sibling repository build context'
    Assert-Contains $composeConfiguration 'context: ../ewsp-dashboard' 'dashboard uses its sibling repository build context'
    Assert-Contains $composeConfiguration '${EWSP_COMPOSE_BACKEND_IMAGE:-ewsp-backend:local}' 'Compose backend tag is isolated from Kubernetes GHCR configuration'
    Assert-Contains $composeConfiguration '${EWSP_COMPOSE_DASHBOARD_IMAGE:-ewsp-dashboard:local}' 'Compose dashboard tag is isolated from Kubernetes GHCR configuration'
    Assert-NotContains $composeConfiguration '${EWSP_BACKEND_IMAGE' 'Compose does not consume Kubernetes backend image configuration'
    Assert-NotContains $composeConfiguration '${EWSP_DASHBOARD_IMAGE' 'Compose does not consume Kubernetes dashboard image configuration'
    Assert-Equal ([regex]::Matches($composeConfiguration, '(?m)^\s+dockerfile: Dockerfile\s*$').Count) 2 'both applications use their repository Dockerfile'
    Assert-NotContains $composeConfiguration 'additional_contexts:' 'dashboard has no orchestration additional build context'
    Assert-NotContains $composeConfiguration 'VITE_API_BASE_URL' 'Compose does not pass the obsolete dashboard API build argument'
    Assert-NotContains $composeConfiguration 'VITE_WS_URL' 'Compose does not pass the obsolete dashboard WebSocket build argument'
    Assert-Equal ([regex]::Matches($composeConfiguration, '(?m)^  backend:\s*$').Count) 1 'backend service name remains exact'
    Assert-Contains $composeConfiguration '"${BACKEND_HOST_PORT:-8080}:8080"' 'backend keeps direct host port publication'
    Assert-NotContains $composeConfiguration 'network_mode:' 'dashboard and backend remain on the shared Compose default network'
    Assert-Contains $composeConfiguration 'command: ["redis-server", "--save", "", "--appendonly", "no"]' 'Redis persistence is explicitly disabled'
    Assert-Contains $composeConfiguration 'type: tmpfs' 'Redis image data path is replaced with tmpfs'
    Assert-Contains $composeConfiguration 'EWSP_MOBILE_LATEST_VERSION: ${EWSP_MOBILE_LATEST_VERSION:-1.0.1}' 'Compose backend receives the current mobile version with a development-safe default'
    Assert-Contains $composeConfiguration 'EWSP_MOBILE_LATEST_VERSION_CODE: ${EWSP_MOBILE_LATEST_VERSION_CODE:-2}' 'Compose backend receives mobile version code 2'
    Assert-Contains $composeConfiguration 'EWSP_MOBILE_UPDATE_URL: ${EWSP_MOBILE_UPDATE_URL:-https://github.com/Mohammad-Hamadi/ewsp-mobile/releases/download/v1.0.1/ewsp-1.0.1.apk}' 'Compose backend receives the exact HTTPS mobile update URL'
    $environmentExample = Get-Content -Raw -LiteralPath (Join-Path $localRoot '.env.example')
    Assert-NotContains $environmentExample 'VITE_API_BASE_URL' 'environment example removes obsolete dashboard API build configuration'
    Assert-NotContains $environmentExample 'VITE_WS_URL' 'environment example removes obsolete dashboard WebSocket build configuration'
    $dashboardDockerfile = Get-Content -Raw -LiteralPath (Join-Path $localRoot '..\ewsp-dashboard\Dockerfile')
    $dashboardNginx = Get-Content -Raw -LiteralPath (Join-Path $localRoot '..\ewsp-dashboard\nginx.conf')
    Assert-NotContains $dashboardDockerfile 'VITE_API_BASE_URL' 'dashboard Dockerfile accepts no API build argument'
    Assert-NotContains $dashboardDockerfile 'VITE_WS_URL' 'dashboard Dockerfile accepts no WebSocket build argument'
    Assert-Contains $dashboardNginx 'proxy_pass http://backend:8080;' 'dashboard proxies same-origin API requests to backend service'
    Assert-Contains $dashboardNginx 'proxy_pass http://backend:8080/ws;' 'dashboard proxies same-origin WebSocket requests to backend service'

    $healthyStates = @(
        [PSCustomObject]@{ Service = 'postgres'; State = 'running'; Health = 'healthy'; Id = '1' },
        [PSCustomObject]@{ Service = 'redis'; State = 'running'; Health = 'healthy'; Id = '2' },
        [PSCustomObject]@{ Service = 'minio'; State = 'running'; Health = 'healthy'; Id = '3' },
        [PSCustomObject]@{ Service = 'backend'; State = 'running'; Health = 'healthy'; Id = '4' },
        [PSCustomObject]@{ Service = 'dashboard'; State = 'running'; Health = 'healthy'; Id = '5' }
    )
    $healthyProvider = {
        param($service)
        @($healthyStates | Where-Object Service -eq $service)[0]
    }.GetNewClosure()
    $noSleep = { }
    $readyStates = @(Wait-EwspServices 'unused' ([PSCustomObject]@{}) -TimeoutSeconds 1 `
        -StateProvider $healthyProvider -SleepAction $noSleep)
    Assert-Equal $readyStates.Count 5 'successful readiness waits for all five services'

    $failedStates = @(
        [PSCustomObject]@{ Service = 'postgres'; State = 'running'; Health = 'healthy'; Id = '1' },
        [PSCustomObject]@{ Service = 'redis'; State = 'running'; Health = 'healthy'; Id = '2' },
        [PSCustomObject]@{ Service = 'minio'; State = 'running'; Health = 'healthy'; Id = '3' },
        [PSCustomObject]@{ Service = 'backend'; State = 'running'; Health = 'unhealthy'; Id = '4' },
        [PSCustomObject]@{ Service = 'dashboard'; State = 'created'; Health = 'n/a'; Id = '5' }
    )
    $failedProvider = {
        param($service)
        @($failedStates | Where-Object Service -eq $service)[0]
    }.GetNewClosure()
    $failedReadinessMessage = $null
    try {
        Wait-EwspServices 'unused' ([PSCustomObject]@{}) -TimeoutSeconds 1 `
            -StateProvider $failedProvider -SleepAction $noSleep | Out-Null
    } catch { $failedReadinessMessage = $_.Exception.Message }
    Assert-Contains $failedReadinessMessage 'Backend        unhealthy' 'service failure identifies the unhealthy backend'
    Assert-Contains $failedReadinessMessage 'Dashboard      waiting on backend' 'service failure explains dashboard dependency wait'

    $waitingStates = @($failedStates | ForEach-Object {
        if ($_.Service -eq 'backend') {
            [PSCustomObject]@{ Service = 'backend'; State = 'starting'; Health = 'starting'; Id = '4' }
        } else { $_ }
    })
    $waitingProvider = {
        param($service)
        @($waitingStates | Where-Object Service -eq $service)[0]
    }.GetNewClosure()
    Assert-ThrowsContains {
        Wait-EwspServices 'unused' ([PSCustomObject]@{}) -TimeoutSeconds 0 `
            -StateProvider $waitingProvider -SleepAction $noSleep | Out-Null
    } 'Timed out' 'health timeout is classified and reported'

    $urls = [PSCustomObject]@{
        Dashboard = 'http://localhost:3000'
        DashboardComplaints = 'http://localhost:3000/complaints'
        DashboardMissingAsset = 'http://localhost:3000/assets/ewsp-missing-verification.js'
        DashboardBackendHealth = 'http://localhost:3000/api/health'
        BackendHealth = 'http://localhost:8080/api/health'
        Swagger = 'http://localhost:8080/swagger-ui/index.html'; OpenApi = 'http://localhost:8080/v3/api-docs'
        MinioLive = 'http://localhost:9000/minio/health/live'
    }
    $successfulProbe = {
        param($uri)
        $status = if ($uri -like '*ewsp-missing-verification.js') { 404 } else { 200 }
        [PSCustomObject]@{ StatusCode = $status; Error = $null }
    }
    Assert-EwspEndpoints $urls -Probe $successfulProbe
    $script:PassCount++
    Write-Host 'PASS: endpoint verification accepts all required HTTP statuses'
    $failedProbe = {
        param($uri)
        if ($uri -like '*ewsp-missing-verification.js') { [PSCustomObject]@{ StatusCode = 404; Error = $null } }
        elseif ($uri -like '*swagger*') { [PSCustomObject]@{ StatusCode = 503; Error = 'unavailable' } }
        else { [PSCustomObject]@{ StatusCode = 200; Error = $null } }
    }
    Assert-ThrowsContains { Assert-EwspEndpoints $urls -Probe $failedProbe } `
        'Swagger UI' 'endpoint verification names the failed endpoint'

    $buildCause = New-Object System.Exception('command failed with JWT_SECRET=do-not-leak')
    $buildCause.Data['Category'] = 'IMAGE_BUILD_FAILURE'
    $buildCause.Data['Component'] = 'backend'
    $buildCause.Data['ExitCode'] = 17
    $buildCause.Data['Operation'] = 'docker compose build backend JWT_SECRET=do-not-leak'
    $completedPhases = New-Object System.Collections.Generic.List[string]
    $completedPhases.Add('ENVIRONMENT_DETECTION')
    $phaseFailure = New-EwspUpFailureException 'IMAGE_BUILD' 'Preparing application images' $buildCause `
        $primaryEnvironment $completedPhases @('SERVICE_START', 'HEALTH_WAIT') 'build backend' 'backend'
    Assert-Contains $phaseFailure.Message 'Phase: IMAGE_BUILD' 'image build failure reports its phase'
    Assert-Contains $phaseFailure.Message 'Category: IMAGE_BUILD_FAILURE' 'image build failure reports its category'
    Assert-Contains $phaseFailure.Message 'Component: backend' 'phase failure reports its component'
    Assert-Contains $phaseFailure.Message 'Operation: docker compose build backend JWT_SECRET=<redacted>' `
        'phase failure reports the sanitized attempted command'
    Assert-Contains $phaseFailure.Message 'Exit code: 17' 'phase failure preserves native exit code'
    Assert-Contains $phaseFailure.Message 'Detected environment:' 'phase failure includes detected environment'
    Assert-Contains $phaseFailure.Message 'Not attempted afterward: SERVICE_START, HEALTH_WAIT' 'phase failure lists skipped later work'
    Assert-NotContains $phaseFailure.Message 'do-not-leak' 'phase diagnostics redact secret values'
    $finalPhaseResult = & $module {
        param($environment)
        $completed = New-Object System.Collections.Generic.List[string]
        Invoke-EwspUpPhase 9 9 'FINAL_VERIFICATION' 'Verifying local endpoints' { 'final-phase-ok' } `
            $completed @() $environment 'Verify endpoints' 'EWSP endpoints'
    } $primaryEnvironment
    Assert-Contains ($finalPhaseResult -join '|') 'final-phase-ok' 'final up phase accepts an empty remaining-phase list on PowerShell 5.1'

    $kubeRuntime = [PSCustomObject]@{
        Platform = [PSCustomObject]@{ Description = 'Windows'; Architecture = 'X64'; PowerShellEdition = 'Desktop'; PowerShellVersion = '5.1' }
        Git = [PSCustomObject]@{ Available = $true; Version = '2.52.0' }
        Docker = [PSCustomObject]@{ Available = $true; CliVersion = '29.5.3'; EngineReachable = $true; EngineVersion = '29.5.3' }
        Compose = [PSCustomObject]@{ Available = $true; DisplayName = 'docker compose'; Version = '5.1.4' }
    }
    $clientJson = @{ clientVersion = @{ gitVersion = 'v1.36.1' } } | ConvertTo-Json -Depth 5 -Compress
    $serverJson = @{ clientVersion = @{ gitVersion = 'v1.36.1' }; serverVersion = @{ gitVersion = 'v1.36.1' } } | ConvertTo-Json -Depth 5 -Compress
    $readyNodeJson = @{ items = @(@{
        metadata = @{ name = 'desktop-control-plane' }
        status = @{ conditions = @(@{ type = 'Ready'; status = 'True' }); nodeInfo = @{ kubeletVersion = 'v1.36.1'; containerRuntimeVersion = 'containerd://1.7.27' } }
    }) } | ConvertTo-Json -Depth 8 -Compress
    $storageJson = @{
        metadata = @{ name = 'standard'; annotations = @{ 'storageclass.kubernetes.io/is-default-class' = 'true' } }
        provisioner = 'rancher.io/local-path'; reclaimPolicy = 'Delete'; volumeBindingMode = 'WaitForFirstConsumer'
    } | ConvertTo-Json -Depth 8 -Compress
    $healthyKubeResults = @{
        'kubectl|version --client -o json' = New-FakeNativeResult 0 @($clientJson)
        'kubectl|config current-context' = New-FakeNativeResult 0 @('docker-desktop')
        'kubectl|version -o json' = New-FakeNativeResult 0 @($serverJson)
        'kubectl|get nodes -o json' = New-FakeNativeResult 0 @($readyNodeJson)
        'kubectl|get namespace ewsp -o name' = New-FakeNativeResult 0 @('namespace/ewsp')
        'kubectl|get storageclass standard -o json' = New-FakeNativeResult 0 @($storageJson)
    }
    $kubectlResolver = { param($name) if ($name -eq 'kubectl') { [PSCustomObject]@{ Name = 'kubectl' } } }
    $healthyKubeRunner = {
        param($filePath, $arguments)
        $key = "$filePath|$($arguments -join ' ')"
        if ($healthyKubeResults.ContainsKey($key)) { return $healthyKubeResults[$key] }
        New-FakeNativeResult 1 @("unsupported fake command: $key")
    }.GetNewClosure()
    $healthyKube = Get-EwspKubernetesEnvironment -RuntimeEnvironment $kubeRuntime -CommandResolver $kubectlResolver -CommandRunner $healthyKubeRunner
    Assert-Equal $healthyKube.Kubernetes.ClientVersion 'v1.36.1' 'Kubernetes detection records kubectl client version'
    Assert-Equal $healthyKube.Kubernetes.Context 'docker-desktop' 'Kubernetes detection records current context'
    Assert-Equal $healthyKube.Kubernetes.ApiReachable $true 'Kubernetes detection records reachable API'
    Assert-Equal $healthyKube.Kubernetes.DockerDesktopKind $true 'Kubernetes detection verifies Docker Desktop kind identity'
    Assert-Equal $healthyKube.Kubernetes.NamespaceExists $true 'Kubernetes detection records namespace state'
    Assert-Equal $healthyKube.Kubernetes.StorageClass.VolumeBindingMode 'WaitForFirstConsumer' 'Kubernetes detection records storage binding mode'
    Assert-EwspKubernetesEnvironment $healthyKube -RequireDocker | Out-Null
    $script:PassCount++
    Write-Host 'PASS: verified Kubernetes environment passes safety gate'

    $missingKubectlRuntime = [PSCustomObject]@{ Kubernetes = $null }
    $missingKubectl = Get-EwspKubernetesEnvironment -RuntimeEnvironment $missingKubectlRuntime -CommandResolver { param($name) $null } -CommandRunner $healthyKubeRunner
    Assert-ThrowsContains { Assert-EwspKubernetesEnvironment $missingKubectl | Out-Null } 'kubectl is not installed' 'missing kubectl is rejected'

    $wrongContextResults = @{
        'kubectl|version --client -o json' = New-FakeNativeResult 0 @($clientJson)
        'kubectl|config current-context' = New-FakeNativeResult 0 @('production')
    }
    $wrongContextRunner = {
        param($filePath, $arguments)
        $key = "$filePath|$($arguments -join ' ')"
        if ($wrongContextResults.ContainsKey($key)) { return $wrongContextResults[$key] }
        New-FakeNativeResult 1
    }.GetNewClosure()
    $wrongContext = Get-EwspKubernetesEnvironment -RuntimeEnvironment ([PSCustomObject]@{}) -CommandResolver $kubectlResolver -CommandRunner $wrongContextRunner
    Assert-ThrowsContains { Assert-EwspKubernetesEnvironment $wrongContext | Out-Null } "current context is 'production'" 'wrong Kubernetes context fails before cluster access'
    Assert-Equal $wrongContext.Kubernetes.ApiReachable $false 'wrong context is not probed through the Kubernetes API'

    $apiResults = $healthyKubeResults.Clone()
    $apiResults['kubectl|version -o json'] = New-FakeNativeResult 1 @('connection refused')
    $apiRunner = {
        param($filePath, $arguments)
        $key = "$filePath|$($arguments -join ' ')"
        if ($apiResults.ContainsKey($key)) { return $apiResults[$key] }
        New-FakeNativeResult 1
    }.GetNewClosure()
    $unreachableApi = Get-EwspKubernetesEnvironment -RuntimeEnvironment ([PSCustomObject]@{}) -CommandResolver $kubectlResolver -CommandRunner $apiRunner
    Assert-ThrowsContains { Assert-EwspKubernetesEnvironment $unreachableApi | Out-Null } 'API for context' 'unreachable Kubernetes API is rejected'

    $notReadyResults = $healthyKubeResults.Clone()
    $notReadyResults['kubectl|get nodes -o json'] = New-FakeNativeResult 0 @(($readyNodeJson -replace '"status":"True"', '"status":"False"'))
    $notReadyRunner = {
        param($filePath, $arguments)
        $key = "$filePath|$($arguments -join ' ')"
        if ($notReadyResults.ContainsKey($key)) { return $notReadyResults[$key] }
        New-FakeNativeResult 1
    }.GetNewClosure()
    $notReady = Get-EwspKubernetesEnvironment -RuntimeEnvironment ([PSCustomObject]@{}) -CommandResolver $kubectlResolver -CommandRunner $notReadyRunner
    Assert-ThrowsContains { Assert-EwspKubernetesEnvironment $notReady | Out-Null } 'NotReady' 'NotReady Kubernetes node is rejected'

    $testSecretValues = @{
        POSTGRES_USER = 'test-db-user'; POSTGRES_PASSWORD = 'test-db-password-private'
        MINIO_ROOT_USER = 'test-minio-user'; MINIO_ROOT_PASSWORD = 'test-minio-password-private'
        JWT_SECRET = 'test-jwt-private'
        EWSP_MAIL_ENABLED = 'true'; EWSP_MAIL_HOST = 'smtp.example.com'; EWSP_MAIL_PORT = '587'
        EWSP_MAIL_USERNAME = 'mailer@example.com'; EWSP_MAIL_PASSWORD = 'test-smtp-password-private'
        EWSP_MAIL_FROM = 'mailer@example.com'; EWSP_MAIL_SMTP_AUTH = 'true'; EWSP_MAIL_STARTTLS_ENABLE = 'true'
    }
    $secretOutput = @(& { New-EwspKubernetesSecretArtifact $localRoot $testSecretValues -SkipAcl } *>&1)
    $secretPath = [string]$secretOutput[-1]
    $secretText = Get-Content -Raw -LiteralPath $secretPath
    Assert-NotContains $secretText 'test-db-password-private' 'temporary Kubernetes Secret stores no plaintext password'
    Assert-NotContains $secretText 'test-smtp-password-private' 'temporary Kubernetes Secret stores no plaintext SMTP password'
    Assert-NotContains ($secretOutput -join ' ') 'test-jwt-private' 'Kubernetes Secret preparation does not log secret values'
    Assert-NotContains ($secretOutput -join ' ') 'test-smtp-password-private' 'Kubernetes Secret preparation does not log SMTP credentials'
    $secretObject = $secretText | ConvertFrom-Json
    Assert-Equal (@($secretObject.data.PSObject.Properties.Name | Sort-Object) -join ',') 'EWSP_MAIL_ENABLED,EWSP_MAIL_FROM,EWSP_MAIL_HOST,EWSP_MAIL_PASSWORD,EWSP_MAIL_PORT,EWSP_MAIL_SMTP_AUTH,EWSP_MAIL_STARTTLS_ENABLE,EWSP_MAIL_USERNAME,JWT_SECRET,MINIO_ROOT_PASSWORD,MINIO_ROOT_USER,POSTGRES_PASSWORD,POSTGRES_USER' 'temporary Kubernetes Secret has exactly required keys'
    $incompleteSecretValues = $testSecretValues.Clone()
    $incompleteSecretValues.Remove('JWT_SECRET')
    Assert-ThrowsContains { New-EwspKubernetesSecretArtifact $localRoot $incompleteSecretValues -SkipAcl | Out-Null } 'JWT_SECRET' 'missing Kubernetes Secret setting is rejected by name'
    $missingMailPassword = $testSecretValues.Clone()
    $missingMailPassword.Remove('EWSP_MAIL_PASSWORD')
    Assert-ThrowsContains { New-EwspKubernetesSecretArtifact $localRoot $missingMailPassword -SkipAcl | Out-Null } 'EWSP_MAIL_PASSWORD' 'missing SMTP Secret setting is rejected by name'

    $tunnelDisabled = Get-EwspPermanentTunnelConfiguration @{}
    Assert-Equal $tunnelDisabled.Enabled $false 'permanent tunnel defaults to disabled when configuration is absent'
    $tokenOnly = Get-EwspPermanentTunnelConfiguration @{ CLOUDFLARE_TUNNEL_TOKEN = 'token-present-but-not-enabled' }
    Assert-Equal $tokenOnly.Enabled $false 'token presence alone never enables the permanent tunnel'
    Assert-ThrowsContains { Get-EwspPermanentTunnelConfiguration @{ CLOUDFLARE_TUNNEL_ENABLED = 'true' } | Out-Null } 'CLOUDFLARE_TUNNEL_TOKEN' 'enabled permanent tunnel requires a token without printing it'
    Assert-ThrowsContains { Get-EwspPermanentTunnelConfiguration @{ CLOUDFLARE_TUNNEL_ENABLED = 'sometimes' } | Out-Null } 'exactly true or false' 'permanent tunnel enable flag is strict'
    $tunnelEnabled = Get-EwspPermanentTunnelConfiguration @{
        CLOUDFLARE_TUNNEL_ENABLED = 'true'; CLOUDFLARE_TUNNEL_TOKEN = 'opaque-cloudflare-token'
        CLOUDFLARE_PUBLIC_HOSTNAME = 'EWSP.Example.com'
    }
    Assert-Equal $tunnelEnabled.Enabled $true 'explicit valid permanent tunnel configuration enables deployment'
    Assert-Equal $tunnelEnabled.PublicHostname 'ewsp.example.com' 'safe public hostname is normalized for status'
    Assert-ThrowsContains { Get-EwspPermanentTunnelConfiguration @{ CLOUDFLARE_TUNNEL_ENABLED = 'false'; CLOUDFLARE_PUBLIC_HOSTNAME = 'https://ewsp.example.com/path' } | Out-Null } 'bare DNS hostname' 'public hostname rejects URL syntax'
    Assert-NotContains (Protect-EwspDiagnosticText 'TUNNEL_TOKEN=opaque-cloudflare-token' @{ CLOUDFLARE_TUNNEL_TOKEN = 'opaque-cloudflare-token' }) 'opaque-cloudflare-token' 'Cloudflare token is redacted from diagnostics'

    Assert-Equal (ConvertTo-EwspPodCidrRegex '10.77.8.0/24') '^(?:10\.77\.8\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]))$' 'Pod CIDR converts to a full-match Tomcat regex'
    Assert-ThrowsContains { ConvertTo-EwspPodCidrRegex '10.77.8.1/24' | Out-Null } 'host bits' 'non-canonical Pod CIDR is rejected'
    Assert-ThrowsContains { ConvertTo-EwspPodCidrRegex '10.77.8.0/99' | Out-Null } 'valid canonical IPv4 CIDR' 'invalid Pod CIDR prefix is rejected'
    $podCidrNode = @{
        metadata = @{ name = 'desktop-control-plane' }; spec = @{ podCIDR = '10.77.8.0/24'; podCIDRs = @('10.77.8.0/24') }
        status = @{ conditions = @(@{ type = 'Ready'; status = 'True' }) }
    }
    $podCidrRunner = { param($filePath, $arguments) [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($podCidrNode) } | ConvertTo-Json -Depth 8 -Compress)) } }.GetNewClosure()
    $podBoundary = Get-EwspNodePodCidr $podCidrRunner
    Assert-Equal $podBoundary.Cidr '10.77.8.0/24' 'node-assigned Pod CIDR is derived dynamically'
    Assert-NotContains $podBoundary.Regex '127\.0\.0\.1' 'permanent trusted boundary excludes loopback'
    $multipleCidrNode = $podCidrNode.Clone()
    $multipleCidrNode.spec = @{ podCIDR = '10.77.8.0/24'; podCIDRs = @('10.77.8.0/24', 'fd00::/64') }
    $multipleCidrRunner = { param($filePath, $arguments) [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($multipleCidrNode) } | ConvertTo-Json -Depth 8 -Compress)) } }.GetNewClosure()
    Assert-ThrowsContains { Get-EwspNodePodCidr $multipleCidrRunner | Out-Null } 'exactly one node-assigned Pod CIDR' 'multiple Pod CIDRs fail closed without broad fallback'

    $cloudflareSecretOutput = @(& { New-EwspCloudflareTunnelSecretArtifact $localRoot 'opaque-cloudflare-token' -SkipAcl } *>&1)
    $cloudflareSecretPath = [string]$cloudflareSecretOutput[-1]
    $cloudflareSecretText = Get-Content -Raw -LiteralPath $cloudflareSecretPath
    Assert-NotContains $cloudflareSecretText 'opaque-cloudflare-token' 'temporary Cloudflare Secret stores no plaintext token'
    Assert-NotContains ($cloudflareSecretOutput -join ' ') 'opaque-cloudflare-token' 'Cloudflare Secret preparation never logs the token'
    $cloudflareSecretObject = $cloudflareSecretText | ConvertFrom-Json
    Assert-Equal $cloudflareSecretObject.metadata.name 'cloudflared-tunnel-token' 'Cloudflare Secret uses the stable runtime name'
    Assert-Equal (@($cloudflareSecretObject.data.PSObject.Properties.Name) -join ',') 'token' 'Cloudflare Secret has only the token key'

    $backendGhcrImage = 'ghcr.io/mohammad-hamadi/ewsp-backend:8d21240124744909af65a5b535c52e5b4b064931'
    $dashboardGhcrImage = 'ghcr.io/mohammad-hamadi/ewsp-dashboard:b7fb4e7b83b3b07737fd2d7bb7ca07a7df1edd6c'
    $ghcrValues = @{ EWSP_BACKEND_IMAGE = $backendGhcrImage; EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage; GHCR_USERNAME = 'test-user'; GHCR_TOKEN = 'opaque-ghcr-token' }
    $ghcr = Get-EwspGhcrConfiguration $ghcrValues -RequireCredentials
    Assert-Equal $ghcr.BackendImage $backendGhcrImage 'backend immutable GHCR image configuration is accepted'
    Assert-Equal $ghcr.DashboardImage $dashboardGhcrImage 'dashboard immutable GHCR image configuration is accepted'
    foreach ($invalid in @(
        @{ Values = @{ EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage }; Category = 'GHCR_CONFIGURATION_MISSING'; Label = 'missing backend image config' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = $backendGhcrImage }; Category = 'GHCR_CONFIGURATION_MISSING'; Label = 'missing dashboard image config' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = 'ghcr.io/mohammad-hamadi/ewsp-backend:latest'; EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage }; Category = 'GHCR_IMAGE_INVALID'; Label = 'latest tag' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = $backendGhcrImage; EWSP_DASHBOARD_IMAGE = 'ghcr.io/mohammad-hamadi/ewsp-dashboard:main' }; Category = 'GHCR_IMAGE_INVALID'; Label = 'main tag' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = 'docker.io/mohammad-hamadi/ewsp-backend:8d21240124744909af65a5b535c52e5b4b064931'; EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage }; Category = 'GHCR_IMAGE_INVALID'; Label = 'wrong registry' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = 'ghcr.io/mohammad-hamadi/not-backend:8d21240124744909af65a5b535c52e5b4b064931'; EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage }; Category = 'GHCR_IMAGE_INVALID'; Label = 'wrong repository' },
        @{ Values = @{ EWSP_BACKEND_IMAGE = 'malformed'; EWSP_DASHBOARD_IMAGE = $dashboardGhcrImage }; Category = 'GHCR_IMAGE_INVALID'; Label = 'malformed image' }
    )) { Assert-ThrowsCategory { Get-EwspGhcrConfiguration $invalid.Values | Out-Null } $invalid.Category "$($invalid.Label) is rejected" }
    $missingUsername = $ghcrValues.Clone(); $missingUsername.Remove('GHCR_USERNAME')
    Assert-ThrowsCategory { Get-EwspGhcrConfiguration $missingUsername -RequireCredentials | Out-Null } 'GHCR_CREDENTIALS_MISSING' 'missing GHCR username is rejected'
    $missingToken = $ghcrValues.Clone(); $missingToken.Remove('GHCR_TOKEN')
    Assert-ThrowsCategory { Get-EwspGhcrConfiguration $missingToken -RequireCredentials | Out-Null } 'GHCR_CREDENTIALS_MISSING' 'missing GHCR token is rejected'
    $ghcrSecretOutput = @(& { New-EwspGhcrPullSecretArtifact $localRoot $ghcr -SkipAcl } *>&1)
    $ghcrSecretPath = [string]$ghcrSecretOutput[-1]
    $ghcrSecretText = Get-Content -Raw -LiteralPath $ghcrSecretPath
    Assert-NotContains $ghcrSecretText 'opaque-ghcr-token' 'temporary GHCR Secret stores no plaintext token'
    Assert-NotContains ($ghcrSecretOutput -join ' ') 'opaque-ghcr-token' 'GHCR Secret preparation never logs the token'
    $ghcrSecretObject = $ghcrSecretText | ConvertFrom-Json
    Assert-Equal $ghcrSecretObject.metadata.name 'ghcr-pull' 'GHCR pull Secret uses stable name'
    Assert-Equal $ghcrSecretObject.type 'kubernetes.io/dockerconfigjson' 'GHCR pull Secret uses Docker registry type'

    $backendConfigText = Get-Content -Raw (Join-Path $localRoot 'k8s\backend\configmap.yaml')
    $backendDeploymentText = Get-Content -Raw (Join-Path $localRoot 'k8s\backend\deployment.yaml')
    $exactMobileUrl = 'https://github.com/Mohammad-Hamadi/ewsp-mobile/releases/download/v1.0.1/ewsp-1.0.1.apk'
    Assert-Contains $backendConfigText 'EWSP_MOBILE_LATEST_VERSION: 1.0.1' 'backend ConfigMap contains exact mobile version 1.0.1'
    Assert-Contains $backendConfigText 'EWSP_MOBILE_LATEST_VERSION_CODE: "2"' 'backend ConfigMap contains exact mobile version code 2'
    Assert-Contains $backendConfigText "EWSP_MOBILE_UPDATE_URL: $exactMobileUrl" 'backend ConfigMap contains exact mobile update URL'
    Assert-Equal ([Uri]$exactMobileUrl).Scheme 'https' 'mobile update URL uses HTTPS'
    Assert-Contains $backendDeploymentText 'name: backend-config' 'backend Pod consumes non-secret mobile metadata through the existing ConfigMap envFrom'
    Assert-Contains $backendDeploymentText 'key: EWSP_MAIL_PASSWORD' 'backend Pod sources the SMTP password from a Kubernetes Secret key'
    Assert-NotContains $backendConfigText 'EWSP_MAIL_PASSWORD' 'backend ConfigMap contains no SMTP password'
    Assert-Contains $composeConfiguration 'EWSP_MAIL_PASSWORD: ${EWSP_MAIL_PASSWORD:-}' 'Compose forwards SMTP credentials without hardcoding them'
    Assert-NotContains $secretText 'EWSP_MOBILE_' 'mobile release metadata is absent from the Kubernetes Secret artifact'
    Assert-Equal ([regex]::Matches(($backendConfigText + $backendDeploymentText + $composeConfiguration), '(?i)minimum[_A-Z]*supported|force[_A-Z]*update|optional[_A-Z]*update').Count) 0 'mobile runtime configuration has no minimum, force, or optional update flag'
    $envExampleText = Get-Content -Raw (Join-Path $localRoot '.env.example')
    Assert-Contains $envExampleText 'EWSP_MOBILE_LATEST_VERSION=1.0.1' 'local environment example documents mobile version 1.0.1'
    Assert-Contains $envExampleText 'EWSP_MOBILE_LATEST_VERSION_CODE=2' 'local environment example documents mobile version code 2'
    Assert-Contains $envExampleText "EWSP_MOBILE_UPDATE_URL=$exactMobileUrl" 'local environment example documents the exact mobile update URL'
    Assert-NotContains (Get-Content -Raw (Join-Path $localRoot 'config\deployment.env.example')) 'EWSP_MOBILE_' 'public mobile metadata is not placed in protected deployment credentials'
    $deploymentExampleText = Get-Content -Raw (Join-Path $localRoot 'config\deployment.env.example')
    Assert-Contains $deploymentExampleText 'EWSP_MAIL_PASSWORD=' 'protected deployment configuration documents the SMTP password key without a value'
    Assert-NotContains $deploymentExampleText 'test-smtp-password-private' 'tracked deployment example contains no SMTP credential'

    $fingerprintFixture = Join-Path $testRoot 'backend-config-fingerprint.yaml'
    Set-Content -LiteralPath $fingerprintFixture -Value $backendConfigText -NoNewline
    $fingerprintV1 = Get-EwspBackendConfigFingerprint $fingerprintFixture
    Set-Content -LiteralPath $fingerprintFixture -Value ($backendConfigText.Replace('EWSP_MOBILE_LATEST_VERSION_CODE: "2"','EWSP_MOBILE_LATEST_VERSION_CODE: "3"')) -NoNewline
    $fingerprintV2 = Get-EwspBackendConfigFingerprint $fingerprintFixture
    Assert-Equal ($fingerprintV1 -ne $fingerprintV2) $true 'mobile metadata mutation changes the backend configuration fingerprint'
    Assert-Equal $fingerprintV1.Length 64 'backend configuration fingerprint is a SHA-256 value'

    $backendSourceHash = (Get-FileHash (Join-Path $localRoot 'k8s\backend\deployment.yaml') -Algorithm SHA256).Hash
    $dashboardSourceHash = (Get-FileHash (Join-Path $localRoot 'k8s\dashboard\deployment.yaml') -Algorithm SHA256).Hash
    $renderRunner = {
        param($filePath, $arguments)
        $source = $arguments[[Array]::IndexOf($arguments, '-f') + 1]
        $assignment = @($arguments | Where-Object { $_ -match '^(backend|dashboard)=' })[0]
        $image = $assignment.Substring($assignment.IndexOf('=') + 1)
        $renderedText = (Get-Content -Raw -LiteralPath $source) -replace 'ewsp-(backend|dashboard):replace-with-ewsp-local-tag', $image
        New-FakeNativeResult 0 @($renderedText -split "`r?`n")
    }
    $mailFingerprintV1 = Get-EwspMailConfigurationFingerprint $testSecretValues
    $mailFingerprintValuesV2 = $testSecretValues.Clone(); $mailFingerprintValuesV2.EWSP_MAIL_PASSWORD = 'rotated-test-smtp-password-private'
    $mailFingerprintV2 = Get-EwspMailConfigurationFingerprint $mailFingerprintValuesV2
    Assert-Equal ($mailFingerprintV1 -ne $mailFingerprintV2) $true 'SMTP credential rotation changes the backend mail configuration fingerprint'
    Assert-Equal $mailFingerprintV1.Length 64 'backend mail configuration fingerprint is a SHA-256 value'
    $rendered = New-EwspKubernetesRenderedManifests $localRoot $backendGhcrImage $dashboardGhcrImage $testSecretValues $renderRunner
    Assert-Contains (Get-Content -Raw $rendered.Backend) $backendGhcrImage 'backend placeholder renders to exact image'
    Assert-Contains (Get-Content -Raw $rendered.Dashboard) $dashboardGhcrImage 'dashboard placeholder renders to exact image'
    Assert-Contains (Get-Content -Raw $rendered.Backend) "ewsp.local/backend-config-sha256: $fingerprintV1" 'rendered backend Pod template contains the current ConfigMap fingerprint'
    Assert-NotContains (Get-Content -Raw $rendered.Backend) 'replace-with-backend-config-sha256' 'rendered backend Pod template resolves the ConfigMap fingerprint placeholder'
    Assert-Contains (Get-Content -Raw $rendered.Backend) "ewsp.local/backend-mail-config-sha256: $mailFingerprintV1" 'rendered backend Pod template contains the protected SMTP configuration fingerprint'
    Assert-NotContains (Get-Content -Raw $rendered.Backend) 'replace-with-backend-mail-config-sha256' 'rendered backend Pod template resolves the SMTP fingerprint placeholder'
    Assert-NotContains (Get-Content -Raw $rendered.Dashboard) 'backend-mail-config-sha256' 'SMTP credential changes do not roll out the dashboard'
    Assert-NotContains (Get-Content -Raw $rendered.Dashboard) 'backend-config-sha256' 'backend ConfigMap changes do not roll out the dashboard'
    Assert-Contains $backendDeploymentText 'type: Recreate' 'mobile ConfigMap changes use the existing short Recreate backend rollout'
    Assert-Equal (Get-FileHash (Join-Path $localRoot 'k8s\backend\deployment.yaml') -Algorithm SHA256).Hash $backendSourceHash 'backend source manifest remains unchanged after rendering'
    Assert-Equal (Get-FileHash (Join-Path $localRoot 'k8s\dashboard\deployment.yaml') -Algorithm SHA256).Hash $dashboardSourceHash 'dashboard source manifest remains unchanged after rendering'
    Assert-ThrowsCategory { New-EwspKubernetesRenderedManifests $localRoot 'ghcr.io/mohammad-hamadi/ewsp-backend:latest' $dashboardGhcrImage $testSecretValues $renderRunner | Out-Null } 'GHCR_IMAGE_INVALID' 'latest Kubernetes application image is rejected during rendering'

    $applyPlan = @(Get-EwspKubernetesApplyPlan $localRoot $rendered $secretPath $ghcrSecretPath)
    Assert-Equal (@($applyPlan.Stage) -join ',') 'NAMESPACE,GHCR_SECRET,CONFIGMAPS,SECRET,POSTGRES,REDIS,MINIO,BACKEND,DASHBOARD' 'Kubernetes resources have deterministic apply order'
    Assert-Equal @($applyPlan | Where-Object { $_.Files -contains (Join-Path $localRoot 'k8s\config\secrets.example.yaml') }).Count 0 'placeholder Secret is absent from apply plan'
    $validationCapture = @{}
    $validationRunner = {
        param($filePath, $arguments)
        $validationCapture['Arguments'] = @($arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @('validated') }
    }.GetNewClosure()
    Assert-EwspKubernetesManifestSet $localRoot $applyPlan $backendGhcrImage $dashboardGhcrImage $validationRunner | Out-Null
    $script:PassCount++
    Write-Host 'PASS: complete rendered Kubernetes manifest set validates'
    Assert-Contains ($validationCapture.Arguments -join ' ') '--dry-run=client --validate=true' 'manifest validation is strict client-side validation'
    Assert-NotContains ($validationCapture.Arguments -join ' ') 'secrets.example.yaml' 'example Secret is never validated as a real apply input'

    $permanentApplyPlan = @(Get-EwspKubernetesApplyPlan $localRoot $rendered $secretPath $ghcrSecretPath $tunnelEnabled $cloudflareSecretPath)
    Assert-Equal (@($permanentApplyPlan.Stage) -join ',') 'NAMESPACE,GHCR_SECRET,CONFIGMAPS,SECRET,POSTGRES,REDIS,MINIO,BACKEND,DASHBOARD,NETWORKPOLICIES,CLOUDFLARE_SECRET,CLOUDFLARED' 'permanent tunnel resources have deterministic apply order'
    Assert-EwspKubernetesManifestSet $localRoot $permanentApplyPlan $backendGhcrImage $dashboardGhcrImage $validationRunner | Out-Null
    $script:PassCount++
    Write-Host 'PASS: permanent tunnel rendered manifest set validates'
    $cloudflaredManifest = Get-Content -Raw (Join-Path $localRoot 'k8s\cloudflared\deployment.yaml')
    Assert-Contains $cloudflaredManifest 'cloudflare/cloudflared:2026.8.2' 'cloudflared image is version-pinned'
    Assert-NotContains $cloudflaredManifest ':latest' 'cloudflared manifest never uses latest'
    Assert-Contains $cloudflaredManifest 'readOnlyRootFilesystem: true' 'cloudflared uses a read-only root filesystem'
    Assert-Contains $cloudflaredManifest 'runAsNonRoot: true' 'cloudflared runs as non-root'
    Assert-Contains $cloudflaredManifest 'path: /ready' 'cloudflared readiness uses its local readiness endpoint'
    Assert-Contains $cloudflaredManifest 'name: TUNNEL_TOKEN' 'cloudflared receives token through an environment Secret reference'
    Assert-NotContains $cloudflaredManifest 'cert.pem' 'cloudflared runtime does not require an account certificate'
    Assert-NotContains $cloudflaredManifest 'credentials.json' 'cloudflared runtime does not require credentials JSON'
    $backendPolicy = Get-Content -Raw (Join-Path $localRoot 'k8s\networkpolicies\backend-ingress.yaml')
    $dashboardPolicy = Get-Content -Raw (Join-Path $localRoot 'k8s\networkpolicies\dashboard-ingress.yaml')
    Assert-Contains $backendPolicy 'app.kubernetes.io/name: dashboard' 'backend ingress is allowed only from dashboard identity'
    Assert-Contains $backendPolicy 'port: 8080' 'backend ingress policy targets TCP 8080'
    Assert-NotContains $backendPolicy 'ipBlock:' 'backend policy does not use a broad CIDR allowance'
    Assert-Contains $dashboardPolicy 'app.kubernetes.io/name: cloudflared' 'dashboard ingress is allowed only from cloudflared identity'
    Assert-Contains $dashboardPolicy 'port: 80' 'dashboard ingress policy targets TCP 80'
    Assert-NotContains $dashboardPolicy 'app.kubernetes.io/name: backend' 'dashboard policy does not authorize backend as a source'

    $cloudflaredFailureRunner = { param($filePath, $arguments) if ($arguments[0] -eq 'logs') { [PSCustomObject]@{ ExitCode = 0; Output = @('TUNNEL_TOKEN=opaque-cloudflare-token') } } else { [PSCustomObject]@{ ExitCode = 1; Output = @('timed out') } } }
    Assert-ThrowsContains { Wait-EwspCloudflaredReady @{ CLOUDFLARE_TUNNEL_TOKEN = 'opaque-cloudflare-token' } $cloudflaredFailureRunner | Out-Null } '<redacted>' 'cloudflared readiness failure is classified with token redaction'

    $pullPod = [PSCustomObject]@{ status = [PSCustomObject]@{ phase = 'Pending'; containerStatuses = @([PSCustomObject]@{ state = [PSCustomObject]@{ waiting = [PSCustomObject]@{ reason = 'ImagePullBackOff' } }; lastState = [PSCustomObject]@{} }) } }
    Assert-Equal (Get-EwspKubernetesPodReason $pullPod) 'ImagePullBackOff' 'Pod diagnostics recognize image pull failure'
    Assert-Equal (Get-EwspKubernetesFailureCategory @([PSCustomObject]@{ Reason = 'ErrImagePull' })) 'IMAGE_PULL_FAILED' 'private registry pull failure is classified'
    Assert-Equal (Get-EwspKubernetesFailureCategory @([PSCustomObject]@{ Reason = 'ImagePullBackOff' })) 'IMAGE_PULL_BACKOFF' 'ImagePullBackOff is classified'
    $oomPod = [PSCustomObject]@{ status = [PSCustomObject]@{ phase = 'Running'; containerStatuses = @([PSCustomObject]@{ state = [PSCustomObject]@{}; lastState = [PSCustomObject]@{ terminated = [PSCustomObject]@{ reason = 'OOMKilled' } } }) } }
    Assert-Equal (Get-EwspKubernetesPodReason $oomPod) 'OOMKilled' 'Pod diagnostics recognize OOMKilled'
    $unscheduledPod = [PSCustomObject]@{ status = [PSCustomObject]@{ phase = 'Pending'; containerStatuses = @(); conditions = @([PSCustomObject]@{ type = 'PodScheduled'; status = 'False'; reason = 'Unschedulable'; message = 'insufficient memory' }) } }
    Assert-Contains (Get-EwspKubernetesPodReason $unscheduledPod) 'insufficient memory' 'Pod diagnostics preserve scheduling evidence'
    Assert-Equal (Get-EwspKubernetesPodReason $null) 'Missing' 'Pod diagnostics recognize missing Pod'

    $snapshotMode = @{ BackendReason = $null; MissingDashboard = $false }
    $snapshotRunner = {
        param($filePath, $arguments)
        if ($arguments[1] -in @('deployment', 'statefulset')) {
            $name = $arguments[2]
            if ($name -eq 'dashboard' -and $snapshotMode.MissingDashboard) {
                return [PSCustomObject]@{ ExitCode = 1; Output = @('not found') }
            }
            $ready = if ($name -eq 'backend' -and $snapshotMode.BackendReason) { 0 } else { 1 }
            $controller = @{
                spec = @{ replicas = 1; template = @{ spec = @{ containers = @(@{ name = $name; image = "${name}:test-tag" }) } } }
                status = @{ readyReplicas = $ready }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = @(($controller | ConvertTo-Json -Depth 8 -Compress)) }
        }
        if ($arguments[1] -eq 'pods') {
            $selector = $arguments[[Array]::IndexOf($arguments, '-l') + 1]
            $name = $selector.Substring($selector.LastIndexOf('=') + 1)
            if ($name -eq 'dashboard' -and $snapshotMode.MissingDashboard) {
                return [PSCustomObject]@{ ExitCode = 0; Output = @('{"items":[]}') }
            }
            $isFailure = $name -eq 'backend' -and $snapshotMode.BackendReason
            $state = if ($isFailure) { @{ waiting = @{ reason = $snapshotMode.BackendReason } } } else { @{ running = @{} } }
            $pod = @{
                metadata = @{ name = "${name}-pod"; creationTimestamp = '2026-08-23T00:00:00Z' }
                spec = @{ containers = @(@{ name = $name; image = "${name}:test-tag" }) }
                status = @{ phase = $(if ($isFailure) { 'Pending' } else { 'Running' }); containerStatuses = @(@{ ready = (-not $isFailure); restartCount = $(if ($isFailure) { 3 } else { 0 }); imageID = "sha256:${name}"; state = $state }) }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($pod) } | ConvertTo-Json -Depth 12 -Compress)) }
        }
        [PSCustomObject]@{ ExitCode = 1; Output = @('unsupported') }
    }.GetNewClosure()
    $healthySnapshots = @(Get-EwspKubernetesWorkloadSnapshot $snapshotRunner)
    Assert-Equal @($healthySnapshots | Where-Object Ready).Count 5 'Kubernetes status recognizes all five healthy workloads'
    Assert-Equal @($healthySnapshots | Where-Object Name -eq 'backend')[0].Image 'backend:test-tag' 'Kubernetes status reports running application image'
    $matchingSnapshots = @(
        [PSCustomObject]@{ Name = 'backend'; Image = $backendGhcrImage },
        [PSCustomObject]@{ Name = 'dashboard'; Image = $dashboardGhcrImage }
    )
    Assert-Equal (Assert-EwspDeployedApplicationImages $ghcr $matchingSnapshots) $true 'configured and running immutable images can agree'
    $mismatchedSnapshots = @(
        [PSCustomObject]@{ Name = 'backend'; Image = $backendGhcrImage },
        [PSCustomObject]@{ Name = 'dashboard'; Image = 'ghcr.io/mohammad-hamadi/ewsp-dashboard:0000000000000000000000000000000000000000' }
    )
    Assert-ThrowsCategory { Assert-EwspDeployedApplicationImages $ghcr $mismatchedSnapshots | Out-Null } 'DEPLOYED_IMAGE_MISMATCH' 'configured and running image mismatch is rejected'
    $snapshotMode.BackendReason = 'ImagePullBackOff'
    $unhealthySnapshots = @(Get-EwspKubernetesWorkloadSnapshot $snapshotRunner)
    $unhealthyBackend = @($unhealthySnapshots | Where-Object Name -eq 'backend')[0]
    Assert-Equal $unhealthyBackend.Ready $false 'Kubernetes status marks unhealthy Pod non-ready'
    Assert-Equal $unhealthyBackend.Reason 'ImagePullBackOff' 'Kubernetes status reports unhealthy Pod reason'
    Assert-Equal $unhealthyBackend.Restarts 3 'Kubernetes status reports restart count'
    $snapshotMode.MissingDashboard = $true
    $missingSnapshots = @(Get-EwspKubernetesWorkloadSnapshot $snapshotRunner)
    Assert-Equal @($missingSnapshots | Where-Object Name -eq 'dashboard')[0].ControllerExists $false 'Kubernetes status recognizes missing controller'
    $pendingPvcRunner = {
        param($filePath, $arguments)
        $pvc = @{ metadata = @{ name = 'postgres-data-postgres-0' }; spec = @{ storageClassName = 'standard'; volumeName = $null }; status = @{ phase = 'Pending' } }
        [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($pvc) } | ConvertTo-Json -Depth 8 -Compress)) }
    }
    $pendingPvc = @(Get-EwspKubernetesPvcSnapshot $pendingPvcRunner)[0]
    Assert-Equal $pendingPvc.Status 'Pending' 'Kubernetes status recognizes Pending PVC'
    Assert-Equal $pendingPvc.Capacity '<pending>' 'Pending PVC status does not require a capacity field'

    Assert-Equal (Resolve-EwspKubernetesPortForwardAction $true $true $true) 'REUSE' 'healthy managed port-forward is reused'
    Assert-Equal (Resolve-EwspKubernetesPortForwardAction $false $false $true) 'CONFLICT' 'external dashboard port conflict is refused'
    Assert-Equal (Resolve-EwspKubernetesPortForwardAction $false $false $false) 'START' 'free dashboard port starts managed forward'
    Assert-Equal (Resolve-EwspKubernetesPortForwardAction $true $false $true) 'START' 'unhealthy managed forward is safely replaced'

    $forwardProfile = Join-Path $testRoot 'port-forward-profile'
    $forwardCheckoutA = Join-Path $testRoot 'port-forward-checkout-a'
    $forwardCheckoutB = Join-Path $testRoot 'port-forward-checkout-b'
    $forwardCheckoutC = Join-Path $testRoot 'port-forward-checkout-c'
    foreach($path in @($forwardCheckoutA,$forwardCheckoutB,$forwardCheckoutC)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
    $forwardPaths = Get-EwspDeploymentMachinePaths $forwardProfile
    Assert-Equal $forwardPaths.DashboardPortForwardState (Join-Path $forwardProfile '.ewsp\dashboard-port-forward.json') 'dashboard port-forward ownership state is machine-global under the user profile'
    $forwardStart = [DateTime]::UtcNow.AddMinutes(-5)
    $forwardExecutable = 'C:\Program Files\Docker\Docker\resources\bin\kubectl.exe'
    $forwardCommand = '"C:\Program Files\Docker\Docker\resources\bin\kubectl.exe" port-forward -n ewsp service/dashboard 3000:80'
    $forwardProcess = [PSCustomObject]@{Id=4242;ProcessName='kubectl';Path=$forwardExecutable;StartTime=$forwardStart}
    $forwardProcessProvider = {param($id) if($id -eq 4242){$forwardProcess}}.GetNewClosure()
    $forwardCommandProvider = {param($id) if($id -eq 4242){$forwardCommand}}.GetNewClosure()
    $forwardListenerProvider = {param($port) if($port -eq 3000){[PSCustomObject]@{OwningProcess=4242}}}
    $forwardHealthyProbe = {param($port) $port -eq 3000}
    $forwardState = [PSCustomObject]@{
        Version=2;Manager='ewsp-local';OwnershipSource='machine-global';OwnershipReason='test';ProcessId=4242
        StartTimeUtcTicks=[string]$forwardStart.ToUniversalTime().Ticks;ExecutablePath=$forwardExecutable
        CommandLineSha256=(Get-EwspTextSha256 $forwardCommand);Namespace='ewsp';Service='dashboard';LocalPort=3000;RemotePort=80
    }
    Assert-Equal (Test-EwspDashboardPortForwardCommandLine $forwardCommand 3000 80 'ewsp') $true 'exact EWSP dashboard port-forward command is accepted'
    Assert-Equal (Test-EwspDashboardPortForwardCommandLine ($forwardCommand -replace '-n ewsp','-n other') 3000 80 'ewsp') $false 'wrong dashboard port-forward namespace is rejected'
    Assert-Equal (Test-EwspDashboardPortForwardCommandLine ($forwardCommand -replace '3000:80','3001:80') 3000 80 'ewsp') $false 'wrong dashboard local port is rejected'
    Assert-Equal (Test-EwspDashboardPortForwardCommandLine ($forwardCommand -replace '3000:80','3000:81') 3000 80 'ewsp') $false 'wrong dashboard remote port is rejected'
    $validEvidence = Test-EwspDashboardPortForwardEvidence $forwardState $forwardProcessProvider $forwardCommandProvider $forwardListenerProvider $forwardHealthyProbe $forwardExecutable
    Assert-Equal $validEvidence.Valid $true 'managed forward validates PID, start time, executable, command, listener, and endpoint'
    $reusedPidProcess = [PSCustomObject]@{Id=4242;ProcessName='kubectl';Path=$forwardExecutable;StartTime=$forwardStart.AddMinutes(1)}
    $reusedPidProvider = {param($id) $reusedPidProcess}.GetNewClosure()
    Assert-Equal (Test-EwspDashboardPortForwardEvidence $forwardState $reusedPidProvider $forwardCommandProvider $forwardListenerProvider $forwardHealthyProbe $forwardExecutable).Reason 'PROCESS_IDENTITY_MISMATCH' 'PID reuse is rejected by process start-time mismatch'
    $wrongExecutableProcess = [PSCustomObject]@{Id=4242;ProcessName='kubectl';Path='C:\untrusted\kubectl.exe';StartTime=$forwardStart}
    $wrongExecutableProvider = {param($id) $wrongExecutableProcess}.GetNewClosure()
    Assert-Equal (Test-EwspDashboardPortForwardEvidence $forwardState $wrongExecutableProvider $forwardCommandProvider $forwardListenerProvider $forwardHealthyProbe $forwardExecutable).Reason 'EXECUTABLE_MISMATCH' 'wrong kubectl executable path is rejected'
    $wrongCommandProvider = {param($id) 'kubectl.exe port-forward -n other service/dashboard 3000:80'}
    Assert-Equal (Test-EwspDashboardPortForwardEvidence $forwardState $forwardProcessProvider $wrongCommandProvider $forwardListenerProvider $forwardHealthyProbe $forwardExecutable).Reason 'COMMAND_LINE_MISMATCH' 'wrong managed process command line is rejected'
    $wrongListenerProvider = {param($port) [PSCustomObject]@{OwningProcess=9999}}
    Assert-Equal (Test-EwspDashboardPortForwardEvidence $forwardState $forwardProcessProvider $forwardCommandProvider $wrongListenerProvider $forwardHealthyProbe $forwardExecutable).Reason 'LISTENER_OWNERSHIP_MISMATCH' 'listener owned by another PID is rejected'

    $legacyPath = Join-Path $forwardCheckoutA '.tmp\k8s\port-forward.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPath) -Force|Out-Null
    ([PSCustomObject]@{ProcessId=4242;StartTimeUtcTicks=[string]$forwardStart.ToUniversalTime().Ticks;Namespace='ewsp';Service='dashboard';LocalPort=3000;RemotePort=80}|ConvertTo-Json)|Set-Content -LiteralPath $legacyPath
    $migratedForward = Get-EwspManagedKubernetesPortForward -LocalRoot $forwardCheckoutA -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $migratedForward.Reason 'MIGRATED' 'valid checkout-local ownership state migrates without restarting the process'
    Assert-Equal (Test-Path -LiteralPath $legacyPath) $false 'obsolete checkout-local ownership state is removed after migration'
    Assert-Equal (Test-Path -LiteralPath $forwardPaths.DashboardPortForwardState) $true 'migration creates machine-global ownership state'
    $actionsForward = Get-EwspManagedKubernetesPortForward -LocalRoot $forwardCheckoutB -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $actionsForward.Process.Id 4242 'Actions checkout reuses the same machine-global managed forward PID'
    $startupForward = Get-EwspManagedKubernetesPortForward -LocalRoot $forwardCheckoutC -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $startupForward.Process.Id 4242 'startup reconciliation checkout reuses the same machine-global managed forward PID'
    $quickTunnelForward = Get-EwspManagedKubernetesPortForward -LocalRoot (Join-Path $testRoot 'quick-tunnel-checkout') -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $quickTunnelForward.Process.Id 4242 'Quick Tunnel checkout reuses the same machine-global managed forward PID'

    Remove-EwspDashboardPortForwardState $forwardProfile
    $adoptedForward = Get-EwspManagedKubernetesPortForward -LocalRoot $forwardCheckoutB -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $adoptedForward.Reason 'ADOPTED' 'missing state safely adopts only the exact healthy EWSP kubectl forward'
    Write-EwspDashboardPortForwardState $forwardState $forwardProfile|Out-Null
    $missingProcessProvider = {param($id) $null}
    $noListeners = {param($port) @()}
    $staleForward = Get-EwspManagedKubernetesPortForward -LocalRoot $forwardCheckoutB -ProcessProvider $missingProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $noListeners -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile
    Assert-Equal $staleForward.Active $false 'stale state becomes inactive when the recorded process exited'
    Assert-Equal (Test-Path -LiteralPath $forwardPaths.DashboardPortForwardState) $false 'stale machine-global state is cleaned when the process exited'
    $unrelatedProcess = [PSCustomObject]@{Id=9999;ProcessName='node';Path='C:\tools\node.exe';StartTime=$forwardStart}
    $unrelatedProvider = {param($id) if($id -eq 9999){$unrelatedProcess}}.GetNewClosure()
    $unrelatedListeners = {param($port) [PSCustomObject]@{OwningProcess=9999}}
    $unrelatedStopCounter = [PSCustomObject]@{Count=0}
    $unrelatedStop = {param($id) $unrelatedStopCounter.Count++}.GetNewClosure()
    Stop-EwspKubernetesPortForward -LocalRoot $forwardCheckoutB -Quiet -ProcessProvider $unrelatedProvider -Probe $forwardHealthyProbe -CommandLineProvider {param($id) 'node.exe server.js'} -ListenerProvider $unrelatedListeners -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile -StopAction $unrelatedStop|Out-Null
    Assert-Equal $unrelatedStopCounter.Count 0 'stop never terminates an unrelated process occupying dashboard port 3000'
    Write-EwspDashboardPortForwardState $forwardState $forwardProfile|Out-Null
    $managedStopCounter = [PSCustomObject]@{Count=0}
    $managedStop = {param($id) if($id -eq 4242){$managedStopCounter.Count++}}.GetNewClosure()
    Stop-EwspKubernetesPortForward -LocalRoot $forwardCheckoutB -Quiet -ProcessProvider $forwardProcessProvider -Probe $forwardHealthyProbe -CommandLineProvider $forwardCommandProvider -ListenerProvider $forwardListenerProvider -ExpectedKubectlPath $forwardExecutable -UserProfile $forwardProfile -StopAction $managedStop|Out-Null
    Assert-Equal $managedStopCounter.Count 1 'stop terminates a managed forward only after full ownership validation'
    Assert-Equal (Test-Path -LiteralPath $forwardPaths.DashboardPortForwardState) $false 'stop removes machine-global state after validated termination'
    $forwardLock = Enter-EwspDashboardPortForwardLock $forwardProfile
    Assert-ThrowsCategory { Enter-EwspDashboardPortForwardLock $forwardProfile 0|Out-Null } 'KUBERNETES_PORT_FORWARD_BUSY' 'machine-global forward lock prevents concurrent ownership/start races'
    Exit-EwspDashboardPortForwardLock $forwardLock
    $portForwardModuleText=Get-Content -Raw -LiteralPath (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
    Assert-Contains $portForwardModuleText 'DashboardPortForwardState = Join-Path $root' 'all persistent dashboard-forward ownership resolves from machine-global paths'
    Assert-Contains $portForwardModuleText 'LegacyPortForwardState' 'only explicit one-time migration references checkout-local forward state'

    $missingCloudflared = Get-EwspCloudflaredInfo -CommandResolver { param($name) $null }
    Assert-Equal $missingCloudflared.Available $false 'Quick Tunnel detects unavailable cloudflared'
    Assert-ThrowsContains { Assert-EwspCloudflaredAvailable $missingCloudflared | Out-Null } 'CLOUDFLARED_MISSING' 'missing cloudflared uses precise diagnostic category'
    $cloudflaredRunner = { param($filePath, $arguments) New-FakeNativeResult 0 @('cloudflared version 2026.8.0') }
    $cloudflaredInfo = Get-EwspCloudflaredInfo -CommandResolver { param($name) [PSCustomObject]@{ Source = 'C:\tools\cloudflared.exe' } } -CommandRunner $cloudflaredRunner
    Assert-Equal $cloudflaredInfo.Available $true 'Quick Tunnel accepts runnable cloudflared'
    Assert-Contains $cloudflaredInfo.Version '2026.8.0' 'Quick Tunnel reports cloudflared version'

    Assert-Equal (ConvertTo-EwspLiteralIpv4Regex '10.77.8.24') '10\.77\.8\.24' 'dashboard Pod IPv4 is escaped as a literal regex'
    Assert-Equal (New-EwspQuickTunnelTrustRegex '10.77.8.24') '^(?:10\.77\.8\.24|127\.0\.0\.1)$' 'temporary trust boundary contains only dashboard Pod and loopback'
    Assert-ThrowsContains { ConvertTo-EwspLiteralIpv4Regex '10.77.8.0/24' | Out-Null } 'DASHBOARD_POD_RESOLUTION_FAILED' 'non-IPv4 dashboard Pod value is rejected'

    $readyDashboardPod = @{
        metadata = @{ name = 'dashboard-test' }
        status = @{
            phase = 'Running'; podIP = '10.77.8.77'
            conditions = @(@{ type = 'Ready'; status = 'True' })
            containerStatuses = @(@{ ready = $true })
        }
    }
    $podRunner = {
        param($filePath, $arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($readyDashboardPod) } | ConvertTo-Json -Depth 8 -Compress)) }
    }.GetNewClosure()
    $resolvedPod = Get-EwspReadyDashboardPod $podRunner
    Assert-Equal $resolvedPod.Ip '10.77.8.77' 'current Ready dashboard Pod IP is derived by stable labels'
    $twoPodRunner = {
        param($filePath, $arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($readyDashboardPod, $readyDashboardPod) } | ConvertTo-Json -Depth 8 -Compress)) }
    }.GetNewClosure()
    Assert-ThrowsContains { Get-EwspReadyDashboardPod $twoPodRunner | Out-Null } 'found 2' 'Quick Tunnel requires exactly one Ready dashboard Pod'

    Assert-Equal (ConvertFrom-EwspQuickTunnelUrl 'INF Requesting new quick Tunnel on https://Calm-Fog-123.trycloudflare.com') 'https://calm-fog-123.trycloudflare.com' 'Quick Tunnel URL is parsed robustly from log text'
    Assert-Equal (ConvertFrom-EwspQuickTunnelUrl 'https://*.trycloudflare.com') $null 'wildcard trycloudflare origin is never accepted as a generated URL'

    Assert-Equal (ConvertTo-EwspQuickTunnelOrigin ' HTTPS://Calm-Fog-123.trycloudflare.com/ ') 'https://calm-fog-123.trycloudflare.com' 'mobile bootstrap safely normalizes a trailing slash and host case'
    Assert-ThrowsCategory { ConvertTo-EwspQuickTunnelOrigin 'http://calm-fog-123.trycloudflare.com' | Out-Null } 'MOBILE_BOOTSTRAP_URL_INVALID' 'mobile bootstrap rejects non-HTTPS origins'
    Assert-ThrowsCategory { ConvertTo-EwspQuickTunnelOrigin 'https://example.com' | Out-Null } 'MOBILE_BOOTSTRAP_URL_INVALID' 'mobile bootstrap rejects non-Quick-Tunnel hosts'
    Assert-ThrowsCategory { ConvertTo-EwspQuickTunnelOrigin 'https://calm-fog-123.trycloudflare.com/api' | Out-Null } 'MOBILE_BOOTSTRAP_URL_INVALID' 'mobile bootstrap rejects an appended API path'
    $bootstrapJson = ConvertTo-EwspMobileBootstrapJson 'https://calm-fog-123.trycloudflare.com/'
    $bootstrapObject = $bootstrapJson | ConvertFrom-Json
    Assert-Equal $bootstrapObject.apiBaseUrl 'https://calm-fog-123.trycloudflare.com' 'valid Quick Tunnel URL produces the exact bootstrap JSON origin'
    Assert-NotContains $bootstrapJson '/api' 'bootstrap JSON never appends the API prefix'
    Assert-Equal (ConvertFrom-EwspMobileBootstrapJson $bootstrapJson).ApiBaseUrl 'https://calm-fog-123.trycloudflare.com' 'raw bootstrap schema accepts exactly one normalized apiBaseUrl'
    Assert-Equal (ConvertFrom-EwspMobileBootstrapJson '{"apiBaseUrl":"https://safe.trycloudflare.com","token":"secret"}') $null 'raw bootstrap schema rejects additional secret-like fields'
    Assert-Equal ([bool](ConvertFrom-EwspMobileBootstrapJson (Get-Content -Raw (Join-Path $localRoot 'public\mobile-bootstrap.json')))) $true 'tracked dynamic bootstrap document continues to conform to the exact public contract'
    Assert-ThrowsCategory { Assert-EwspGitHubBootstrapWritePermission 'protected-test-token' { param($uri,$token) [PSCustomObject]@{permissions=[PSCustomObject]@{push=$false}} } | Out-Null } 'MOBILE_BOOTSTRAP_CREDENTIAL_REQUIRED' 'insufficient GitHub contents permission stops at the protected credential boundary'

    $rawAttempts = [PSCustomObject]@{ Count = 0 }
    $rawRetryInvoker = {
        param($uri)
        $rawAttempts.Count++
        if ($rawAttempts.Count -eq 1) { [PSCustomObject]@{ StatusCode=200; Content='{"apiBaseUrl":"https://old.trycloudflare.com"}' } }
        else { [PSCustomObject]@{ StatusCode=200; Content='{"apiBaseUrl":"https://safe.trycloudflare.com"}' } }
    }.GetNewClosure()
    $rawVerified = Get-EwspMobileBootstrap 'https://safe.trycloudflare.com' 2 $rawRetryInvoker { param($milliseconds) }
    Assert-Equal $rawVerified.Matches $true 'raw bootstrap verification retries until the exact expected endpoint is published'
    Assert-Equal $rawAttempts.Count 2 'raw bootstrap verification uses bounded retry attempts'
    $readyDiscovery = Get-EwspMobileDiscoveryStatus 'https://safe.trycloudflare.com' { param($uri) [PSCustomObject]@{StatusCode=200;Content='{"apiBaseUrl":"https://safe.trycloudflare.com"}'} }
    Assert-Equal $readyDiscovery.State 'READY' 'tunnel status classifies matching tunnel and bootstrap as READY'
    $staleDiscovery = Get-EwspMobileDiscoveryStatus 'https://new.trycloudflare.com' { param($uri) [PSCustomObject]@{StatusCode=200;Content='{"apiBaseUrl":"https://old.trycloudflare.com"}'} }
    Assert-Equal $staleDiscovery.State 'STALE' 'tunnel status classifies a mismatched bootstrap as STALE'
    $unavailableDiscovery = Get-EwspMobileDiscoveryStatus 'https://safe.trycloudflare.com' { param($uri) throw 'offline' }
    Assert-Equal $unavailableDiscovery.State 'UNAVAILABLE' 'tunnel status classifies an unreadable bootstrap as UNAVAILABLE'

    $publishRoot = Join-Path $testRoot 'bootstrap-publication'
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    $publishCalls = New-Object Collections.Generic.List[string]
    $publishGit = {
        param($workingDirectory, $arguments)
        $publishCalls.Add((@($arguments) -join ' ')) | Out-Null
        if ($arguments[0] -eq 'clone') { New-Item -ItemType Directory -Path $arguments[-1] -Force | Out-Null }
        if ($arguments[0] -eq 'diff') { return [PSCustomObject]@{ExitCode=0;Output=@('public/mobile-bootstrap.json')} }
        [PSCustomObject]@{ExitCode=0;Output=@()}
    }.GetNewClosure()
    $permission = { param($uri,$token) [PSCustomObject]@{permissions=[PSCustomObject]@{push=$true}} }
    $rawCurrent = { param($uri) [PSCustomObject]@{StatusCode=200;Content='{"apiBaseUrl":"https://safe.trycloudflare.com"}'} }
    $published = Publish-EwspMobileBootstrap $localRoot 'https://safe.trycloudflare.com/' 'protected-test-token' $publishGit $permission $rawCurrent { param($milliseconds) } $publishRoot -LockHeld
    Assert-Equal $published.ApiBaseUrl 'https://safe.trycloudflare.com' 'bootstrap publication retains a public origin without API suffix'
    Assert-Equal @($publishCalls | Where-Object { $_ -eq 'add -- public/mobile-bootstrap.json' }).Count 1 'bootstrap publication stages only the intended file'
    Assert-Equal @($publishCalls | Where-Object { $_ -match 'clone .*https://github.com/Mohammad-Hamadi/ewsp-local.git' }).Count 1 'bootstrap publication uses an isolated canonical checkout instead of checkout-relative state'
    Assert-Equal @($publishCalls | Where-Object { $_ -match '^push .*HEAD:refs/heads/main$' }).Count 1 'bootstrap publication pushes only its isolated bootstrap commit'
    Assert-NotContains ($publishCalls -join "`n") 'protected-test-token' 'Git publication never emits or places the protected token on a command line'

    $dirtyCalls = New-Object Collections.Generic.List[string]
    $dirtyGit = {
        param($workingDirectory, $arguments)
        $dirtyCalls.Add((@($arguments) -join ' ')) | Out-Null
        if ($arguments[0] -eq 'clone') { New-Item -ItemType Directory -Path $arguments[-1] -Force | Out-Null }
        if ($arguments[0] -eq 'status') { return [PSCustomObject]@{ExitCode=0;Output=@(' M README.md')} }
        [PSCustomObject]@{ExitCode=0;Output=@()}
    }.GetNewClosure()
    $dirtyPublicationRoot = Join-Path $testRoot 'bootstrap-dirty'
    Assert-ThrowsCategory { Publish-EwspMobileBootstrap $localRoot 'https://safe.trycloudflare.com' 'protected-test-token' $dirtyGit $permission $rawCurrent { } $dirtyPublicationRoot -LockHeld | Out-Null } 'MOBILE_BOOTSTRAP_PUBLICATION_FAILED' 'unexpected unrelated worktree changes fail bootstrap publication safely'
    Assert-Equal @($dirtyCalls | Where-Object { $_ -match '^add ' }).Count 0 'dirty publication checkout is rejected before staging anything'

    $failedPushGit = {
        param($workingDirectory, $arguments)
        if ($arguments[0] -eq 'clone') { New-Item -ItemType Directory -Path $arguments[-1] -Force | Out-Null }
        if ($arguments[0] -eq 'diff') { return [PSCustomObject]@{ExitCode=0;Output=@('public/mobile-bootstrap.json')} }
        if ($arguments[0] -eq 'push') { return [PSCustomObject]@{ExitCode=1;Output=@('remote rejected protected-test-token')} }
        [PSCustomObject]@{ExitCode=0;Output=@()}
    }
    $pushFailureRoot = Join-Path $testRoot 'bootstrap-push-failure'
    $pushFailureMessage = $null
    try { Publish-EwspMobileBootstrap $localRoot 'https://safe.trycloudflare.com' 'protected-test-token' $failedPushGit $permission $rawCurrent { } $pushFailureRoot -LockHeld | Out-Null } catch { $pushFailureMessage=$_.Exception.Message }
    Assert-Contains $pushFailureMessage 'MOBILE_BOOTSTRAP_PUBLICATION_FAILED' 'Git publication failure is classified without claiming mobile readiness'
    Assert-NotContains $pushFailureMessage 'protected-test-token' 'Git publication failure does not emit secret values'

    $publicationLock = Enter-EwspDeploymentLock
    try {
        Assert-ThrowsCategory { Publish-EwspMobileBootstrap $localRoot 'https://safe.trycloudflare.com' 'protected-test-token' $publishGit $permission $rawCurrent { } (Join-Path $testRoot 'bootstrap-locked') | Out-Null } 'DEPLOYMENT_LOCKED' 'concurrent bootstrap publication is rejected by the shared machine lock'
    } finally { Exit-EwspDeploymentLock $publicationLock }

    $managedRoot = Join-Path $testRoot 'managed-tunnel'
    New-Item -ItemType Directory -Path (Join-Path $managedRoot '.tmp\k8s') -Force | Out-Null
    $managedStatePath = Join-Path $managedRoot '.tmp\k8s\quick-tunnel.json'
    @{ ProcessId = 42; StartTimeUtcTicks = '123'; ManagedBy = 'ewsp-local-quick-tunnel'; PublicUrl = 'https://safe.trycloudflare.com' } |
        ConvertTo-Json | Set-Content -LiteralPath $managedStatePath
    $externalProcess = [PSCustomObject]@{ Id = 42; ProcessName = 'cloudflared'; StartTime = [DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) }
    $externalProvider = { param($id) $externalProcess }.GetNewClosure()
    $managedResult = Get-EwspManagedQuickTunnel $managedRoot -ProcessProvider $externalProvider
    Assert-Equal $managedResult.Active $false 'stale state cannot claim an external cloudflared process'
    $ownedTicks = [string]$externalProcess.StartTime.ToUniversalTime().Ticks
    @{ ProcessId = 42; StartTimeUtcTicks = $ownedTicks; ManagedBy = 'ewsp-local-quick-tunnel'; PublicUrl = 'https://safe.trycloudflare.com' } |
        ConvertTo-Json | Set-Content -LiteralPath $managedStatePath
    $ownedResult = Get-EwspManagedQuickTunnel $managedRoot -ProcessProvider $externalProvider
    Assert-Equal $ownedResult.Active $true 'duplicate EWSP-managed tunnel is recognized by PID and start time'
    Assert-Equal $ownedResult.PublicUrl 'https://safe.trycloudflare.com' 'duplicate EWSP-managed tunnel reuses its captured exact URL'

    $restoreCalls = New-Object System.Collections.Generic.List[string]
    $restoreRunner = {
        param($filePath, $arguments)
        $restoreCalls.Add((@($arguments) -join ' ')) | Out-Null
        [PSCustomObject]@{ ExitCode = 0; Output = @('deployment.apps/backend env updated') }
    }.GetNewClosure()
    $previousSettings = [PSCustomObject]@{
        SERVER_FORWARD_HEADERS_STRATEGY = [PSCustomObject]@{ Present = $false; Value = 'NONE' }
        SERVER_TOMCAT_REMOTEIP_INTERNAL_PROXIES = [PSCustomObject]@{ Present = $false; Value = $null }
        EWSP_CORS_ALLOWED_ORIGINS = [PSCustomObject]@{ Present = $true; Value = 'http://localhost:3000' }
    }
    Restore-EwspBackendEnvironmentOverrides $previousSettings $restoreRunner
    Assert-Contains $restoreCalls[0] 'SERVER_FORWARD_HEADERS_STRATEGY-' 'tunnel stop restoration removes temporary forwarded-header override'
    Assert-Contains $restoreCalls[0] 'EWSP_CORS_ALLOWED_ORIGINS=http://localhost:3000' 'tunnel stop restoration restores pre-run origin exactly'

    $backendReadinessStates = @(
        [PSCustomObject]@{ DeploymentReady = $false; PodReady = $false; EndpointReady = $false; Detail = 'zero Ready Pods under Recreate' },
        [PSCustomObject]@{ DeploymentReady = $false; PodReady = $false; EndpointReady = $false; Detail = 'Pod Running but not Ready' },
        [PSCustomObject]@{ DeploymentReady = $true; PodReady = $true; EndpointReady = $false; Detail = 'EndpointSlice not propagated' },
        [PSCustomObject]@{ DeploymentReady = $true; PodReady = $true; EndpointReady = $true; Detail = 'ready' }
    )
    $readinessQueue = New-Object Collections.Queue
    foreach ($state in $backendReadinessStates) { $readinessQueue.Enqueue($state) }
    $readinessCounter = @{ Value = 0 }
    $readinessProvider = {
        $readinessCounter.Value++
        if ($readinessQueue.Count -gt 1) { $readinessQueue.Dequeue() } else { $readinessQueue.Peek() }
    }.GetNewClosure()
    $readyState = Wait-EwspBackendServiceReadiness -TimeoutSeconds 2 -StateProvider $readinessProvider -SleepAction { }
    Assert-Equal $readyState.EndpointReady $true 'backend readiness tolerates Recreate zero-Pod and Running-not-Ready transitions'
    Assert-Equal $readinessCounter.Value 4 'backend readiness waits for EndpointSlice propagation after Deployment readiness'

    $healthAttempts = @{ Direct = 0; Dashboard = 0 }
    $directProbe = {
        $healthAttempts.Direct++
        [PSCustomObject]@{ Success = $healthAttempts.Direct -ge 2; StatusCode = if ($healthAttempts.Direct -ge 2) { 200 } else { 0 }; Content = if ($healthAttempts.Direct -ge 2) { '{"status":"UP"}' } else { '' } }
    }.GetNewClosure()
    $dashboardProbe = {
        $healthAttempts.Dashboard++
        [PSCustomObject]@{ Success = $healthAttempts.Dashboard -ge 3; StatusCode = if ($healthAttempts.Dashboard -ge 3) { 200 } else { 502 }; Content = if ($healthAttempts.Dashboard -ge 3) { '{"status":"UP"}' } else { '' } }
    }.GetNewClosure()
    $healthyResult = Wait-EwspBackendHealth -TimeoutSeconds 2 -DirectProbe $directProbe -DashboardProbe $dashboardProbe -SleepAction { }
    Assert-Equal $healthyResult.Dashboard.StatusCode 200 'backend health retries transient direct and dashboard failures until success'
    Assert-Equal $healthAttempts.Dashboard 3 'backend health does not classify the first transient proxy failure as invalid configuration'

    $neverReady = { [PSCustomObject]@{ DeploymentReady = $true; PodReady = $true; EndpointReady = $false; Detail = 'endpoint pending' } }
    Assert-ThrowsContains { Wait-EwspBackendServiceReadiness -TimeoutSeconds 0 -StateProvider $neverReady -SleepAction { } | Out-Null } 'BACKEND_ENDPOINT_READINESS' 'genuine EndpointSlice timeout has a precise readiness phase'
    $failedHealth = { [PSCustomObject]@{ Success = $false; StatusCode = 502; Content = '' } }
    Assert-ThrowsContains { Wait-EwspBackendHealth -TimeoutSeconds 0 -DirectProbe $failedHealth -DashboardProbe $failedHealth -SleepAction { } | Out-Null } 'BACKEND_HEALTH' 'genuine backend health timeout has a precise health phase'
    $restoreCountBeforeTimeout = $restoreCalls.Count
    try { Wait-EwspBackendHealth -TimeoutSeconds 0 -DirectProbe $failedHealth -DashboardProbe $failedHealth -SleepAction { } | Out-Null } catch {
        Restore-EwspBackendEnvironmentOverrides $previousSettings $restoreRunner
    }
    Assert-Equal $restoreCalls.Count ($restoreCountBeforeTimeout + 1) 'genuine backend health timeout executes rollback restoration'

    Assert-Equal (Assert-EwspKubernetesSeedContext 'docker-desktop') $true 'Kubernetes local seed allows only the exact Docker Desktop context'
    Assert-ThrowsCategory { Assert-EwspKubernetesSeedContext 'production-cluster' | Out-Null } 'UNSAFE_KUBERNETES_CONTEXT' 'Kubernetes local seed rejects non-docker-desktop context'

    $seedTestBackend = Join-Path $testRoot 'seed-backend'
    New-Item -ItemType Directory -Path (Join-Path $seedTestBackend 'local-dev') -Force | Out-Null
    $missingBackendLocalRoot = Join-Path $testRoot 'missing-backend-local'
    New-Item -ItemType Directory -Path (Join-Path $missingBackendLocalRoot 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $missingBackendLocalRoot 'config\repositories.psd1') -Value "@{ Repositories = @(@{ Name='ewsp-backend'; Directory='absent-backend'; ExpectedIdentity='github.com/example/absent'; CloneUrl='https://github.com/example/absent'; PrimaryBranch='main' }) }"
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $missingBackendLocalRoot | Out-Null } 'SEED_FILE_MISSING' 'Kubernetes admin seed safety rejects a missing backend sibling repository'
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner { } | Out-Null } 'SEED_FILE_MISSING' 'Kubernetes local seed rejects a missing seed file'
    $seedTestPath = Join-Path $seedTestBackend 'local-dev\seed-dashboard-users.sql'
    Set-Content -LiteralPath $seedTestPath -Value "-- local test only`nselect 1;"
    $trackedSeedGit = {
        param($repositoryPath, $arguments)
        if ($arguments[0] -eq 'ls-files') { [PSCustomObject]@{ ExitCode = 0; Output = @('local-dev/seed-dashboard-users.sql') } }
        else { [PSCustomObject]@{ ExitCode = 0; Output = @() } }
    }
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner $trackedSeedGit | Out-Null } 'SEED_FILE_TRACKED' 'Kubernetes local seed rejects a tracked seed file'
    $nonIgnoredSeedGit = {
        param($repositoryPath, $arguments)
        [PSCustomObject]@{ ExitCode = 1; Output = @() }
    }
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner $nonIgnoredSeedGit | Out-Null } 'SEED_FILE_NOT_IGNORED' 'Kubernetes local seed rejects an untracked but non-ignored seed file'
    $ignoredSeedGit = {
        param($repositoryPath, $arguments)
        if ($arguments[0] -eq 'ls-files') { [PSCustomObject]@{ ExitCode = 1; Output = @() } }
        else { [PSCustomObject]@{ ExitCode = 0; Output = @() } }
    }
    $safeSeed = Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner $ignoredSeedGit
    Assert-Equal $safeSeed.Path $seedTestPath 'Kubernetes local seed accepts the exact untracked ignored seed path'

    $seedStatefulSet = @{ spec = @{ replicas = 1 }; status = @{ readyReplicas = 1 } }
    $seedPod = @{ status = @{ phase = 'Running'; conditions = @(@{ type = 'Ready'; status = 'True' }); containerStatuses = @(@{ ready = $true }) } }
    $seedPvc = @{ metadata = @{ name = 'postgres-data-postgres-0'; uid = 'test-pvc-uid' }; status = @{ phase = 'Bound' } }
    $postgresReadyRunner = {
        param($filePath, $arguments)
        $resource = $arguments[1]
        $object = if ($resource -eq 'statefulset') { $seedStatefulSet } elseif ($resource -eq 'pod') { $seedPod } else { $seedPvc }
        [PSCustomObject]@{ ExitCode = 0; Output = @(($object | ConvertTo-Json -Depth 8 -Compress)) }
    }.GetNewClosure()
    $postgresTarget = Get-EwspKubernetesPostgresSeedTarget $postgresReadyRunner
    Assert-Equal $postgresTarget.PvcUid 'test-pvc-uid' 'Kubernetes local seed accepts Ready PostgreSQL and Bound PVC'
    $postgresMissingRunner = { param($filePath, $arguments) [PSCustomObject]@{ ExitCode = 1; Output = @('not found') } }
    Assert-ThrowsCategory { Get-EwspKubernetesPostgresSeedTarget $postgresMissingRunner | Out-Null } 'POSTGRES_NOT_READY' 'Kubernetes local seed rejects unavailable PostgreSQL'

    $seedExecutions = @{ Count = 0; Users = New-Object Collections.Generic.HashSet[string] }
    $idempotentSeedExecutor = {
        param($path)
        $seedExecutions.Count++
        foreach ($email in @('admin@ewsp.local', 'viewer@ewsp.local')) { $seedExecutions.Users.Add($email) | Out-Null }
        [PSCustomObject]@{ ExitCode = 0; Output = @() }
    }.GetNewClosure()
    Assert-Equal (Invoke-EwspKubernetesSeedSql $seedTestPath $idempotentSeedExecutor) $true 'Kubernetes local seed executes successfully'
    $usersAfterFirstSeed = $seedExecutions.Users.Count
    Invoke-EwspKubernetesSeedSql $seedTestPath $idempotentSeedExecutor | Out-Null
    Assert-Equal $seedExecutions.Users.Count $usersAfterFirstSeed 'second Kubernetes local seed run remains idempotent'
    Assert-Equal $seedExecutions.Count 2 'Kubernetes local seed explicitly executes on each command invocation'
    $failedSeedExecutor = { param($path) [PSCustomObject]@{ ExitCode = 3; Output = @('sensitive SQL withheld') } }
    Assert-ThrowsCategory { Invoke-EwspKubernetesSeedSql $seedTestPath $failedSeedExecutor | Out-Null } 'SEED_EXECUTION_FAILED' 'Kubernetes local seed classifies SQL execution failure'

    $validSeedVerification = [PSCustomObject]@{
        TotalUsers = 2; EmployeeUsers = 2; AdminEmployees = 1
        Accounts = @(
            [PSCustomObject]@{ Email = 'admin@ewsp.local'; AccountType = 'EMPLOYEE'; Role = 'ADMIN'; Status = 'ACTIVE'; Verified = $true; PasswordHashPresent = $true },
            [PSCustomObject]@{ Email = 'viewer@ewsp.local'; AccountType = 'EMPLOYEE'; Role = 'VIEWER'; Status = 'ACTIVE'; Verified = $true; PasswordHashPresent = $true }
        )
    }
    Assert-Equal (Assert-EwspKubernetesSeedVerification $validSeedVerification @('admin@ewsp.local', 'viewer@ewsp.local')) $true 'Kubernetes local seed verifies expected admin contract'
    $invalidSeedVerification = [PSCustomObject]@{ TotalUsers = 1; EmployeeUsers = 1; AdminEmployees = 0; Accounts = @([PSCustomObject]@{ Email = 'admin@ewsp.local'; AccountType = 'EMPLOYEE'; Role = 'VIEWER'; Status = 'ACTIVE'; Verified = $true; PasswordHashPresent = $true }) }
    Assert-ThrowsCategory { Assert-EwspKubernetesSeedVerification $invalidSeedVerification @('admin@ewsp.local') | Out-Null } 'SEED_VERIFICATION_FAILED' 'Kubernetes local seed rejects invalid admin verification state'

    $fakeHash = '$2a$10$' + ('A' * 53)
    $fakePassword = 'unit-' + [Guid]::NewGuid().ToString('N')
    $adminSeedText = @"
-- Dev-only password for all users: $fakePassword
WITH employee_users(id, email, phone, role_name, status, verified) AS (
  VALUES ('10000000-0000-4000-8000-000000000004'::uuid, 'admin@ewsp.local', '70000004', 'ADMIN', 'ACTIVE', TRUE)
)
INSERT INTO users (id,email,password_hash,phone,account_type,role_id,status,verified,created_at,updated_at)
SELECT employee_users.id, employee_users.email, '$fakeHash', employee_users.phone, 'EMPLOYEE', roles.id,
       employee_users.status, employee_users.verified, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM employee_users JOIN roles ON roles.name=employee_users.role_name ON CONFLICT (email) DO NOTHING;
"@
    Set-Content -LiteralPath $seedTestPath -Value $adminSeedText
    $adminContract = Resolve-EwspKubernetesAdminSeedContract $seedTestPath
    Assert-Equal $adminContract.Email 'admin@ewsp.local' 'admin reset resolves the exact seeded admin identity'
    Assert-Equal ($adminContract.PasswordHash -eq $fakeHash) $true 'admin reset safely resolves the seed-defined BCrypt hash'
    Assert-Equal ($adminContract.PlaintextPassword -eq $fakePassword) $true 'admin reset resolves the local login proof credential without output'
    Set-Content -LiteralPath $seedTestPath -Value ($adminSeedText.Replace("'$fakeHash'", "'not-a-bcrypt-hash'"))
    Assert-ThrowsCategory { Resolve-EwspKubernetesAdminSeedContract $seedTestPath | Out-Null } 'ADMIN_SEED_RESOLUTION_FAILED' 'admin reset rejects an incompatible seed credential contract'
    Set-Content -LiteralPath $seedTestPath -Value $adminSeedText

    $adminId = [Guid]'10000000-0000-4000-8000-000000000004'
    $validAdminSnapshot = [PSCustomObject]@{
        TotalUsers = 9; EmployeeUsers = 9; AdminEmployees = 1
        Accounts = @([PSCustomObject]@{ Id=$adminId; Email='admin@ewsp.local'; AccountType='EMPLOYEE'; Role='ADMIN'; Status='ACTIVE'; Verified=$true })
    }
    Assert-Equal (Assert-EwspKubernetesAdminSnapshot $validAdminSnapshot) $true 'admin reset accepts exactly one active verified ADMIN employee with 9/9/1 counts'
    $absentAdminSnapshot = [PSCustomObject]@{ TotalUsers=8; EmployeeUsers=8; AdminEmployees=0; Accounts=@() }
    Assert-ThrowsCategory { Assert-EwspKubernetesAdminSnapshot $absentAdminSnapshot | Out-Null } 'ADMIN_NOT_FOUND' 'admin reset rejects an absent admin before mutation'
    $ambiguousAdminSnapshot = [PSCustomObject]@{ TotalUsers=9; EmployeeUsers=9; AdminEmployees=1; Accounts=@($validAdminSnapshot.Accounts[0],$validAdminSnapshot.Accounts[0]) }
    Assert-ThrowsCategory { Assert-EwspKubernetesAdminSnapshot $ambiguousAdminSnapshot | Out-Null } 'ADMIN_STATE_INVALID' 'admin reset rejects ambiguous admin matches before mutation'
    $invalidRoleSnapshot = [PSCustomObject]@{ TotalUsers=9; EmployeeUsers=9; AdminEmployees=0; Accounts=@([PSCustomObject]@{ Id=$adminId; Email='admin@ewsp.local'; AccountType='EMPLOYEE'; Role='VIEWER'; Status='ACTIVE'; Verified=$true }) }
    Assert-ThrowsCategory { Assert-EwspKubernetesAdminSnapshot $invalidRoleSnapshot | Out-Null } 'ADMIN_STATE_INVALID' 'admin reset rejects an invalid admin role before mutation'

    $capturedResetSql = New-Object Collections.Generic.List[string]
    $successfulResetExecutor = {
        param($sql)
        $capturedResetSql.Add($sql) | Out-Null
        [PSCustomObject]@{ ExitCode=0; Output=@("RESULT|$adminId|9|9|1|true") }
    }.GetNewClosure()
    $resetResult = Invoke-EwspKubernetesAdminCredentialUpdate $validAdminSnapshot $fakeHash $successfulResetExecutor
    Assert-Equal $resetResult.AdminId $adminId 'admin reset preserves the admin UUID'
    Assert-Equal "$($resetResult.TotalUsers)/$($resetResult.EmployeeUsers)/$($resetResult.AdminEmployees)" '9/9/1' 'admin reset preserves user employee and admin counts'
    Assert-Contains $capturedResetSql[0] 'BEGIN;' 'admin reset uses an explicit transaction'
    Assert-Contains $capturedResetSql[0] '\set ON_ERROR_STOP on' 'admin reset SQL is executed with fail-on-error semantics'
    Assert-Contains $capturedResetSql[0] 'UPDATE users SET password_hash=' 'admin reset updates the password_hash credential field'
    foreach ($unrelatedSet in @('SET email=','SET role_id=','SET account_type=','SET status=','SET verified=','SET created_at=','SET updated_at=')) {
        Assert-NotContains $capturedResetSql[0] $unrelatedSet "admin reset does not mutate unrelated field $unrelatedSet"
    }
    $firstResetSqlCount = $capturedResetSql.Count
    $secondResetResult = Invoke-EwspKubernetesAdminCredentialUpdate $validAdminSnapshot $fakeHash $successfulResetExecutor
    Assert-Equal $capturedResetSql.Count ($firstResetSqlCount + 1) 'second admin reset executes safely and explicitly'
    Assert-Equal $secondResetResult.AdminId $adminId 'second admin reset remains UUID-idempotent'
    $failedResetExecutor = { param($sql) [PSCustomObject]@{ ExitCode=7; Output=@($sql) } }
    $failedResetText = $null
    try { Invoke-EwspKubernetesAdminCredentialUpdate $validAdminSnapshot $fakeHash $failedResetExecutor | Out-Null } catch { $failedResetText = $_.Exception.Message; $failedResetCategory = $_.Exception.Data['Category'] }
    Assert-Equal $failedResetCategory 'ADMIN_RESET_FAILED' 'admin reset classifies transactional SQL failure'
    Assert-NotContains $failedResetText $fakeHash 'admin reset failure output withholds the password hash'

    $safeLoginBody = @{ accessToken='x'; refreshToken='y'; user=@{ email='admin@ewsp.local'; accountType='EMPLOYEE'; role='ADMIN' } } | ConvertTo-Json -Depth 4 -Compress
    $loginProbe = { param($payload) [PSCustomObject]@{ StatusCode=200; Body=$safeLoginBody } }.GetNewClosure()
    $loginProofOutput = (& { $script:loginProofResult = Test-EwspKubernetesAdminLogin $fakePassword $loginProbe $loginProbe } 6>&1 | Out-String)
    Assert-Equal $script:loginProofResult.DirectStatus 200 'admin reset login proof accepts HTTP 200 from the real API contract'
    Assert-Equal $script:loginProofResult.DashboardStatus 200 'admin reset login proof accepts HTTP 200 through the dashboard proxy contract'
    Assert-NotContains $loginProofOutput $fakePassword 'admin reset login proof never prints the plaintext credential'
    Assert-NotContains $loginProofOutput 'accessToken' 'admin reset login proof never prints token response content'
    $badLoginProbe = { param($payload) [PSCustomObject]@{ StatusCode=401; Body='{}' } }
    Assert-ThrowsCategory { Test-EwspKubernetesAdminLogin $fakePassword $badLoginProbe $loginProbe | Out-Null } 'ADMIN_RESET_VERIFICATION_FAILED' 'admin reset rejects unsuccessful real login proof'

    $machineProfile = Join-Path $testRoot 'machine-profile'
    $machinePaths = Get-EwspDeploymentMachinePaths $machineProfile
    Assert-Equal $machinePaths.Configuration (Join-Path $machineProfile '.ewsp\deployment.env') 'CD config path is user-profile relative and outside a checkout'
    Assert-Equal $machinePaths.State (Join-Path $machineProfile '.ewsp\deployment-state.json') 'dynamic deployment state is separate from static configuration'
    Assert-Equal $machinePaths.Lock (Join-Path $machineProfile '.ewsp\deployment.lock') 'GitHub and startup reconciliation share one machine lock path'
    Assert-ThrowsCategory { Get-EwspDeploymentConfiguration -UserProfile $machineProfile -SkipAcl | Out-Null } 'DEPLOYMENT_CONFIG_MISSING' 'missing machine deployment config fails by setting name'
    New-Item -ItemType Directory -Path $machinePaths.Root -Force | Out-Null
    @('EWSP_GITHUB_READ_TOKEN=read-token-test','GHCR_USERNAME=test-user','GHCR_TOKEN=ghcr-token-test','EWSP_ADMIN_PASSWORD=admin-password-test','EWSP_MAIL_ENABLED=true','EWSP_MAIL_HOST=smtp.example.com','EWSP_MAIL_PORT=587','EWSP_MAIL_USERNAME=mailer@example.com','EWSP_MAIL_PASSWORD=smtp-password-test','EWSP_MAIL_FROM=mailer@example.com','EWSP_MAIL_SMTP_AUTH=true','EWSP_MAIL_STARTTLS_ENABLE=true') | Set-Content -LiteralPath $machinePaths.Configuration
    $machineConfiguration = Get-EwspDeploymentConfiguration -UserProfile $machineProfile -RequireGhcr -RequireAdminLogin -RequireMail -SkipAcl
    Assert-Equal $machineConfiguration.AdminEmail 'admin@ewsp.local' 'CD login uses the fixed verified local admin identity by default'
    Assert-Equal $machineConfiguration.DashboardPort 3000 'CD dashboard smoke checks use the safe default port'
    Assert-Equal $machineConfiguration.MailValues.EWSP_MAIL_HOST 'smtp.example.com' 'protected SMTP host is available to Secret reconciliation'
    Assert-Equal $machineConfiguration.MailValues.EWSP_MAIL_PORT '587' 'protected SMTP port is available to Secret reconciliation'
    $configOutput = (& { Get-EwspDeploymentConfiguration -UserProfile $machineProfile -RequireGhcr -RequireAdminLogin -RequireMail -SkipAcl | Out-Null } 6>&1 | Out-String)
    Assert-NotContains $configOutput 'read-token-test' 'machine config validation never prints GitHub read token'
    Assert-NotContains $configOutput 'ghcr-token-test' 'machine config validation never prints GHCR token'
    Assert-NotContains $configOutput 'admin-password-test' 'machine config validation never prints admin password'
    Assert-NotContains $configOutput 'smtp-password-test' 'machine config validation never prints SMTP password'
    $invalidMailConfiguration = Get-Content -LiteralPath $machinePaths.Configuration | Where-Object { $_ -notmatch '^EWSP_MAIL_STARTTLS_ENABLE=' }
    $invalidMailConfiguration += 'EWSP_MAIL_STARTTLS_ENABLE=false'
    $invalidMailConfiguration | Set-Content -LiteralPath $machinePaths.Configuration
    Assert-ThrowsCategory { Get-EwspDeploymentConfiguration -UserProfile $machineProfile -RequireMail -SkipAcl | Out-Null } 'DEPLOYMENT_CONFIG_INVALID' 'deployed SMTP configuration refuses disabled STARTTLS'

    $backendApprovedSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $dashboardApprovedSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $discoveryInvoker = {
        param($uri,$token)
        if ($token -ne 'read-token-test') { throw 'unexpected token' }
        $sha = if ($uri -match 'ewsp-backend') { $backendApprovedSha } else { $dashboardApprovedSha }
        [PSCustomObject]@{ workflow_runs=@(
            [PSCustomObject]@{ id=91; run_number=91; event='pull_request'; head_branch='main'; status='completed'; conclusion='success'; head_sha=('c' * 40); html_url='pr' },
            [PSCustomObject]@{ id=92; run_number=92; event='push'; head_branch='main'; status='completed'; conclusion='failure'; head_sha=('d' * 40); html_url='failed' },
            [PSCustomObject]@{ id=93; run_number=93; event='push'; head_branch='main'; status='completed'; conclusion='success'; head_sha=$sha; html_url='approved' },
            [PSCustomObject]@{ id=90; run_number=90; event='push'; head_branch='main'; status='completed'; conclusion='success'; head_sha=('e' * 40); html_url='stale' }
        ) }
    }.GetNewClosure()
    $desiredArtifacts = @(Get-EwspDesiredArtifacts 'read-token-test' $discoveryInvoker)
    Assert-Equal $desiredArtifacts.Count 2 'desired discovery returns exactly backend and dashboard'
    Assert-Equal @($desiredArtifacts | Where-Object Service -eq 'backend')[0].GitSha $backendApprovedSha 'backend discovery selects newest successful push/main CI SHA'
    Assert-Equal @($desiredArtifacts | Where-Object Service -eq 'dashboard')[0].GitSha $dashboardApprovedSha 'dashboard discovery selects newest successful push/main CI SHA'
    Assert-Contains @($desiredArtifacts | Where-Object Service -eq 'backend')[0].Image ":$backendApprovedSha" 'desired backend image uses the full immutable SHA tag'
    Assert-Equal (@($desiredArtifacts | Where-Object WorkflowRunId -eq 92).Count) 0 'failed CI is never deployment eligible'
    Assert-Equal (@($desiredArtifacts | Where-Object WorkflowRunId -eq 91).Count) 0 'PR CI is never deployment eligible'
    $noApprovedInvoker = { param($uri,$token) [PSCustomObject]@{ workflow_runs=@([PSCustomObject]@{ id=1;run_number=1;event='push';head_branch='main';status='completed';conclusion='failure';head_sha=('f' * 40) }) } }
    Assert-ThrowsCategory { Get-EwspDesiredArtifacts 'read-token-test' $noApprovedInvoker | Out-Null } 'NO_APPROVED_ARTIFACT' 'absence of successful artifact-producing CI fails closed'
    $badShaInvoker = { param($uri,$token) [PSCustomObject]@{ workflow_runs=@([PSCustomObject]@{ id=1;run_number=1;event='push';head_branch='main';status='completed';conclusion='success';head_sha='main' }) } }
    Assert-ThrowsCategory { Get-EwspDesiredArtifacts 'read-token-test' $badShaInvoker | Out-Null } 'NO_APPROVED_ARTIFACT' 'successful run with invalid SHA is rejected'
    $githubUnavailableInvoker = { param($uri,$token) throw 'simulated private GitHub API outage' }
    Assert-ThrowsCategory { Get-EwspDesiredArtifacts 'read-token-test' $githubUnavailableInvoker | Out-Null } 'GITHUB_API_UNAVAILABLE' 'private GitHub API outage is classified without exposing its response'

    $ghcrUnauthorizedInvoker = {
        param($mode,$uri,$username,$token,$accept)
        $failure = [Exception]::new('simulated registry response content')
        $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{StatusCode=401})
        throw $failure
    }
    Assert-ThrowsCategory { Get-EwspGhcrBearerToken 'ewsp-backend' 'u' 't' $ghcrUnauthorizedInvoker | Out-Null } 'GHCR_AUTH_FAILED' 'GHCR authentication failure is classified without exposing registry content'
    $ghcrMissingInvoker = {
        param($mode,$uri,$username,$token,$accept)
        $failure = [Exception]::new('simulated registry response content')
        $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{StatusCode=404})
        throw $failure
    }
    Assert-ThrowsCategory { Get-EwspGhcrManifestResponse 'ewsp-backend' $backendApprovedSha 'bearer-test' $ghcrMissingInvoker | Out-Null } 'GHCR_IMAGE_MISSING' 'nonexistent immutable GHCR tag fails closed without exposing registry content'

    $tagDigest = 'sha256:' + ('1' * 64)
    $runtimeDigest = 'sha256:' + ('2' * 64)
    $manifestInvoker = {
        param($mode,$uri,$username,$token,$accept)
        if ($mode -eq 'TOKEN') { return [PSCustomObject]@{ token='registry-bearer-test' } }
        [PSCustomObject]@{
            StatusCode=200; Headers=@{ 'Docker-Content-Digest'=$tagDigest }
            Content=(@{ mediaType='application/vnd.oci.image.index.v1+json'; manifests=@(
                @{ digest=('sha256:' + ('3' * 64)); platform=@{os='unknown';architecture='unknown'} },
                @{ digest=$runtimeDigest; platform=@{os='linux';architecture='amd64'} }
            ) } | ConvertTo-Json -Depth 6 -Compress)
        }
    }.GetNewClosure()
    $resolvedArtifact = Resolve-EwspGhcrArtifactDigest @($desiredArtifacts | Where-Object Service -eq 'backend')[0] 'user-test' 'token-test' $manifestInvoker
    Assert-Equal $resolvedArtifact.TagDigest $tagDigest 'GHCR discovery records immutable tag/index digest'
    Assert-Equal $resolvedArtifact.RuntimeDigest $runtimeDigest 'GHCR discovery selects linux/amd64 runtime digest for Pod verification'
    $badDigestInvoker = { param($mode,$uri,$username,$token,$accept) if($mode -eq 'TOKEN'){[PSCustomObject]@{token='x'}}else{[PSCustomObject]@{Headers=@{'Docker-Content-Digest'='latest'};Content='{}'}} }
    Assert-ThrowsCategory { Resolve-EwspGhcrArtifactDigest @($desiredArtifacts | Where-Object Service -eq 'backend')[0] 'u' 't' $badDigestInvoker | Out-Null } 'GHCR_DIGEST_INVALID' 'invalid GHCR digest is rejected'
    $wrongImageArtifact = [PSCustomObject]@{Service='backend';GitSha=$backendApprovedSha;Image='ghcr.io/mohammad-hamadi/ewsp-backend:latest'}
    Assert-ThrowsCategory { Resolve-EwspGhcrArtifactDigest $wrongImageArtifact 'u' 't' $manifestInvoker | Out-Null } 'GHCR_IMAGE_INVALID' 'moving GHCR tag is never accepted as desired state'

    $desiredByService = @{}
    foreach($artifact in $desiredArtifacts){$desiredByService[$artifact.Service]=$artifact.Image}
    $currentSnapshots = @(
        [PSCustomObject]@{Name='backend';Image=$desiredByService.backend;Ready=$true},
        [PSCustomObject]@{Name='dashboard';Image=$desiredByService.dashboard;Ready=$true}
    )
    Assert-Equal @(Get-EwspDeploymentChangePlan $desiredArtifacts $desiredByService $currentSnapshots).Count 0 'no-op plan changes no application when configured and running refs are current'
    $backendOld = $desiredByService.Clone(); $backendOld.backend="ghcr.io/mohammad-hamadi/ewsp-backend:$('1' * 40)"
    $backendOnly = @(Get-EwspDeploymentChangePlan $desiredArtifacts $backendOld $currentSnapshots)
    Assert-Equal $backendOnly.Count 1 'backend-only plan changes exactly one component'
    Assert-Equal $backendOnly[0].Service 'backend' 'backend-only plan leaves dashboard untouched'
    $dashboardOld = $desiredByService.Clone(); $dashboardOld.dashboard="ghcr.io/mohammad-hamadi/ewsp-dashboard:$('2' * 40)"
    $dashboardOnly = @(Get-EwspDeploymentChangePlan $desiredArtifacts $dashboardOld $currentSnapshots)
    Assert-Equal $dashboardOnly.Count 1 'dashboard-only plan changes exactly one component'
    Assert-Equal $dashboardOnly[0].Service 'dashboard' 'dashboard-only plan leaves backend untouched'
    $bothOld = $backendOld.Clone(); $bothOld.dashboard=$dashboardOld.dashboard
    Assert-Equal @(Get-EwspDeploymentChangePlan $desiredArtifacts $bothOld $currentSnapshots).Count 2 'both-component plan reconciles both applications deterministically'
    $stalePodSnapshots = @([PSCustomObject]@{Name='backend';Image=$backendOld.backend;Ready=$true},$currentSnapshots[1])
    Assert-Equal @(Get-EwspDeploymentChangePlan $desiredArtifacts $desiredByService $stalePodSnapshots).Count 1 'stale running Pod is not misclassified as no-op when Deployment spec is current'
    $oldBackendImage="ghcr.io/mohammad-hamadi/ewsp-backend:$('3' * 40)"
    $oldDashboardImage="ghcr.io/mohammad-hamadi/ewsp-dashboard:$('4' * 40)"
    Assert-Equal (Resolve-EwspRollbackAction dashboard $oldDashboardImage $null $null) 'RESTORE_PREVIOUS_IMAGE' 'dashboard failure restores previous immutable image'
    Assert-Equal (Resolve-EwspRollbackAction backend $oldBackendImage ([PSCustomObject]@{Fingerprint='same'}) ([PSCustomObject]@{Fingerprint='same'})) 'RESTORE_PREVIOUS_IMAGE' 'backend failure restores code only when Flyway history is unchanged'
    Assert-Equal (Resolve-EwspRollbackAction backend $oldBackendImage ([PSCustomObject]@{Fingerprint='before'}) ([PSCustomObject]@{Fingerprint='after'})) 'UNSAFE_DATABASE_ADVANCED' 'backend rollback stops when Flyway history advances'
    Assert-Equal (Resolve-EwspRollbackAction backend 'backend:latest' $null $null) 'UNAVAILABLE' 'rollback never restores a non-immutable previous image'

    $firstLock = Enter-EwspDeploymentLock $machineProfile
    Assert-Equal $firstLock.Acquired $true 'first deployment reconciliation acquires the machine lock'
    Assert-ThrowsCategory { Enter-EwspDeploymentLock $machineProfile | Out-Null } 'DEPLOYMENT_LOCKED' 'concurrent local deployment is cleanly rejected'
    Exit-EwspDeploymentLock $firstLock
    Assert-Equal (Test-EwspDeploymentLock $machineProfile) $false 'deployment lock becomes available after reconciliation exits'
    $stateObject = [PSCustomObject]@{Status='ALREADY_CURRENT';DesiredBackendSha=$backendApprovedSha;DesiredDashboardSha=$dashboardApprovedSha;Trigger='test'}
    Write-EwspDeploymentState $stateObject $machineProfile | Out-Null
    Assert-Equal (Read-EwspDeploymentState $machineProfile).Status 'ALREADY_CURRENT' 'non-secret deployment state survives process restart'
    $imageConfigurationRoot = Join-Path $testRoot 'image-configuration'
    New-Item -ItemType Directory -Path $imageConfigurationRoot -Force | Out-Null
    $staleBackendSha = '1' * 40
    $staleDashboardSha = '2' * 40
    Set-Content -LiteralPath (Join-Path $imageConfigurationRoot '.env') -Value @(
        "EWSP_BACKEND_IMAGE=ghcr.io/mohammad-hamadi/ewsp-backend:$staleBackendSha",
        "EWSP_DASHBOARD_IMAGE=ghcr.io/mohammad-hamadi/ewsp-dashboard:$staleDashboardSha",
        'GHCR_USERNAME=test-user',
        'GHCR_TOKEN=opaque-test-token'
    )
    $successfulState = [PSCustomObject]@{
        Status='RECONCILIATION_SUCCEEDED'
        DesiredBackendSha=$backendApprovedSha; DeployedBackendSha=$backendApprovedSha
        DesiredDashboardSha=$dashboardApprovedSha; DeployedDashboardSha=$dashboardApprovedSha
    }
    Write-EwspDeploymentState $successfulState $machineProfile | Out-Null
    $resolvedImages = Resolve-EwspKubernetesImageConfiguration $imageConfigurationRoot $machineProfile
    Assert-Equal $resolvedImages.ImageSource 'last successful automatic deployment' 'successful automatic deployment state is the Kubernetes image authority'
    Assert-Equal $resolvedImages.EnvironmentValues.EWSP_BACKEND_IMAGE "ghcr.io/mohammad-hamadi/ewsp-backend:$backendApprovedSha" 'stale checkout backend ref cannot downgrade an automatically deployed image'
    Assert-Equal $resolvedImages.EnvironmentValues.EWSP_DASHBOARD_IMAGE "ghcr.io/mohammad-hamadi/ewsp-dashboard:$dashboardApprovedSha" 'successful deployment state resolves both application images atomically'
    Assert-Equal $resolvedImages.EnvironmentValues.GHCR_TOKEN 'opaque-test-token' 'image authority change preserves protected local credential sourcing'
    $incompleteState = [PSCustomObject]@{
        Status='RECONCILIATION_SUCCEEDED'
        DesiredBackendSha=$backendApprovedSha; DeployedBackendSha=$staleBackendSha
        DesiredDashboardSha=$dashboardApprovedSha; DeployedDashboardSha=$dashboardApprovedSha
    }
    Write-EwspDeploymentState $incompleteState $machineProfile | Out-Null
    $fallbackImages = Resolve-EwspKubernetesImageConfiguration $imageConfigurationRoot $machineProfile
    Assert-Equal $fallbackImages.ImageSource 'local environment' 'incomplete or divergent deployment state is never trusted as image authority'
    Assert-Equal $fallbackImages.EnvironmentValues.EWSP_BACKEND_IMAGE "ghcr.io/mohammad-hamadi/ewsp-backend:$staleBackendSha" 'invalid deployment state falls back to validated local immutable refs'
    Set-Content -LiteralPath $machinePaths.State -Value '{broken'
    $malformedStateOutput = (& { $script:malformedState = Read-EwspDeploymentState $machineProfile } 3>&1 | Out-String)
    Assert-Equal $script:malformedState $null 'malformed deployment state is ignored because it is not authoritative'
    Assert-Contains $malformedStateOutput 'malformed' 'malformed deployment state reports recoverable diagnostics'
    Remove-Item -LiteralPath $machinePaths.State -Force
    Assert-Equal (Read-EwspDeploymentState $machineProfile) $null 'deleted deployment state recovers as absent without affecting desired discovery'

    $setImageCalls = New-Object Collections.Generic.List[string]
    $setImageRunner = { param($file,$arguments) $setImageCalls.Add(($arguments -join ' ')); [PSCustomObject]@{ ExitCode=0; Output=@('deployment.apps/backend image updated') } }.GetNewClosure()
    Set-EwspDeploymentImage backend "ghcr.io/mohammad-hamadi/ewsp-backend:$backendApprovedSha" $setImageRunner | Out-Null
    Assert-Contains $setImageCalls[0] "set image deployment/backend backend=ghcr.io/mohammad-hamadi/ewsp-backend:$backendApprovedSha" 'backend-only deployment targets only backend Deployment'
    Assert-ThrowsCategory { Set-EwspDeploymentImage dashboard 'ghcr.io/mohammad-hamadi/ewsp-dashboard:main' $setImageRunner | Out-Null } 'GHCR_IMAGE_INVALID' 'component deployment rejects moving tags before kubectl mutation'

    $deployWorkflow = Get-Content -Raw (Join-Path $localRoot '.github\workflows\deploy.yml')
    Assert-Contains $deployWorkflow 'runs-on: [self-hosted, Windows, X64]' 'CD workflow mutates Kubernetes only on the proven Windows runner'
    Assert-Contains $deployWorkflow 'group: ewsp-docker-desktop-kubernetes' 'CD workflow declares one environment concurrency group'
    Assert-Contains $deployWorkflow 'cancel-in-progress: false' 'active deployment is never cancelled mid-mutation'
    Assert-Contains $deployWorkflow '.\ewsp.ps1 deploy' 'every CD event performs current desired-state reconciliation'
    Assert-Contains $deployWorkflow 'persist-credentials: false' 'CD checkout does not persist GitHub credentials'
    Assert-NotContains $deployWorkflow 'EWSP_BACKEND_IMAGE' 'stale triggering SHA is not passed as deployment source of truth'
    $startupScriptText = Get-Content -Raw (Join-Path $localRoot 'scripts\Invoke-EwspStartupReconciliation.ps1')
    Assert-Contains $startupScriptText '$delays = @(0, 15, 30, 60, 120, 180)' 'startup reconciliation uses bounded backoff'
    Assert-NotContains $startupScriptText 'while ($true)' 'startup reconciliation has no infinite busy loop'
    Assert-Contains $startupScriptText 'EWSP_DEPLOY_RESULT=DEPLOYMENT_DEFERRED' 'startup reconciliation distinguishes transient host unavailability'
    Assert-Contains $startupScriptText '& powershell.exe -NoProfile -File $entryPoint deploy' 'startup reconciliation invokes authoritative desired-state discovery instead of replaying an event SHA'
    $missedEventPlan = @(Get-EwspDeploymentChangePlan $desiredArtifacts $bothOld @(
        [PSCustomObject]@{Name='backend';Image=$bothOld.backend;Ready=$true},
        [PSCustomObject]@{Name='dashboard';Image=$bothOld.dashboard;Ready=$true}
    ))
    Assert-Equal $missedEventPlan.Count 2 'long-offline recovery discovers and reconciles both newer approved artifacts without a queued event'
    Assert-Equal (($missedEventPlan | ForEach-Object Service) -join ',') 'backend,dashboard' 'long-offline recovery remains deterministic and component-specific'

    $cdModuleText = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
    Assert-Contains $cdModuleText "New-ScheduledTaskPrincipal -UserId `$identity -LogonType Interactive -RunLevel Limited" 'runner tasks use the current interactive Docker Desktop user without a stored password'
    Assert-Contains $cdModuleText "New-ScheduledTaskTrigger -AtLogOn -User `$identity" 'runner and reconciliation tasks trigger at logon for the detected user'
    Assert-Contains $cdModuleText '-MultipleInstances IgnoreNew' 'scheduled startup cannot create duplicate runner or reconciliation instances'
    Assert-Contains $cdModuleText "-RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)" 'runner task restarts a failed runner with bounded Task Scheduler policy'
    Assert-Contains $cdModuleText "-RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5)" 'startup reconciliation has bounded Task Scheduler retries'
    Assert-Contains $cdModuleText "Join-Path `$RunnerRoot '.service'" 'stale runner service metadata is detected without recreating the deleted service wrapper'
    Assert-NotContains $cdModuleText 'Register-ScheduledTask.*-Password' 'runner setup never persists a Windows password'
    Assert-Contains $cdModuleText 'RESTORED_PREVIOUS_IMAGE_AND_VERIFIED' 'automatic code rollback is not reported restored until application verification passes'
    Assert-Contains $cdModuleText "Test-EwspKubernetesAdminLogin `$configuration.AdminPassword" 'automatic rollback verification includes authenticated admin login'
    Assert-Contains $cdModuleText "foreach (`$name in @('DeployedBackendSha','DeployedDashboardSha','BackendRunningDigest','DashboardRunningDigest','PvcUids'))" 'a failed attempt preserves the previous successful non-secret deployment record'
    foreach($application in @('ewsp-backend','ewsp-dashboard')){
        $ciText = Get-Content -Raw (Join-Path (Split-Path $localRoot -Parent) "$application\.github\workflows\ci.yml")
        Assert-Contains $ciText 'EWSP_LOCAL_DEPLOY_TRIGGER_TOKEN' "$application uses the dedicated cross-repository trigger token"
        Assert-Contains $ciText 'continue-on-error: true' "$application deployment signal is best-effort"
        Assert-Contains $ciText "workflow_id: 'deploy.yml'" "$application signals only the ewsp-local deploy workflow"
        Assert-NotContains $ciText 'kubectl' "$application never mutates the user Kubernetes cluster"
    }

    $commandRegistry = @(Get-EwspCommandRegistry)
    $canonicalNames = @($commandRegistry | ForEach-Object Name)
    Assert-Equal $canonicalNames.Count 20 'help registry contains every canonical public command including CD host operations'
    Assert-Equal @($canonicalNames | Sort-Object -Unique).Count $canonicalNames.Count 'help registry has no duplicate canonical commands'
    Assert-Equal ($canonicalNames -contains 'k8s-reset-admin') $true 'help registry exposes k8s-reset-admin'
    foreach($cdCommand in @('deploy-configure','deploy','deploy-status','runner-setup','runner-status')) { Assert-Equal ($canonicalNames -contains $cdCommand) $true "help registry exposes $cdCommand" }
    foreach ($commandMetadata in $commandRegistry) {
        Assert-Equal ([string]::IsNullOrWhiteSpace($commandMetadata.ShortDescription)) $false "help metadata describes $($commandMetadata.Name)"
        Assert-Equal ([string]::IsNullOrWhiteSpace($commandMetadata.Usage)) $false "help metadata provides usage for $($commandMetadata.Name)"
        if ($commandMetadata.Name -ne 'help') {
            $handlerExists = & $module { param($handler) [bool](Get-Command $handler -CommandType Function -ErrorAction SilentlyContinue) } $commandMetadata.Handler
            Assert-Equal $handlerExists $true "documented command $($commandMetadata.Name) resolves to a real handler"
        }
        $commandHelpOutput = (& { Invoke-EwspCommand -Command $commandMetadata.Name -Arguments @('--help') -LocalRoot (Join-Path $testRoot 'missing-runtime') } 6>&1 | Out-String)
        Assert-Contains $commandHelpOutput $commandMetadata.Usage "--help documents $($commandMetadata.Name) without executing it"
        $shortHelpOutput = (& { Invoke-EwspCommand -Command $commandMetadata.Name -Arguments @('-h') -LocalRoot (Join-Path $testRoot 'missing-runtime') } 6>&1 | Out-String)
        Assert-Contains $shortHelpOutput $commandMetadata.Usage "-h documents $($commandMetadata.Name) without executing it"
    }

    $topHelpOutput = (& { Invoke-EwspCommand -Command help -LocalRoot (Join-Path $testRoot 'no-env-or-runtime') } 6>&1 | Out-String)
    Assert-Contains $topHelpOutput 'EWSP Local' 'top-level help works without .env or runtime prerequisites'
    Assert-Contains $topHelpOutput '.\ewsp.ps1 help commands' 'top-level help explains command discovery'
    $topLongAliasOutput = (& { Invoke-EwspCommand -Command '--help' -LocalRoot $testRoot } 6>&1 | Out-String)
    Assert-Contains $topLongAliasOutput 'EWSP Local' 'top-level --help alias works'
    $topShortAliasOutput = (& { Invoke-EwspCommand -Command '-h' -LocalRoot $testRoot } 6>&1 | Out-String)
    Assert-Contains $topShortAliasOutput 'EWSP Local' 'top-level -h alias works'
    $catalogOutput = (& { Invoke-EwspCommand -Command help -Arguments @('commands') -LocalRoot $testRoot } 6>&1 | Out-String)
    foreach ($canonicalName in $canonicalNames) { Assert-Contains $catalogOutput $canonicalName "help commands catalogs $canonicalName" }

    $categories = @(Get-EwspHelpCategories)
    $allAliases = New-Object Collections.Generic.List[string]
    foreach ($commandMetadata in $commandRegistry) { foreach ($alias in @($commandMetadata.Aliases)) { $allAliases.Add($alias) } }
    Assert-Equal @($allAliases | Sort-Object -Unique).Count $allAliases.Count 'help command aliases are unique'
    foreach ($category in $categories) {
        foreach ($referencedCommand in $category.Commands) {
            Assert-Equal ($canonicalNames -contains $referencedCommand) $true "help category $($category.Id) references real command $referencedCommand"
        }
        foreach ($synonym in $category.Synonyms) {
            $categoryOutput = (& { Invoke-EwspCommand -Command help -Arguments @($synonym) -LocalRoot $testRoot } 6>&1 | Out-String)
            Assert-Contains $categoryOutput $category.Name.ToUpperInvariant() "help category synonym $synonym resolves"
        }
    }
    $searchOutput = (& { Invoke-EwspCommand -Command help -Arguments @('find','password') -LocalRoot $testRoot } 6>&1 | Out-String)
    Assert-Contains $searchOutput 'k8s-reset-admin' 'help find searches credential-related keywords'
    $noSearchOutput = (& { Invoke-EwspCommand -Command help -Arguments @('find','no-such-help-topic-xyz') -LocalRoot $testRoot } 6>&1 | Out-String)
    Assert-Contains $noSearchOutput '.\ewsp.ps1 help commands' 'help find no-result points to the command catalog'

    $workflows = @(Get-EwspHelpWorkflows)
    Assert-Equal ($workflows.Name -contains 'local') $true 'workflow help includes local development'
    Assert-Equal ($workflows.Name -contains 'kubernetes') $true 'workflow help includes Kubernetes deployment'
    Assert-Equal ($workflows.Name -contains 'public-demo') $true 'workflow help includes public demo'
    Assert-Equal ($workflows.Name -contains 'ghcr') $true 'workflow help includes private GHCR deployment'
    foreach ($workflow in $workflows) {
        foreach ($referencedCommand in $workflow.Commands) {
            Assert-Equal ($canonicalNames -contains $referencedCommand) $true "workflow $($workflow.Name) references real command $referencedCommand"
        }
        $workflowOutput = (& { Invoke-EwspCommand -Command help -Arguments @('workflow',$workflow.Name) -LocalRoot $testRoot } 6>&1 | Out-String)
        Assert-Contains $workflowOutput $workflow.Title "workflow help renders $($workflow.Name)"
    }
    Assert-Equal @(Get-EwspCommandSuggestions 'k8-up')[0] 'k8s-up' 'unknown k8-up suggests k8s-up deterministically'
    Assert-Equal @(Get-EwspCommandSuggestions 'tunel-quick')[0] 'tunnel-quick' 'unknown tunel-quick suggests tunnel-quick deterministically'
    Assert-Equal @(Get-EwspCommandSuggestions 'k8s-stats')[0] 'k8s-status' 'unknown k8s-stats suggests k8s-status deterministically'
    Assert-ThrowsContains { Invoke-EwspCommand -Command 'tunel-quick' -LocalRoot $testRoot } 'Did you mean:' 'unknown command returns useful suggestions'

    $wrapperPath = Join-Path $localRoot 'ewsp.ps1'
    $wrapperHelpOutput = @(& powershell.exe -NoProfile -File $wrapperPath --help 2>&1) -join "`n"
    $wrapperHelpExit = $LASTEXITCODE
    Assert-Equal $wrapperHelpExit 0 'ewsp.ps1 --help exits successfully without prerequisites'
    Assert-Contains $wrapperHelpOutput 'EWSP Local' 'ewsp.ps1 --help renders top-level help'
    $wrapperCommandHelpOutput = @(& powershell.exe -NoProfile -File $wrapperPath k8s-up -h 2>&1) -join "`n"
    $wrapperCommandHelpExit = $LASTEXITCODE
    Assert-Equal $wrapperCommandHelpExit 0 'ewsp.ps1 command -h exits successfully without executing the command'
    Assert-Contains $wrapperCommandHelpOutput '.\ewsp.ps1 k8s-up' 'ewsp.ps1 command -h renders command help'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wrapperUnknownOutput = @(& powershell.exe -NoProfile -File $wrapperPath tunel-quick 2>&1) -join "`n"
        $wrapperUnknownExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    Assert-Equal ($wrapperUnknownExit -ne 0) $true 'actual unknown command returns a non-zero exit code'
    Assert-Contains $wrapperUnknownOutput 'tunnel-quick' 'actual unknown command prints deterministic suggestion'

    $stoppedRunner = {
        param($filePath, $arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @('{"items":[]}') }
    }
    Assert-Equal (Wait-EwspKubernetesPodsStopped -TimeoutSeconds 2 -CommandRunner $stoppedRunner -SleepAction { }) $true 'Kubernetes stop confirms controller-managed Pods disappeared'

    $kubeCause = New-EwspKubernetesException 'image pull failed without secret value test-jwt-private' 'KUBERNETES_READINESS_FAILURE' 'backend' 'kubectl rollout status deployment/backend'
    $kubeCompleted = New-Object System.Collections.Generic.List[string]
    $kubeCompleted.Add('K8S_ENVIRONMENT')
    $kubeFailure = New-EwspUpFailureException 'READINESS_WAIT' 'Waiting for Kubernetes readiness' $kubeCause $healthyKube $kubeCompleted @('FINAL_VERIFICATION', 'ACCESS_SETUP') 'rollout backend' 'backend' 'k8s-up'
    Assert-Contains $kubeFailure.Message 'EWSP k8s-up failed' 'Kubernetes failure uses structured workflow diagnostics'
    Assert-Contains $kubeFailure.Message 'Category: KUBERNETES_READINESS_FAILURE' 'Kubernetes failure preserves category'
    Assert-Contains $kubeFailure.Message 'Not attempted afterward: FINAL_VERIFICATION, ACCESS_SETUP' 'Kubernetes failure lists skipped phases'
    Assert-NotContains (Protect-EwspDiagnosticText $kubeFailure.Message $testSecretValues) 'test-jwt-private' 'Kubernetes diagnostics redact secret values'
    Assert-NotContains (Protect-EwspDiagnosticText 'failed opaque-ghcr-token' $ghcrValues) 'opaque-ghcr-token' 'Kubernetes diagnostics redact GHCR token values'

    Remove-EwspKubernetesSecretArtifact $localRoot
    Remove-EwspGhcrPullSecretArtifact $localRoot
    Remove-EwspCloudflareTunnelSecretArtifact $localRoot

    $moduleText = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
    foreach ($destructiveGitOperation in @("@('reset'", "@('clean'", "@('stash'", "@('checkout'", "@('rebase'")) {
        Assert-NotContains $moduleText $destructiveGitOperation "orchestration does not introduce destructive Git operation $destructiveGitOperation"
    }
    Assert-NotContains $moduleText "@('delete', 'namespace'" 'Kubernetes orchestration does not delete its namespace'
    Assert-NotContains $moduleText "@('delete', 'pvc'" 'Kubernetes orchestration does not delete PVCs'
    Assert-Contains $moduleText "Name='k8s-up'; Category='kubernetes'; Handler='Invoke-EwspKubernetesUp'" 'central command registry routes k8s-up'
    Assert-Contains $moduleText "Name='k8s-reset-admin'; Category='data'; Handler='Invoke-EwspKubernetesResetAdmin'" 'central command registry routes k8s-reset-admin'
    Assert-Contains $moduleText '& $metadata[0].Handler $LocalRoot' 'command dispatcher executes handlers from central metadata'
    Assert-NotContains $moduleText '10\.244\.0\.24|127' 'Quick Tunnel implementation does not hardcode the example Pod IP'
    Assert-NotContains $moduleText '*.trycloudflare.com' 'Quick Tunnel implementation never configures wildcard trycloudflare origin'
    Assert-NotContains $moduleText "Stop-Process -Name cloudflared" 'Quick Tunnel never kills arbitrary cloudflared processes by name'
    Assert-NotContains $moduleText "@('delete', 'pvc'" 'Quick Tunnel lifecycle leaves Kubernetes PVCs untouched'
    Assert-Contains $moduleText 'Wait-EwspBackendServiceReadiness' 'Quick Tunnel synchronizes on Kubernetes backend readiness state'
    Assert-Contains $moduleText 'kubernetes.io/service-name=backend' 'Quick Tunnel synchronizes on the backend EndpointSlice'
    Assert-Contains $moduleText '/api/v1/namespaces/ewsp/services/http:backend:8080/proxy/api/health' 'Quick Tunnel verifies direct backend Service health'
    Assert-NotContains $moduleText "Backend health failed after trusted-proxy configuration." 'one-shot post-rollout health classification is removed'
    $k8sUpFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspKubernetesUp \{.*?(?=function Invoke-EwspStop \{)').Value
    $deployFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspDeploy \{.*?(?=function Get-EwspRunnerRegistration \{)').Value
    $tunnelStartFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspQuickTunnelStart \{.*?(?=function Invoke-EwspQuickTunnelStatus \{)').Value
    $tunnelStopFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspQuickTunnelStop \{.*?(?=function Invoke-EwspQuickTunnelStart \{)').Value
    Assert-NotContains $k8sUpFunction 'Invoke-EwspKubernetesSeed' 'k8s-up never invokes local user seeding automatically'
    Assert-NotContains $tunnelStartFunction 'Invoke-EwspKubernetesSeed' 'tunnel-quick never invokes local user seeding automatically'
    Assert-Contains $tunnelStartFunction 'Publish-EwspMobileBootstrap' 'tunnel-quick publishes bootstrap only within the verified tunnel lifecycle'
    Assert-Contains $tunnelStartFunction 'if ($publicVerified)' 'bootstrap publication failure preserves an already verified healthy tunnel'
    Assert-Contains $tunnelStartFunction 'Enter-EwspDeploymentLock' 'concurrent tunnel starts coordinate with deployment and publication operations'
    Assert-NotContains $tunnelStopFunction 'Publish-EwspMobileBootstrap' 'tunnel-stop never publishes a blank, localhost, or invalid fallback'
    Assert-Contains $tunnelStopFunction 'Enter-EwspDeploymentLock' 'tunnel-stop coordinates with deployment and tunnel activation operations'
    Assert-Contains $moduleText 'MOBILE_DISCOVERY=$($discovery.State)' 'tunnel-status reports the mobile discovery state'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot '.github\workflows\deploy.yml')) 'schedule:' 'bootstrap-only commits do not trigger application deployment reconciliation'
    Assert-Contains $moduleText "'K8S_ENVIRONMENT', 'CONFIGURATION', 'IMAGE_RESOLUTION', 'SECRET_PREPARATION'" 'k8s-up declares structured phases'
    Assert-Contains $k8sUpFunction 'Resolve-EwspKubernetesImageConfiguration' 'k8s-up prevents stale checkout image refs from overriding successful automatic deployment state'
    Assert-Contains $moduleText 'Configured image source:' 'k8s-status identifies the authority used for configured application images'
    Assert-NotContains $k8sUpFunction 'New-EwspImagePlan' 'Kubernetes path does not use sibling source-aware image planning'
    Assert-NotContains $k8sUpFunction 'Invoke-EwspImageBuilds' 'Kubernetes path does not invoke local application builds'
    Assert-Contains $k8sUpFunction 'New-EwspKubernetesRenderedManifests' 'k8s-up reconciles the backend ConfigMap fingerprint through rendered manifests'
    Assert-NotContains $deployFunction 'backend-config' 'existing image-only CD behavior does not independently mutate runtime ConfigMaps'
    $statefulMobileText = @(
        Get-Content -Raw (Join-Path $localRoot 'k8s\postgres\statefulset.yaml')
        Get-Content -Raw (Join-Path $localRoot 'k8s\redis\deployment.yaml')
        Get-Content -Raw (Join-Path $localRoot 'k8s\minio\statefulset.yaml')
    ) -join "`n"
    Assert-NotContains $statefulMobileText 'EWSP_MOBILE_' 'mobile metadata rollout requires no PostgreSQL, Redis, MinIO, or PVC configuration mutation'
    Assert-NotContains (Get-Content -Raw (Join-Path $localRoot 'public\mobile-bootstrap.json')) 'EWSP_MOBILE_' 'mobile release metadata leaves dynamic endpoint bootstrap behavior unchanged'
    Assert-NotContains $k8sUpFunction 'Resolve-EwspRepositoryPath' 'Kubernetes startup does not require sibling application repositories'
    Assert-Contains $moduleText 'Invoke-EwspImageBuilds $LocalRoot $EnvironmentInfo' 'Compose start retains local application build behavior'
    Assert-Contains $moduleText "Resolve-EwspRepositoryPath `$LocalRoot `$repository" 'repository discovery remains available for Compose and seed workflows'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot 'k8s\backend\deployment.yaml')) 'imagePullSecrets:' 'backend Pod uses private registry pull Secret'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot 'k8s\dashboard\deployment.yaml')) 'name: ghcr-pull' 'dashboard Pod uses private registry pull Secret'
    Assert-Contains $moduleText "'--tail=40'" 'Kubernetes failure diagnostics bound recent logs'
    Assert-Contains $moduleText 'Select-Object -Last 12' 'Kubernetes failure diagnostics bound recent events'
    Assert-Contains $moduleText "@('scale', `$target.Type, `$name" 'k8s-stop uses reversible controller scaling'
    Assert-Contains $moduleText "Names = @('cloudflared', 'dashboard', 'backend', 'redis')" 'k8s-stop scales cloudflared with application workloads'
    Assert-Contains $moduleText 'Permanent Cloudflare Tunnel' 'k8s-status reports permanent tunnel state'
    Assert-Contains $moduleText 'Trusted boundary source: node Pod CIDR' 'k8s-status identifies the node Pod CIDR trust source'
    Assert-Contains $moduleText "'SERVER_FORWARD_HEADERS_STRATEGY-', 'SERVER_TOMCAT_REMOTEIP_INTERNAL_PROXIES-'" 'disabled reconciliation removes permanent backend proxy overrides'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot '.env.example')) 'CLOUDFLARE_TUNNEL_ENABLED=false' 'environment example keeps permanent tunnel explicitly disabled'
    $permanentTrackedText = @(
        Get-Content -Raw (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
        Get-Content -Raw (Join-Path $localRoot 'k8s\cloudflared\deployment.yaml')
        Get-Content -Raw (Join-Path $localRoot 'k8s\networkpolicies\backend-ingress.yaml')
        Get-Content -Raw (Join-Path $localRoot 'k8s\networkpolicies\dashboard-ingress.yaml')
    ) -join "`n"
    $observedPodCidrFixture = '10.244.' + '0.0/24'
    Assert-NotContains $permanentTrackedText $observedPodCidrFixture 'permanent implementation does not hardcode the observed node Pod CIDR'
    Assert-NotContains $permanentTrackedText 'eyJ' 'permanent implementation contains no token-like runtime credential'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot 'k8s\postgres\statefulset.yaml')) 'replicas: 1' 'k8s-up source restores PostgreSQL replica count'
    Assert-Contains (Get-Content -Raw (Join-Path $localRoot 'k8s\minio\statefulset.yaml')) 'replicas: 1' 'k8s-up source restores MinIO replica count'

    Write-Host "All EWSP orchestration tests passed ($script:PassCount assertions)." -ForegroundColor Green
} finally {
    $safeBase = [System.IO.Path]::GetFullPath($testBase).TrimEnd('\') + '\'
    $safeTarget = [System.IO.Path]::GetFullPath($testRoot)
    if ($safeTarget.StartsWith($safeBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $safeTarget)) {
        Remove-Item -LiteralPath $safeTarget -Recurse -Force
    }
}
