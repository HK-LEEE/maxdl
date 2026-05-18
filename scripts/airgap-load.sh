#!/usr/bin/env bash
# =============================================================================
# airgap-load.sh — 이미지 번들을 노드 컨테이너 런타임에 적재 (폐쇄망, 노드별)
# -----------------------------------------------------------------------------
# airgap-bundle.sh 산출 번들을 운영 노드의 containerd(k8s.io 네임스페이스)에
# import 한다. **클러스터의 모든 노드에서 1회씩 실행**(KubernetesExecutor 의
# 태스크 pod 가 어느 노드에나 스케줄되므로 누락 노드 = ImagePullBackOff).
#
# 기본은 k3s 내장 ctr 사용(재기동 불필요·즉시 반영).
#
# 사용(각 노드에서, root 권한):
#   sudo scripts/airgap-load.sh <번들.tar|.tar.gz> [옵션]
#     --ctr "CMD"     import 명령 override
#                     (기본 'k3s ctr'; 비 k3s: --ctr "ctr -n k8s.io")
#     --auto-dir      ctr import 대신 k3s 자동 import 디렉토리에 배치
#                     (/var/lib/rancher/k3s/agent/images/ → k3s 재기동 시 로드)
#     --skip-verify   sha256 검증 생략(.sha256 동봉 시 기본 검증)
#
# 원칙: fallback 없음 — 검증/적재 실패 시 즉시 비정상 종료.
# =============================================================================
set -euo pipefail

BUNDLE="${1:-}"; shift || true
[[ -n "${BUNDLE:-}" && -f "$BUNDLE" ]] || { echo "ERROR: 번들 경로 필요(존재 X): '${BUNDLE:-}'" >&2; exit 1; }

CTR_CMD="k3s ctr"
AUTO_DIR=0
SKIP_VERIFY=0
K3S_IMG_DIR="/var/lib/rancher/k3s/agent/images"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctr) CTR_CMD="$2"; shift 2;;
    --auto-dir) AUTO_DIR=1; shift;;
    --skip-verify) SKIP_VERIFY=1; shift;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "ERROR: 알 수 없는 옵션: $1" >&2; exit 2;;
  esac
done

# sha256 검증(동봉 시)
if [[ "$SKIP_VERIFY" == 0 && -f "${BUNDLE}.sha256" ]]; then
  echo "sha256 검증..."
  ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" ) \
    || { echo "ERROR: 체크섬 불일치 — 전송 손상" >&2; exit 1; }
fi

# 방식 A: k3s 자동 import 디렉토리 배치 (재기동 시 로드)
if [[ "$AUTO_DIR" == 1 ]]; then
  [[ -d "$K3S_IMG_DIR" ]] || mkdir -p "$K3S_IMG_DIR"
  cp -v "$BUNDLE" "$K3S_IMG_DIR/"
  echo "→ 배치 완료. k3s 재기동 시 자동 로드:"
  echo "   sudo systemctl restart k3s   (서버) / k3s-agent (에이전트)"
  exit 0
fi

# 방식 B(기본): ctr 즉시 import (재기동 불필요)
echo "import → $CTR_CMD images import ($BUNDLE)"
case "$BUNDLE" in
  *.tar.gz|*.tgz) gunzip -c "$BUNDLE" | $CTR_CMD images import - ;;
  *.tar)          $CTR_CMD images import "$BUNDLE" ;;
  *) echo "ERROR: 지원 안 함 확장자(.tar/.tar.gz): $BUNDLE" >&2; exit 1;;
esac

# 검증: import 된 이미지 수 출력
N=$($CTR_CMD images ls -q 2>/dev/null | wc -l || echo "?")
echo "완료 — 현재 노드 containerd 이미지 수: $N"
echo "(모든 노드에서 1회씩 실행했는지 확인 필요)"
