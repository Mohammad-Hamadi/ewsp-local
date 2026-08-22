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
    Assert-Equal ([regex]::Matches($composeConfiguration, '(?m)^\s+dockerfile: Dockerfile\s*$').Count) 2 'both applications use their repository Dockerfile'
    Assert-NotContains $composeConfiguration 'additional_contexts:' 'dashboard has no orchestration additional build context'
    Assert-NotContains $composeConfiguration 'VITE_API_BASE_URL' 'Compose does not pass the obsolete dashboard API build argument'
    Assert-NotContains $composeConfiguration 'VITE_WS_URL' 'Compose does not pass the obsolete dashboard WebSocket build argument'
    Assert-Equal ([regex]::Matches($composeConfiguration, '(?m)^  backend:\s*$').Count) 1 'backend service name remains exact'
    Assert-Contains $composeConfiguration '"${BACKEND_HOST_PORT:-8080}:8080"' 'backend keeps direct host port publication'
    Assert-NotContains $composeConfiguration 'network_mode:' 'dashboard and backend remain on the shared Compose default network'
    Assert-Contains $composeConfiguration 'command: ["redis-server", "--save", "", "--appendonly", "no"]' 'Redis persistence is explicitly disabled'
    Assert-Contains $composeConfiguration 'type: tmpfs' 'Redis image data path is replaced with tmpfs'
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

    $moduleText = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
    foreach ($destructiveGitOperation in @("@('reset'", "@('clean'", "@('stash'", "@('checkout'", "@('rebase'")) {
        Assert-NotContains $moduleText $destructiveGitOperation "orchestration does not introduce destructive Git operation $destructiveGitOperation"
    }

    Write-Host "All EWSP orchestration tests passed ($script:PassCount assertions)." -ForegroundColor Green
} finally {
    $safeBase = [System.IO.Path]::GetFullPath($testBase).TrimEnd('\') + '\'
    $safeTarget = [System.IO.Path]::GetFullPath($testRoot)
    if ($safeTarget.StartsWith($safeBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $safeTarget)) {
        Remove-Item -LiteralPath $safeTarget -Recurse -Force
    }
}
