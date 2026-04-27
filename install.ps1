param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot "install.yaml")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── YAML Reader ────────────────────────────────────────────────────────
# install.yaml 스키마 전용 파서 (외부 모듈 의존성 없음)
function Read-InstallConfig {
    param([string]$Path)

    $lines = Get-Content $Path -Encoding UTF8
    $cfg     = [ordered]@{ apps = [System.Collections.Generic.List[object]]::new() }
    $app     = $null
    $cfgFile = $null
    $inCfgFiles = $false

    foreach ($raw in $lines) {
        if ($raw.Trim() -eq '' -or $raw.Trim().StartsWith('#')) { continue }

        switch -Regex ($raw) {
            '^installDir:\s*(.+)$' {
                $cfg.installDir = $Matches[1].Trim()
            }
            '^  - name:\s*(.+)$' {
                $app = [ordered]@{
                    name    = $Matches[1].Trim()
                    enabled = $true
                    version = ''
                    install = [ordered]@{ configFiles = [System.Collections.Generic.List[object]]::new() }
                }
                $cfg.apps.Add($app)
                $inCfgFiles = $false
                $cfgFile    = $null
            }
            '^    enabled:\s*(.+)$' {
                if ($app) { $app.enabled = $Matches[1].Trim() -eq 'true' }
            }
            '^    version:\s*"?([^"#\s]+)' {
                if ($app) { $app.version = $Matches[1].Trim() }
            }
            '^      type:\s*(.+)$' {
                if ($app) { $app.install.type = $Matches[1].Trim() }
            }
            '^      url:\s*"?([^"#]+?)"?\s*$' {
                if ($app) { $app.install.url = $Matches[1].Trim() }
            }
            '^      extractedDir:\s*"?([^"#]+?)"?\s*$' {
                if ($app) { $app.install.extractedDir = $Matches[1].Trim() }
            }
            '^      script:\s*"?([^"#]+?)"?\s*$' {
                if ($app) { $app.install.script = $Matches[1].Trim() }
            }
            '^      configFiles:' {
                if ($app) { $inCfgFiles = $true }
            }
            '^        - src:\s*"?([^"#]+?)"?\s*$' {
                if ($app -and $inCfgFiles) {
                    $cfgFile = [ordered]@{ src = $Matches[1].Trim() }
                    $app.install.configFiles.Add($cfgFile)
                }
            }
            '^          dst:\s*"?([^"#]+?)"?\s*$' {
                if ($cfgFile) { $cfgFile.dst = $Matches[1].Trim() }
            }
        }
    }

    return $cfg
}
#endregion

#region ── Helpers ────────────────────────────────────────────────────────────
function Resolve-Tpl([string]$s, [string]$ver) { $s.Replace('{version}', $ver) }

function New-DirIfMissing([string]$path) {
    if (-not (Test-Path $path)) { New-Item $path -ItemType Directory -Force | Out-Null }
}

function Write-Step([string]$msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "  [--] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  [!!] $msg" -ForegroundColor Red }
#endregion

