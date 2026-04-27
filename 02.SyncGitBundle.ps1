param(
    [string[]]$BundleList,
    [switch]$DryRun,
    [switch]$NoReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# [설정] GPG 복호화용 비밀번호 (01번 스크립트와 동일하게 설정)
$gpgPass = "abc123"

# 현재 브랜치 감지
$currentBranch = git rev-parse --abbrev-ref HEAD
$tagSuffix = $currentBranch -replace '/', '_'
$bundlePattern = "update_${tagSuffix}_*"

Write-Host "사용 예시:" -ForegroundColor DarkGray
Write-Host "   .\02.SyncGitBundle.ps1 -DryRun" -ForegroundColor DarkGray
Write-Host '   .\02.SyncGitBundle.ps1 -BundleList "a.bundle","b.bundle"' -ForegroundColor DarkGray

function Write-Section($message) {
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
    Write-Host $message -ForegroundColor Cyan
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
}

# [변경] 안정적인 매개변수 직접 전달 방식으로 수정
function Decrypt-GpgFiles {
    # 현재 디렉토리에서 현재 브랜치 gpg 파일 검색
    $gpgFiles = Get-ChildItem -Path "${bundlePattern}.bundle.gpg" -File -ErrorAction SilentlyContinue
    foreach ($g in $gpgFiles) {
        # 복호화 결과는 현재 디렉토리에 저장
        $outName = $g.Name -replace '\.gpg$', ''
        Write-Host "🔐 [해독] $($g.Name) 해독 중..." -ForegroundColor Magenta

        # [수정] 파이프(|) 대신 --passphrase 매개변수 직접 사용
        gpg --batch --yes --pinentry-mode loopback --passphrase $gpgPass --decrypt --output $outName $g.FullName

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ [성공] 번들 파일 생성됨." -ForegroundColor Green
            Remove-Item $g.FullName -Force  # 해독 후 gpg 파일 삭제
        } else {
            Write-Host "❌ [실패] $($g.Name) 해독에 실패했습니다. 암호를 확인하세요." -ForegroundColor Red
        }
    }
}

function Get-BundleCandidates {
    param([string[]]$InputList)

    Decrypt-GpgFiles  # .gpg 파일 선행 해독

    if ($InputList -and $InputList.Count -gt 0) {
        $files = foreach ($item in $InputList) {
            if (Test-Path $item) {
                Get-Item $item
            } else {
                Write-Host "⚠️ [건너뜀] 파일 없음: $item" -ForegroundColor Yellow
            }
        }
    } else {
        $files = Get-ChildItem -Path "${bundlePattern}.bundle" -File | Sort-Object Name
    }

    if (-not $files -or $files.Count -eq 0) {
        Write-Host "❌ [오류] 적용할 .bundle 파일이 없습니다." -ForegroundColor Red
        exit 1
    }

    return @($files | Sort-Object Name)
}

function Get-BundlePrimaryRef {
    param([System.IO.FileInfo]$BundleFile)

    $lines = git bundle list-heads $BundleFile.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bundle head 조회 실패: $($BundleFile.Name)`n$($lines -join "`n")"
    }

    $parsed = @()
    foreach ($line in $lines) {
        $trimmed = $line.ToString().Trim()
        if (-not $trimmed) { continue }

        $parts = $trimmed -split '\s+', 2
        if ($parts.Count -lt 2) { continue }

        $parsed += [PSCustomObject]@{
            Commit = $parts[0]
            Ref    = $parts[1]
        }
    }

    if (-not $parsed -or $parsed.Count -eq 0) {
        throw "bundle에 유효한 ref가 없습니다: $($BundleFile.Name)"
    }

    $branchRef = $parsed | Where-Object { $_.Ref -like 'refs/heads/*' } | Select-Object -First 1
    if ($branchRef) { return $branchRef }

    $headRef = $parsed | Where-Object { $_.Ref -eq 'HEAD' } | Select-Object -First 1
    if ($headRef) { return $headRef }

    return ($parsed | Select-Object -First 1)
}

function Test-BundleCompatibility {
    param([System.IO.FileInfo]$BundleFile)

    $primaryRef = Get-BundlePrimaryRef -BundleFile $BundleFile

    # 이미 반영된 내용인지 체크 (fetch 후 조상 커밋 여부 확인)
    git fetch $BundleFile.FullName $primaryRef.Ref 2>$null
    if ($LASTEXITCODE -eq 0) {
        if (git merge-base --is-ancestor FETCH_HEAD HEAD 2>$null) {
            return [PSCustomObject]@{
                Compatible = $true
                AlreadyApplied = $true
                Output     = "Already Applied ($($primaryRef.Ref))"
            }
        }
    }

    $verifyOutput = git bundle verify $BundleFile.FullName 2>&1 | Out-String
    $ok = ($LASTEXITCODE -eq 0)

    return [PSCustomObject]@{
        Compatible = $ok
        AlreadyApplied = $false
        Output     = $verifyOutput.Trim()
    }
}

