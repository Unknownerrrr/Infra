#!/bin/bash 

# 사용법 출력 함수
usage() {
    echo -e "\e[90m사용 예시:\e[0m"
    echo -e "\e[90m  ./03.SyncGitBundle.sh --dry-run\e[0m"
    echo -e "\e[90m  ./03.SyncGitBundle.sh\e[0m"
    exit 1
} 

# [추가] GPG 설정 부분
GPG_PASS="abc123"

# 현재 브랜치 감지
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TAG_SUFFIX="${CURRENT_BRANCH//\//_}"
BUNDLE_PATTERN="update_${TAG_SUFFIX}_*"

# 변수 초기화
BUNDLE_LIST=()
DRY_RUN=false
NO_RESET=false

# 인자 처리
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --no-reset) NO_RESET=true; shift ;;
        -h|--help) usage ;;
        *) BUNDLE_LIST+=("$1"); shift ;;
    esac
done

write_section() {
    echo -e "\e[90m---------------------------------------------------\e[0m"
    echo -e "\e[36m$1\e[0m"
    echo -e "\e[90m---------------------------------------------------\e[0m"
}

# 번들의 주요 ref를 감지하는 함수
get_bundle_primary_ref() {
    local bundle="$1"
    
    # bundle list-heads 출력 파싱
    local bundle_lines=$(git bundle list-heads "$bundle" 2>&1)
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to list bundle heads" >&2
        return 1
    fi
    
    # refs/heads/* 형태의 ref 찾기
    local branch_ref=$(echo "$bundle_lines" | grep -E 'refs/heads/' | head -1 | awk '{print $NF}')
    if [ -n "$branch_ref" ]; then
        echo "$branch_ref"
        return 0
    fi
    
    # HEAD 형태 찾기
    local head_ref=$(echo "$bundle_lines" | grep -E 'HEAD$' | head -1 | awk '{print $NF}')
    if [ -n "$head_ref" ]; then
        echo "$head_ref"
        return 0
    fi
    
    # 첫 번째 ref 사용
    local first_ref=$(echo "$bundle_lines" | head -1 | awk '{print $NF}')
    if [ -n "$first_ref" ]; then
        echo "$first_ref"
        return 0
    fi
    
    echo "ERROR: No valid ref found in bundle" >&2
    return 1
}

# [추가] GPG 파일 선행 해독 함수
decrypt_gpg_files() {
    # 다운로드 폴더에서 현재 브랜치 gpg 파일 검색
    local gpg_files=$(ls ~/storage/downloads/${BUNDLE_PATTERN}.bundle.gpg 2>/dev/null)
    
    for g in $gpg_files; do
        if [ -f "$g" ]; then
            local out_name="${g%.gpg}"
            echo -e "\e[35m🔐 [해독] $(basename "$g") 해독 중...\e[0m"
                        
            gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASS" --decrypt --output "$out_name" "$g"
            
            if [ $? -eq 0 ]; then
                echo -e "\e[32m✅ [성공] 번들 파일 생성됨.\e[0m"
                rm "$g" # 해독 후 .gpg 파일 삭제
            else
                echo -e "\e[31m❌ [오류] 해독 실패: $(basename "$g")\e[0m"
            fi
        fi
    done
}

# 번들 후보 찾기 전에 해독 먼저 실행
decrypt_gpg_files