#region ── Install Handlers ───────────────────────────────────────────────────
function Install-ZipApp {
    param($App, [string]$AppRootDir)

    $ver     = $App.version
    $url     = Resolve-Tpl $App.install.url $ver
    $zipName = Split-Path $url -Leaf
    $binDir  = Join-Path $AppRootDir "server"
    $zipPath = Join-Path $binDir $zipName

    New-DirIfMissing $binDir

    # 1. 다운로드
    if (Test-Path $zipPath) {
        Write-Skip "Already downloaded: $zipName"
    } else {
        Write-Step "Downloading $zipName..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -ErrorAction Stop
            Write-OK "Download complete."
        } catch {
            Write-Err "Download failed: $($_.Exception.Message)"
            return $false
        }
    }

    # 2. 압축 해제 (tar 사용 - 대용량/긴경로 안정적)
    Write-Step "Extracting..."
    $tempDir = Join-Path $binDir "_temp"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item $tempDir -ItemType Directory -Force | Out-Null
    tar -xf $zipPath -C $tempDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Extraction failed (tar exit $LASTEXITCODE)"
        return $false
    }

    # 3. 바이너리 이동
    $extractedDir = Resolve-Tpl $App.install.extractedDir $ver
    $src = Join-Path $tempDir $extractedDir
    Copy-Item "$src\*" -Destination $binDir -Recurse -Force
    Remove-Item $tempDir -Recurse -Force
    Write-OK "Binaries installed to server\"

    # 4. 설정 파일 복사 (appRoot 기준)
    foreach ($cf in $App.install.configFiles) {
        $cfgSrc = Join-Path $AppRootDir ($cf.src -replace '/', '\')
        $cfgDst = Join-Path $AppRootDir ($cf.dst -replace '/', '\')
        if (Test-Path $cfgSrc) {
            New-DirIfMissing (Split-Path $cfgDst -Parent)
            Copy-Item $cfgSrc $cfgDst -Force
            Write-OK "Config applied: $($cf.src) -> $($cf.dst)"
        } else {
            Write-Skip "Config not found (skipped): $($cf.src)"
        }
    }

    return $true
}

function Install-MsiApp {
    param($App, [string]$AppRootDir)

    $ver     = $App.version
    $url     = Resolve-Tpl $App.install.url $ver
    $msiName = Split-Path $url -Leaf
    $binDir  = Join-Path $AppRootDir "server"
    $msiPath = Join-Path $binDir $msiName

    New-DirIfMissing $binDir

    # 1. 다운로드
    if (Test-Path $msiPath) {
        Write-Skip "Already downloaded: $msiName"
    } else {
        Write-Step "Downloading $msiName..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $msiPath -ErrorAction Stop
            Write-OK "Download complete."
        } catch {
            Write-Err "Download failed: $($_.Exception.Message)"
            return $false
        }
    }

    # 2. msiexec /a 로 추출
    Write-Step "Extracting from MSI..."
    $tempDir = Join-Path $binDir "_temp"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    Start-Process msiexec.exe -Wait -ArgumentList "/a `"$msiPath`" /qb TARGETDIR=`"$tempDir`""

    # 3. 바이너리 이동 (설정 경로 우선, 없으면 exe 기준 자동 탐지)
    $relPath    = Resolve-Tpl $App.install.extractedDir $ver
    $sourcePath = Join-Path $tempDir ($relPath -replace '/', '\')
    if (-not (Test-Path $sourcePath)) {
        $exeName = "$($App.name).exe"
        $found   = Get-ChildItem $tempDir -Recurse -Filter $exeName -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        if ($found) {
            $sourcePath = Split-Path $found.FullName -Parent
            Write-Step "Auto-detected path: $($sourcePath.Replace($tempDir,''))"
        } else {
            Write-Err "Extracted path not found: $sourcePath"
            Remove-Item $tempDir -Recurse -Force
            return $false
        }
    }
    Copy-Item "$sourcePath\*" -Destination $binDir -Recurse -Force
    Write-OK "Binaries installed to server\"
    Remove-Item $tempDir -Recurse -Force

    return $true
}

function Install-CustomApp {
    param($App, [string]$InstallDir)

    $scriptPath = Join-Path $InstallDir ($App.install.script -replace '/', '\')
    if (-not (Test-Path $scriptPath)) {
        Write-Err "Custom script not found: $scriptPath"
        return $false
    }

    Write-Step "Running: $($App.install.script)"
    & $scriptPath -Version $App.version
    return $true
}
#endregion

#region ── Main ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          infra  install.ps1          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$cfgPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile }
           else { Join-Path $PSScriptRoot $ConfigFile }

if (-not (Test-Path $cfgPath)) {
    Write-Host "ERROR: ConfigFile not found: $cfgPath" -ForegroundColor Red
    exit 1
}

$config     = Read-InstallConfig $cfgPath
$installDir = $config.installDir

Write-Host "InstallDir : $installDir"
Write-Host "ConfigFile : $cfgPath"
Write-Host ""

$success = 0; $skipped = 0; $failed = 0

foreach ($app in $config.apps) {

    if (-not $app.enabled) {
        Write-Host "[$($app.name)] SKIPPED (disabled)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "[$($app.name)]  v$($app.version)  type=$($app.install.type)" -ForegroundColor White
    Write-Host ""

    $appRootDir = Join-Path $installDir $app.name
    New-DirIfMissing $appRootDir

    $ok = switch ($app.install.type) {
        'zip'    { Install-ZipApp    $app $appRootDir }
        'msi'    { Install-MsiApp    $app $appRootDir }
        'custom' { Install-CustomApp $app $installDir }
        default  { Write-Err "Unknown type: $($app.install.type)"; $false }
    }

    Write-Host ""
    if ($ok) { Write-OK "$($app.name) done."; $success++ }
    else     { Write-Err "$($app.name) FAILED."; $failed++ }
    Write-Host ""
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
$color = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "success=$success  skipped=$skipped  failed=$failed" -ForegroundColor $color
Write-Host ""
#endregion
