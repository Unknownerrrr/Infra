param(
    [string]$ConfigFile    = (Join-Path $PSScriptRoot "install.yaml"),
    [switch]$KeepDownloads,          # zip/tgz/msi 보관 (재설치 속도 향상)
    [string[]]$Only        = @()     # 특정 앱만 정리 (예: -Only kafka,kestra)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── YAML Reader (install.ps1 과 동일) ──────────────────────────────────
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
            '^installDir:\s*(.+)$'             { $cfg.installDir = $Matches[1].Trim() }
            '^  - name:\s*(.+)$' {
                $app = [ordered]@{
                    name    = $Matches[1].Trim()
                    enabled = $true
                    version = ''
                    install = [ordered]@{ configFiles = [System.Collections.Generic.List[object]]::new() }
                }
                $cfg.apps.Add($app)
                $inCfgFiles = $false; $cfgFile = $null
            }
            '^    enabled:\s*(.+)$'            { if ($app) { $app.enabled = $Matches[1].Trim() -eq 'true' } }
            '^    version:\s*"?([^"#\s]+)'     { if ($app) { $app.version = $Matches[1].Trim() } }
            '^      type:\s*(.+)$'             { if ($app) { $app.install.type = $Matches[1].Trim() } }
            '^      url:\s*"?([^"#]+?)"?\s*$'  { if ($app) { $app.install.url = $Matches[1].Trim() } }
            '^      extractedDir:\s*"?([^"#]+?)"?\s*$' { if ($app) { $app.install.extractedDir = $Matches[1].Trim() } }
            '^      script:\s*"?([^"#]+?)"?\s*$'       { if ($app) { $app.install.script = $Matches[1].Trim() } }
            '^      configFiles:'              { if ($app) { $inCfgFiles = $true } }
            '^        - src:\s*"?([^"#]+?)"?\s*$' {
                if ($app -and $inCfgFiles) {
                    $cfgFile = [ordered]@{ src = $Matches[1].Trim() }
                    $app.install.configFiles.Add($cfgFile)
                }
            }
            '^          dst:\s*"?([^"#]+?)"?\s*$' { if ($cfgFile) { $cfgFile.dst = $Matches[1].Trim() } }
        }
    }
    return $cfg
}
#endregion

#region ── Helpers ────────────────────────────────────────────────────────────
function Remove-DirSafe([string]$path, [string]$label) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "  [DEL] $label" -ForegroundColor DarkYellow
    }
}

function Remove-FileSafe([string]$path, [string]$label) {
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Host "  [DEL] $label" -ForegroundColor DarkYellow
    }
}

function Remove-DirContents([string]$dir, [string]$label, [switch]$KeepDl) {
    if (-not (Test-Path $dir)) { return }

    $dlExts = @('.zip', '.tgz', '.gz', '.msi', '.exe', '.bat')

    Get-ChildItem $dir | ForEach-Object {
        if ($KeepDl -and $dlExts -contains $_.Extension.ToLower()) {
            Write-Host "  [--]  kept  : $($_.Name)" -ForegroundColor Gray
        } else {
            Remove-Item $_.FullName -Recurse -Force
            Write-Host "  [DEL] $label/$($_.Name)" -ForegroundColor DarkYellow
        }
    }
}

function Stop-JavaProcess {
    $procs = Get-Process java -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
        Write-Host "  [STP] java 프로세스 종료" -ForegroundColor DarkYellow
    }
}

function Write-OK([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "  [--] $msg" -ForegroundColor Gray }
#endregion

#region ── App-specific Cleanup ───────────────────────────────────────────────
function Cleanup-App {
    param($App, [string]$AppRootDir, [switch]$KeepDl)

    $name   = $App.name
    $server = Join-Path $AppRootDir "server"

    switch ($name) {

        'kafka' {
            Stop-JavaProcess
            Remove-DirContents $server "server" -KeepDl:$KeepDl
            Remove-DirSafe (Join-Path $AppRootDir "data")   "data/"
            Remove-DirSafe (Join-Path $AppRootDir "logs")   "logs/"
        }

        'kestra' {
            Stop-JavaProcess
            Remove-DirContents $server "server" -KeepDl:$KeepDl
            Remove-DirSafe (Join-Path $AppRootDir "data")    "data/"
            Remove-DirSafe (Join-Path $AppRootDir "storage") "storage/"
            Remove-DirSafe (Join-Path $AppRootDir "plugins") "plugins/"
            Remove-FileSafe (Join-Path $AppRootDir ".env")   ".env"
        }

        default {
            # zip / msi 타입 — server/ 내용 제거, 설정 파일(appRoot)은 보존
            Remove-DirContents $server "server" -KeepDl:$KeepDl
            Remove-DirSafe (Join-Path $server "_temp") "server/_temp"
        }
    }
}
#endregion

#region ── Main ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         infra  cleanup.ps1           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
if ($KeepDownloads) { Write-Host "  mode: KeepDownloads (zip/tgz/msi 보관)" -ForegroundColor Yellow }
if ($Only.Count)    { Write-Host "  scope: $($Only -join ', ')" -ForegroundColor Yellow }
Write-Host ""

$cfgPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile }
           else { Join-Path $PSScriptRoot $ConfigFile }

if (-not (Test-Path $cfgPath)) {
    Write-Host "ERROR: ConfigFile not found: $cfgPath" -ForegroundColor Red
    exit 1
}

$config     = Read-InstallConfig $cfgPath
$installDir = $config.installDir

$cleaned = 0; $skipped = 0

foreach ($app in $config.apps) {

    # -Only 필터
    if ($Only.Count -gt 0 -and $Only -notcontains $app.name) {
        continue
    }

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "[$($app.name)]" -ForegroundColor White
    Write-Host ""

    $appRootDir = Join-Path $installDir $app.name

    if (-not (Test-Path $appRootDir)) {
        Write-Skip "$($app.name)/ 디렉터리 없음 — 건너뜀"
        $skipped++
    } else {
        Cleanup-App $app $appRootDir -KeepDl:$KeepDownloads
        Write-OK "$($app.name) 정리 완료"
        $cleaned++
    }
    Write-Host ""
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host "cleaned=$cleaned  skipped=$skipped" -ForegroundColor Green
Write-Host ""
Write-Host "다음 단계: .\install.ps1" -ForegroundColor Cyan
Write-Host ""
#endregion
