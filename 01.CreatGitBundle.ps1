# --- 설정 부분 ---
$gpgPass = "abc123" # 🔐 사용할 비밀번호를 여기에 직접 입력하세요
# -----------------

# 0. 현재 브랜치 감지
$currentBranch = git rev-parse --abbrev-ref HEAD
$tagSuffix = $currentBranch -replace '/', '_'
$tagName = "last_sent_$tagSuffix"

# 1. 기준점 설정
$baseRef = git tag -l $tagName
if (-not $baseRef) {
    $baseRef = "origin/$currentBranch"
    Write-Host "ℹ️ [정보] '$tagName' 태그가 없어 $baseRef 기준 시작" -ForegroundColor Cyan
}

# 2. 보낼 커밋 개수 확인 (핵심 추가 부분)
$commitCount = (git rev-list --count "$($baseRef)..HEAD")

if ($commitCount -eq 0) {
    Write-Host "---------------------------------------------------"
    Write-Host "✅ [알림] 마지막 전송 이후 추가된 변경 사항이 없습니다." -ForegroundColor Green
    Write-Host "   새로운 작업을 완료하고 커밋한 후 다시 실행해 주세요."
    Write-Host "---------------------------------------------------"
    exit
}

# 3. 파일명 및 생성
$date = Get-Date -Format "yyyyMMdd_HHmm"
$bundleName = "update_${tagSuffix}_$date.bundle"
$gpgName = "$bundleName.gpg"


Write-Host "🚀 [작업] [$baseRef] 이후 [$commitCount]개의 커밋을 번들로 생성합니다..." -ForegroundColor Yellow

# 실제 번들 생성 (현재 브랜치 참조 포함)
git bundle create $bundleName "$($baseRef)..HEAD" $currentBranch

if ($LASTEXITCODE -eq 0) {
    # 4. 태그 업데이트
    git tag -f $tagName HEAD
    
    # 5. 번들 내용 확인 및 출력
    Write-Host "---------------------------------------------------"
    Write-Host "📦 [완료] $bundleName 생성 성공!" -ForegroundColor Green
    Write-Host ""
    Write-Host "📋 [번들 포함 참조]" -ForegroundColor Cyan
    
    git bundle list-heads $bundleName

    # 6. 🔐 GPG 암호화 수행 
    Write-Host "🔐 [암호화] 번들 파일을 암호화하는 중..." -ForegroundColor Magenta
    
    # --batch: 대화창 방지, --passphrase:     
    gpg --batch --yes --pinentry-mode loopback --passphrase $gpgPass --symmetric --cipher-algo AES256 --output $gpgName $bundleName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ [암호화 완료] $gpgName 파일이 생성되었습니다." -ForegroundColor Green
        # 원본 번들 파일 삭제
        Remove-Item $bundleName -Force
    } else {
        Write-Host "❌ [암호화 실패] GPG 암호화 중 문제가 발생했습니다." -ForegroundColor Red
        exit 1
    }
     
    Write-Host ""
    Write-Host "📧 이제 이 파일을 이메일에 첨부하여 보내세요." -ForegroundColor Green
    Write-Host "---------------------------------------------------"
} else {
    Write-Host "❌ [오류] 번들 생성 중 예상치 못한 문제가 발생했습니다." -ForegroundColor Red
}