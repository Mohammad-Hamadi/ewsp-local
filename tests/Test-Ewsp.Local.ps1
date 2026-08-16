[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$localRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $localRoot 'scripts\Ewsp.Local.psm1') -Force -DisableNameChecking

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
    Write-Host "PASS: $Message"
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if (-not $Actual.Contains($Expected)) { throw "$Message Expected '$Actual' to contain '$Expected'." }
    Write-Host "PASS: $Message"
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

    $recipeLocal = Join-Path $testRoot 'recipe-local'
    $recipeDocker = Join-Path $recipeLocal 'docker'
    New-Item -ItemType Directory -Path $recipeDocker -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $recipeDocker 'test.Dockerfile') -Value 'FROM scratch'
    $imageRepository = @{
        Name = 'image-app'
        Image = @{
            Service = 'image-app'; RepositoryName = 'ewsp-image-test'; EnvironmentName = 'EWSP_TEST_IMAGE'
            RecipeFiles = @('docker/test.Dockerfile'); BuildInputs = @('VITE_API_BASE_URL')
        }
    }
    $cleanImageState = [PSCustomObject]@{
        Dirty = $false; Commit = '0123456789abcdef0123456789abcdef01234567'; ShortCommit = '0123456'
    }
    $dirtyImageState = [PSCustomObject]@{
        Dirty = $true; Commit = '0123456789abcdef0123456789abcdef01234567'; ShortCommit = '0123456'
    }
    $imageEnvironment = @{ VITE_API_BASE_URL = 'http://localhost:8080' }
    $cleanImageA = Get-EwspImageDescriptor $recipeLocal $imageRepository $cleanImageState $imageEnvironment 'session-a'
    $cleanImageARepeat = Get-EwspImageDescriptor $recipeLocal $imageRepository $cleanImageState $imageEnvironment 'session-b'
    Assert-Equal $cleanImageA.Tag $cleanImageARepeat.Tag 'clean image identity is stable across sessions'
    Assert-Equal (Resolve-EwspImageAction $cleanImageA $true) 'REUSE' 'existing clean image is reused'
    Assert-Equal (Resolve-EwspImageAction $cleanImageA $false) 'BUILD' 'missing clean image is built'

    Set-Content -LiteralPath (Join-Path $recipeDocker 'test.Dockerfile') -Value "FROM scratch`nLABEL recipe=changed"
    $cleanImageRecipeChanged = Get-EwspImageDescriptor $recipeLocal $imageRepository $cleanImageState $imageEnvironment 'session-c'
    if ($cleanImageRecipeChanged.Tag -eq $cleanImageA.Tag) { throw 'Recipe change did not change clean image identity.' }
    Write-Host 'PASS: recipe change changes clean image identity'

    $changedEnvironment = @{ VITE_API_BASE_URL = 'http://localhost:18080' }
    $cleanImageInputChanged = Get-EwspImageDescriptor $recipeLocal $imageRepository $cleanImageState $changedEnvironment 'session-d'
    if ($cleanImageInputChanged.Tag -eq $cleanImageRecipeChanged.Tag) { throw 'Build input change did not change image identity.' }
    Write-Host 'PASS: build-time input changes image identity'

    $dirtyImage = Get-EwspImageDescriptor $recipeLocal $imageRepository $dirtyImageState $imageEnvironment 'session-dirty'
    Assert-Equal $dirtyImage.Reusable $false 'dirty image is non-reusable'
    Assert-Equal (Resolve-EwspImageAction $dirtyImage $true) 'BUILD' 'dirty image builds even if a same-tag image exists'
    Assert-Contains $dirtyImage.Tag 'dirty-0123456-session-dirty' 'dirty image tag identifies dirty session'

    $productionConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $localRoot 'config\repositories.psd1')
    $backendImageConfig = @($productionConfig.Repositories | Where-Object Name -eq 'ewsp-backend')[0].Image
    $dashboardImageConfig = @($productionConfig.Repositories | Where-Object Name -eq 'ewsp-dashboard')[0].Image
    Assert-Contains ($backendImageConfig.RecipeFiles -join '|') 'docker/backend.Dockerfile.dockerignore' 'backend identity includes its Docker ignore recipe'
    Assert-Contains ($dashboardImageConfig.RecipeFiles -join '|') 'docker/dashboard.nginx.conf' 'dashboard identity includes Nginx configuration'
    Assert-Contains ($dashboardImageConfig.RecipeFiles -join '|') 'docker/dashboard.Dockerfile.dockerignore' 'dashboard identity includes its Docker ignore recipe'
    Assert-Contains ($dashboardImageConfig.BuildInputs -join '|') 'VITE_API_BASE_URL' 'dashboard identity includes browser API build input'

    $nginxConfiguration = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'docker\dashboard.nginx.conf')
    Assert-Contains $nginxConfiguration 'location ~* \.' 'Nginx treats file-like requests as assets'
    Assert-Contains $nginxConfiguration 'try_files $uri =404;' 'Nginx returns 404 for missing assets'

    $composeConfiguration = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'compose.yml')
    Assert-Contains $composeConfiguration 'command: ["redis-server", "--save", "", "--appendonly", "no"]' 'Redis persistence is explicitly disabled'
    Assert-Contains $composeConfiguration 'type: tmpfs' 'Redis image data path is replaced with tmpfs'

    Write-Host 'All EWSP orchestration tests passed.' -ForegroundColor Green
} finally {
    $safeBase = [System.IO.Path]::GetFullPath($testBase).TrimEnd('\') + '\'
    $safeTarget = [System.IO.Path]::GetFullPath($testRoot)
    if ($safeTarget.StartsWith($safeBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $safeTarget)) {
        Remove-Item -LiteralPath $safeTarget -Recurse -Force
    }
}
