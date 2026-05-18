#!/usr/bin/env bash
# =============================================================================
# airgap-bundle.sh — 스택 전 이미지를 단일 번들로 묶음 (온라인 빌드 머신)
# -----------------------------------------------------------------------------
# 폐쇄망 운영 이관용. 이미지를 하나씩이 아니라 한 번에 추출·pull·save 한다.
#
# 이미지 열거 소스(합집합·중복제거):
#   1) 라이브 클러스터 pod 의 모든 image (containers+initContainers)
#      → 커스텀 Airflow(maxdl/airflow:fu3) 및 서브차트 이미지까지 포함
#   2) deploy/airgap/extra-images.txt
#      → Airbyte 커넥터 등 런타임 동적 pull(열거 누락분) 강제 포함
#   3) (선택) --helmfile : helmfile template 렌더의 image 라인
#
# 출력: 단일 tar 번들 + 이미지 manifest(images.txt) + sha256.
#
# 사용:
#   scripts/airgap-bundle.sh [옵션]
#     --out FILE        번들 경로 (기본 dist/maxdl-airgap-images.tar)
#     --extra FILE      추가 이미지 목록 (기본 deploy/airgap/extra-images.txt)
#     --helmfile        helmfile template 도 열거 소스로 추가
#     --no-cluster      라이브 클러스터 열거 생략(extra/helmfile 만)
#     --gzip            번들 gzip 압축(.tar.gz)
#     --dry-run         pull/save 없이 최종 이미지 목록만 출력
#
# 원칙: fallback/mock 없음 — pull 실패 시 즉시 중단(불완전 번들 금지).
#       멀티아키: 이 머신 아키텍처 이미지로만 save(운영 노드 아키 일치 전제).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/dist/maxdl-airgap-images.tar"
EXTRA="$REPO_ROOT/deploy/airgap/extra-images.txt"
USE_HELMFILE=0
USE_CLUSTER=1
GZIP=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --extra) EXTRA="$2"; shift 2;;
    --helmfile) USE_HELMFILE=1; shift;;
    --no-cluster) USE_CLUSTER=0; shift;;
    --gzip) GZIP=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "ERROR: 알 수 없는 옵션: $1" >&2; exit 2;;
  esac
done

command -v docker >/dev/null || { echo "ERROR: docker 미설치(빌드 머신)" >&2; exit 1; }

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# 1) 라이브 클러스터 pod 이미지 (containers + initContainers)
if [[ "$USE_CLUSTER" == 1 ]]; then
  command -v kubectl >/dev/null || { echo "ERROR: kubectl 미설치(--no-cluster 로 생략 가능)" >&2; exit 1; }
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' >> "$TMP" 2>/dev/null || true
fi

# 2) 추가 이미지 목록(런타임 동적 pull 분 — Airbyte 커넥터 등)
if [[ -f "$EXTRA" ]]; then
  grep -vE '^\s*#|^\s*$' "$EXTRA" >> "$TMP" || true
fi

# 3) (선택) helmfile 렌더 이미지
if [[ "$USE_HELMFILE" == 1 ]]; then
  command -v helmfile >/dev/null || { echo "ERROR: helmfile 미설치" >&2; exit 1; }
  ( cd "$REPO_ROOT" && helmfile template 2>/dev/null ) \
    | grep -oE '^\s*image:\s*"?[^"]+' | sed -E 's/^\s*image:\s*"?//' >> "$TMP" || true
fi

# 정규화: 공백/따옴표 제거, 빈 줄·중복 제거, 정렬
mapfile -t IMAGES < <(sed -E 's/[" ]//g' "$TMP" | grep -vE '^$' | sort -u)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  echo "ERROR: 열거된 이미지 0개 — 소스(클러스터/extra/helmfile) 확인" >&2; exit 1
fi

echo "=== 번들 대상 이미지 ${#IMAGES[@]}개 ==="
printf '%s\n' "${IMAGES[@]}"

if [[ "$DRY" == 1 ]]; then echo "--dry-run: pull/save 생략"; exit 0; fi

# 로컬에 있으면 pull 생략(커스텀/로컬빌드 이미지 = maxdl/airflow 등은 레지스트리
# 에 없음 — air-gap 의 핵심). 없을 때만 pull. 실패 즉시 중단(불완전 번들 금지).
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "local: $img"
  else
    echo "pull: $img"
    docker pull -q "$img" >/dev/null || { echo "ERROR: pull 실패: $img" >&2; exit 1; }
  fi
done

mkdir -p "$(dirname "$OUT")"
MANIFEST="${OUT%.tar}.images.txt"
printf '%s\n' "${IMAGES[@]}" > "$MANIFEST"

echo "save → $OUT (이미지 ${#IMAGES[@]}개)"
docker save "${IMAGES[@]}" -o "$OUT"

if [[ "$GZIP" == 1 ]]; then
  gzip -f "$OUT"; OUT="${OUT}.gz"
fi

sha256sum "$OUT" > "${OUT}.sha256"
echo "완료:"
echo "  번들    : $OUT"
echo "  목록    : $MANIFEST"
echo "  체크섬  : ${OUT}.sha256"
echo "→ 폐쇄망 각 노드로 전송 후 scripts/airgap-load.sh 실행"
