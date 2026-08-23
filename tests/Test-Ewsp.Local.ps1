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
    }
    $secretOutput = @(& { New-EwspKubernetesSecretArtifact $localRoot $testSecretValues -SkipAcl } *>&1)
    $secretPath = [string]$secretOutput[-1]
    $secretText = Get-Content -Raw -LiteralPath $secretPath
    Assert-NotContains $secretText 'test-db-password-private' 'temporary Kubernetes Secret stores no plaintext password'
    Assert-NotContains ($secretOutput -join ' ') 'test-jwt-private' 'Kubernetes Secret preparation does not log secret values'
    $secretObject = $secretText | ConvertFrom-Json
    Assert-Equal (@($secretObject.data.PSObject.Properties.Name | Sort-Object) -join ',') 'JWT_SECRET,MINIO_ROOT_PASSWORD,MINIO_ROOT_USER,POSTGRES_PASSWORD,POSTGRES_USER' 'temporary Kubernetes Secret has exactly required keys'
    $incompleteSecretValues = $testSecretValues.Clone()
    $incompleteSecretValues.Remove('JWT_SECRET')
    Assert-ThrowsContains { New-EwspKubernetesSecretArtifact $localRoot $incompleteSecretValues -SkipAcl | Out-Null } 'JWT_SECRET' 'missing Kubernetes Secret setting is rejected by name'

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
    $rendered = New-EwspKubernetesRenderedManifests $localRoot 'ewsp-backend:test-a8b83aa9' 'ewsp-dashboard:test-471172e8' $renderRunner
    Assert-Contains (Get-Content -Raw $rendered.Backend) 'ewsp-backend:test-a8b83aa9' 'backend placeholder renders to exact image'
    Assert-Contains (Get-Content -Raw $rendered.Dashboard) 'ewsp-dashboard:test-471172e8' 'dashboard placeholder renders to exact image'
    Assert-Equal (Get-FileHash (Join-Path $localRoot 'k8s\backend\deployment.yaml') -Algorithm SHA256).Hash $backendSourceHash 'backend source manifest remains unchanged after rendering'
    Assert-Equal (Get-FileHash (Join-Path $localRoot 'k8s\dashboard\deployment.yaml') -Algorithm SHA256).Hash $dashboardSourceHash 'dashboard source manifest remains unchanged after rendering'
    Assert-ThrowsContains { New-EwspKubernetesRenderedManifests $localRoot 'ewsp-backend:latest' 'ewsp-dashboard:test' $renderRunner | Out-Null } 'Invalid resolved application image' 'latest Kubernetes application image is rejected'

    $applyPlan = @(Get-EwspKubernetesApplyPlan $localRoot $rendered $secretPath)
    Assert-Equal (@($applyPlan.Stage) -join ',') 'NAMESPACE,CONFIGMAPS,SECRET,POSTGRES,REDIS,MINIO,BACKEND,DASHBOARD' 'Kubernetes resources have deterministic apply order'
    Assert-Equal @($applyPlan | Where-Object { $_.Files -contains (Join-Path $localRoot 'k8s\config\secrets.example.yaml') }).Count 0 'placeholder Secret is absent from apply plan'
    $validationCapture = @{}
    $validationRunner = {
        param($filePath, $arguments)
        $validationCapture['Arguments'] = @($arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @('validated') }
    }.GetNewClosure()
    Assert-EwspKubernetesManifestSet $localRoot $applyPlan 'ewsp-backend:test-a8b83aa9' 'ewsp-dashboard:test-471172e8' $validationRunner | Out-Null
    $script:PassCount++
    Write-Host 'PASS: complete rendered Kubernetes manifest set validates'
    Assert-Contains ($validationCapture.Arguments -join ' ') '--dry-run=client --validate=true' 'manifest validation is strict client-side validation'
    Assert-NotContains ($validationCapture.Arguments -join ' ') 'secrets.example.yaml' 'example Secret is never validated as a real apply input'

    $pullPod = [PSCustomObject]@{ status = [PSCustomObject]@{ phase = 'Pending'; containerStatuses = @([PSCustomObject]@{ state = [PSCustomObject]@{ waiting = [PSCustomObject]@{ reason = 'ImagePullBackOff' } }; lastState = [PSCustomObject]@{} }) } }
    Assert-Equal (Get-EwspKubernetesPodReason $pullPod) 'ImagePullBackOff' 'Pod diagnostics recognize image pull failure'
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

    $missingCloudflared = Get-EwspCloudflaredInfo -CommandResolver { param($name) $null }
    Assert-Equal $missingCloudflared.Available $false 'Quick Tunnel detects unavailable cloudflared'
    Assert-ThrowsContains { Assert-EwspCloudflaredAvailable $missingCloudflared | Out-Null } 'CLOUDFLARED_MISSING' 'missing cloudflared uses precise diagnostic category'
    $cloudflaredRunner = { param($filePath, $arguments) New-FakeNativeResult 0 @('cloudflared version 2026.8.0') }
    $cloudflaredInfo = Get-EwspCloudflaredInfo -CommandResolver { param($name) [PSCustomObject]@{ Source = 'C:\tools\cloudflared.exe' } } -CommandRunner $cloudflaredRunner
    Assert-Equal $cloudflaredInfo.Available $true 'Quick Tunnel accepts runnable cloudflared'
    Assert-Contains $cloudflaredInfo.Version '2026.8.0' 'Quick Tunnel reports cloudflared version'

    Assert-Equal (ConvertTo-EwspLiteralIpv4Regex '10.244.0.24') '10\.244\.0\.24' 'dashboard Pod IPv4 is escaped as a literal regex'
    Assert-Equal (New-EwspQuickTunnelTrustRegex '10.244.0.24') '^(?:10\.244\.0\.24|127\.0\.0\.1)$' 'temporary trust boundary contains only dashboard Pod and loopback'
    Assert-ThrowsContains { ConvertTo-EwspLiteralIpv4Regex '10.244.0.0/24' | Out-Null } 'DASHBOARD_POD_RESOLUTION_FAILED' 'non-IPv4 dashboard Pod value is rejected'

    $readyDashboardPod = @{
        metadata = @{ name = 'dashboard-test' }
        status = @{
            phase = 'Running'; podIP = '10.244.0.77'
            conditions = @(@{ type = 'Ready'; status = 'True' })
            containerStatuses = @(@{ ready = $true })
        }
    }
    $podRunner = {
        param($filePath, $arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($readyDashboardPod) } | ConvertTo-Json -Depth 8 -Compress)) }
    }.GetNewClosure()
    $resolvedPod = Get-EwspReadyDashboardPod $podRunner
    Assert-Equal $resolvedPod.Ip '10.244.0.77' 'current Ready dashboard Pod IP is derived by stable labels'
    $twoPodRunner = {
        param($filePath, $arguments)
        [PSCustomObject]@{ ExitCode = 0; Output = @((@{ items = @($readyDashboardPod, $readyDashboardPod) } | ConvertTo-Json -Depth 8 -Compress)) }
    }.GetNewClosure()
    Assert-ThrowsContains { Get-EwspReadyDashboardPod $twoPodRunner | Out-Null } 'found 2' 'Quick Tunnel requires exactly one Ready dashboard Pod'

    Assert-Equal (ConvertFrom-EwspQuickTunnelUrl 'INF Requesting new quick Tunnel on https://Calm-Fog-123.trycloudflare.com') 'https://calm-fog-123.trycloudflare.com' 'Quick Tunnel URL is parsed robustly from log text'
    Assert-Equal (ConvertFrom-EwspQuickTunnelUrl 'https://*.trycloudflare.com') $null 'wildcard trycloudflare origin is never accepted as a generated URL'

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
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner { } | Out-Null } 'SEED_FILE_MISSING' 'Kubernetes local seed rejects a missing seed file'
    $seedTestPath = Join-Path $seedTestBackend 'local-dev\seed-dashboard-users.sql'
    Set-Content -LiteralPath $seedTestPath -Value "-- local test only`nselect 1;"
    $trackedSeedGit = {
        param($repositoryPath, $arguments)
        if ($arguments[0] -eq 'ls-files') { [PSCustomObject]@{ ExitCode = 0; Output = @('local-dev/seed-dashboard-users.sql') } }
        else { [PSCustomObject]@{ ExitCode = 0; Output = @() } }
    }
    Assert-ThrowsCategory { Resolve-EwspKubernetesSeedFile $localRoot -BackendRepositoryPath $seedTestBackend -GitRunner $trackedSeedGit | Out-Null } 'SEED_FILE_TRACKED' 'Kubernetes local seed rejects a tracked seed file'
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

    Remove-EwspKubernetesSecretArtifact $localRoot

    $moduleText = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'scripts\Ewsp.Local.psm1')
    foreach ($destructiveGitOperation in @("@('reset'", "@('clean'", "@('stash'", "@('checkout'", "@('rebase'")) {
        Assert-NotContains $moduleText $destructiveGitOperation "orchestration does not introduce destructive Git operation $destructiveGitOperation"
    }
    Assert-NotContains $moduleText "@('delete', 'namespace'" 'Kubernetes orchestration does not delete its namespace'
    Assert-NotContains $moduleText "@('delete', 'pvc'" 'Kubernetes orchestration does not delete PVCs'
    Assert-Contains $moduleText "'k8s-up' { Invoke-EwspKubernetesUp" 'command router exposes k8s-up'
    Assert-Contains $moduleText "'k8s-status' { Invoke-EwspKubernetesStatus" 'command router exposes k8s-status'
    Assert-Contains $moduleText "'k8s-stop' { Invoke-EwspKubernetesStop" 'command router exposes k8s-stop'
    Assert-Contains $moduleText "'k8s-seed' { Invoke-EwspKubernetesSeed" 'command router exposes explicit k8s-seed'
    Assert-Contains $moduleText "'tunnel-quick' { Invoke-EwspQuickTunnelStart" 'command router exposes tunnel-quick'
    Assert-Contains $moduleText "'tunnel-status' { Invoke-EwspQuickTunnelStatus" 'command router exposes tunnel-status'
    Assert-Contains $moduleText "'tunnel-stop' { Invoke-EwspQuickTunnelStop" 'command router exposes tunnel-stop'
    Assert-NotContains $moduleText '10\.244\.0\.24|127' 'Quick Tunnel implementation does not hardcode the example Pod IP'
    Assert-NotContains $moduleText '*.trycloudflare.com' 'Quick Tunnel implementation never configures wildcard trycloudflare origin'
    Assert-NotContains $moduleText "Stop-Process -Name cloudflared" 'Quick Tunnel never kills arbitrary cloudflared processes by name'
    Assert-NotContains $moduleText "@('delete', 'pvc'" 'Quick Tunnel lifecycle leaves Kubernetes PVCs untouched'
    Assert-Contains $moduleText 'Wait-EwspBackendServiceReadiness' 'Quick Tunnel synchronizes on Kubernetes backend readiness state'
    Assert-Contains $moduleText 'kubernetes.io/service-name=backend' 'Quick Tunnel synchronizes on the backend EndpointSlice'
    Assert-Contains $moduleText '/api/v1/namespaces/ewsp/services/http:backend:8080/proxy/api/health' 'Quick Tunnel verifies direct backend Service health'
    Assert-NotContains $moduleText "Backend health failed after trusted-proxy configuration." 'one-shot post-rollout health classification is removed'
    $k8sUpFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspKubernetesUp \{.*?(?=function Invoke-EwspStop \{)').Value
    $tunnelStartFunction = [regex]::Match($moduleText, '(?s)function Invoke-EwspQuickTunnelStart \{.*?(?=function Invoke-EwspQuickTunnelStatus \{)').Value
    Assert-NotContains $k8sUpFunction 'Invoke-EwspKubernetesSeed' 'k8s-up never invokes local user seeding automatically'
    Assert-NotContains $tunnelStartFunction 'Invoke-EwspKubernetesSeed' 'tunnel-quick never invokes local user seeding automatically'
    Assert-Contains $moduleText "'K8S_ENVIRONMENT', 'REPOSITORY_STATE', 'IMAGE_RESOLUTION', 'SECRET_PREPARATION'" 'k8s-up declares structured phases'
    Assert-Contains $moduleText "'--tail=40'" 'Kubernetes failure diagnostics bound recent logs'
    Assert-Contains $moduleText 'Select-Object -Last 12' 'Kubernetes failure diagnostics bound recent events'
    Assert-Contains $moduleText "@('scale', `$target.Type, `$name" 'k8s-stop uses reversible controller scaling'
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