function Apply-Bundle {
    param(
        [System.IO.FileInfo]$BundleFile,
        [switch]$SkipReset
    )

    $primaryRef = Get-BundlePrimaryRef -BundleFile $BundleFile

    Write-Host "📦 [적용] $($BundleFile.Name)" -ForegroundColor Cyan
    Write-Host "🔖 [참조] $($primaryRef.Ref)" -ForegroundColor DarkGray
    
    # 해시 정보 출력 (요청사항 반영)
    git bundle list-heads $BundleFile.FullName

    git fetch $BundleFile.FullName $primaryRef.Ref
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ [오류] fetch 실패" -ForegroundColor Red
        return $false
    }

    if (-not $SkipReset) {
        Write-Host "🔄 [병합] FETCH_HEAD를 현재 브랜치에 반영합니다..." -ForegroundColor Yellow
        
        # Fast-forward 시도 후 안되면 일반 Merge
        git merge FETCH_HEAD --ff-only 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️ [알림] 일반 Merge 시도 중..." -ForegroundColor Gray
            git merge FETCH_HEAD --no-edit
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ [오류] 병합 충돌 발생" -ForegroundColor Red
            return $false
        }
    }

    # 적용 성공 후 원본 삭제
    Remove-Item $BundleFile.FullName -Force
    Write-Host "🗑️ [삭제] 원본 번들 제거 완료." -ForegroundColor DarkGray

    return $true
}

# --- 메인 실행 로직 ---
Write-Section "Bundle 순차 적용 시작"

$bundles = Get-BundleCandidates -InputList $BundleList
$pending = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$bundles | ForEach-Object { $pending.Add($_) }

$applied = [System.Collections.Generic.List[string]]::new()
$stuck   = [System.Collections.Generic.Dictionary[string, string]]::new()

while ($pending.Count -gt 0) {
    $appliedInPass = 0

    for ($i = 0; $i -lt $pending.Count; $i++) {
        $bundle = $pending[$i]
        Write-Host "🔍 [검증] $($bundle.Name)" -ForegroundColor Yellow

        $check = Test-BundleCompatibility -BundleFile $bundle
        
        # [중복 처리] 이미 적용된 번들은 삭제 후 건너뜀
        if ($check.AlreadyApplied) {
            Write-Host "✅ [인지] 이미 반영된 번들입니다. 삭제합니다." -ForegroundColor Green
            Remove-Item $bundle.FullName -Force
            $applied.Add("$($bundle.Name) (Skipped)")
            $pending.RemoveAt($i)
            $appliedInPass++
            break
        }

        if (-not $check.Compatible) {
            $stuck[$bundle.Name] = $check.Output
            continue
        }

        if ($DryRun) {
            Write-Host "🧪 [DryRun] 적용 가능: $($bundle.Name)" -ForegroundColor Green
            $applied.Add($bundle.Name)
            $pending.RemoveAt($i)
            $appliedInPass++
            break
        }

        if (Apply-Bundle -BundleFile $bundle -SkipReset:$NoReset) {
            $applied.Add($bundle.Name)
            $pending.RemoveAt($i)
            $appliedInPass++
            break
        }
    }

    if ($appliedInPass -eq 0) { break }
}

Write-Section "결과"

if ($applied.Count -gt 0) {
    Write-Host "✅ [적용 완료 목록]" -ForegroundColor Green
    $applied | ForEach-Object { Write-Host " - $_" }
} else {
    Write-Host "ℹ️ [정보] 적용된 번들이 없습니다." -ForegroundColor Yellow
}

if ($pending.Count -gt 0) {
    Write-Host "⚠️ [미적용 목록] 선행 tag/commit 이 없어 적용할 수 없습니다." -ForegroundColor Yellow
    foreach ($left in $pending) {
        Write-Host " - $($left.Name)" -ForegroundColor Yellow
        if ($stuck.ContainsKey($left.Name)) {
            Write-Host "   사유: $($stuck[$left.Name])" -ForegroundColor DarkYellow
        }
    }

    Write-Host "" 
    Write-Host "힌트: 아래 선행 commit/tag가 현재 저장소에 있어야 다음 번들이 적용됩니다." -ForegroundColor DarkYellow
    Write-Host "      git bundle verify <bundle파일> 출력의 prerequisite 항목을 확인하세요." -ForegroundColor DarkYellow
    if ($DryRun) {
        exit 0
    }
    exit 2
}

Write-Host "" 
Write-Host "✅ [완료] 순차 적용이 끝났습니다." -ForegroundColor Green
Write-Host "현재 시점: $(git log -1 --format='%cd (%h) %s')" -ForegroundColor White