# 번들 후보 찾기
if [ ${#BUNDLE_LIST[@]} -eq 0 ]; then
    mapfile -t BUNDLES < <(ls ~/storage/downloads/${BUNDLE_PATTERN}.bundle 2>/dev/null | sort)
else
    BUNDLES=()
    for item in "${BUNDLE_LIST[@]}"; do
        if [ -f "$item" ]; then
            BUNDLES+=("$item")
        else
            echo -e "\e[33m⚠️ [건너뜀] 파일 없음: $item\e[0m"
        fi
    done
fi

if [ ${#BUNDLES[@]} -eq 0 ]; then
    echo -e "\e[31m❌ [오류] 적용할 .bundle 파일이 없습니다.\e[0m"
    exit 1
fi

write_section "Bundle 순차 적용 시작"
echo -e "\e[36m📚 [입력 목록]\e[0m"
for b in "${BUNDLES[@]}"; do echo " - $(basename "$b")"; done

PENDING=("${BUNDLES[@]}")
APPLIED=()
declare -A STUCK_REASONS

while [ ${#PENDING[@]} -gt 0 ]; do
    APPLIED_IN_PASS=0
    NEW_PENDING=()

    for i in "${!PENDING[@]}"; do
        bundle="${PENDING[$i]}"
        echo -e "\e[33m🔍 [검증] $(basename "$bundle")\e[0m"

        # 번들의 주요 ref 감지
        primary_ref=$(get_bundle_primary_ref "$bundle")
        if [ $? -ne 0 ]; then
            STUCK_REASONS["$bundle"]="$primary_ref"
            NEW_PENDING+=("$bundle")
            continue
        fi
        echo -e "\e[90m🔖 [참조] $primary_ref\e[0m"

        # 1. 번들 유효성 및 선행 조건 검증
         VERIFY_OUTPUT=$(git bundle verify "$bundle" 2>&1)
        if [ $? -ne 0 ]; then
            STUCK_REASONS["$bundle"]="$VERIFY_OUTPUT"
            NEW_PENDING+=("$bundle")
            continue
        fi

        fi

        # 3. [핵심] 이미 현재 브랜치에 포함된 내용인지 확인
        if git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
            echo -e "\e[32m✅ [건너뜀] 이미 로컬에 반영된 데이터입니다.\e[0m"

            # 적용 완료된 원본 파일 삭제 (중복 시에도 삭제)
            rm "$bundle" 
            echo -e "\e[90m🗑️  [삭제 완료] $(basename "$bundle") 파일이 제거되었습니다.\e[0m"

            APPLIED+=("$(basename "$bundle") (Skipped)")
            APPLIED_IN_PASS=$((APPLIED_IN_PASS + 1))
            for ((j=i+1; j<${#PENDING[@]}; j++)); do NEW_PENDING+=("${PENDING[$j]}"); done
            break
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "\e[32m🧪 [DryRun] 적용 가능: $(basename "$bundle")\e[0m"
            APPLIED+=("$(basename "$bundle")")
            APPLIED_IN_PASS=$((APPLIED_IN_PASS + 1))
            for ((j=i+1; j<${#PENDING[@]}; j++)); do NEW_PENDING+=("${PENDING[$j]}"); done
            break
        fi

        # 4. 적용 단계: fast-forward 시도 후 안되면 일반 merge
        echo -e "\e[36m📦 [병합] $(basename "$bundle")\e[0m"

        git merge FETCH_HEAD --ff-only 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "\e[90m⚠️  [알림] 일반 Merge 시도 중...\e[0m"
            git merge FETCH_HEAD --no-edit
        fi

        if [ $? -ne 0 ]; then
            echo -e "\e[31m❌ [오류] 병합 중 충돌 발생! 수동 해결이 필요합니다.\e[0m"
            exit 1
        fi

        # [추가] 적용 성공 후 원본 번들 파일 삭제
        rm "$bundle"
        echo -e "\e[90m🗑️  [삭제 완료] 적용된 파일을 제거했습니다.\e[0m"

        APPLIED+=("$(basename "$bundle")")
        APPLIED_IN_PASS=$((APPLIED_IN_PASS + 1))

        for ((j=i+1; j<${#PENDING[@]}; j++)); do NEW_PENDING+=("${PENDING[$j]}"); done
        break
    done

    PENDING=("${NEW_PENDING[@]}")
    if [ $APPLIED_IN_PASS -eq 0 ]; then break; fi
done

write_section "결과"
if [ ${#APPLIED[@]} -gt 0 ]; then
    echo -e "\e[32m✅ [적용 완료 목록]\e[0m"
    for a in "${APPLIED[@]}"; do echo " - $a"; done
fi

if [ ${#PENDING[@]} -gt 0 ]; then
    echo -e "\e[33m⚠️ [미적용 목록] 선행 데이터가 부족합니다.\e[0m"
    for p in "${PENDING[@]}"; do
        echo " - $p"
        echo -e "\e[33m   사유: ${STUCK_REASONS[$p]}\e[0m"
    done
    [ "$DRY_RUN" = true ] && exit 0 || exit 2
fi

echo -e "\n\e[32m✅ [완료] 현재 시점: $(git log -1 --format='%cd (%h) %s')\e[0m"