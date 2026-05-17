#!/usr/bin/env bash
# =============================================================================
# seal-secret.sh — 평문 K8s Secret 을 SealedSecret 으로 봉인
# - 평문 Secret 은 절대 git 에 커밋하지 않는다. 이 스크립트로 봉인한 결과
#   (SealedSecret) 만 deploy/ 하위에 커밋한다.
# - 사전 조건: kubeseal CLI, maxdl-system 의 sealed-secrets-controller 실행 중.
#
# 사용법:
#   scripts/seal-secret.sh <평문secret.yaml> <출력sealed.yaml>
# 예:
#   scripts/seal-secret.sh /tmp/src-db-maxplatform.yaml \
#       deploy/k8s/sealed/src-db-maxplatform.sealed.yaml
# =============================================================================
set -euo pipefail

PLAIN="${1:?평문 Secret YAML 경로 필요}"      # 입력: 평문 Secret 매니페스트
OUT="${2:?출력 SealedSecret YAML 경로 필요}"   # 출력: 봉인된 SealedSecret
CONTROLLER_NS="maxdl-system"                    # 컨트롤러 네임스페이스
CONTROLLER_NAME="sealed-secrets-controller"     # 컨트롤러 서비스명

# kubeseal 존재 확인 (없으면 즉시 실패 — fallback 없음)
command -v kubeseal >/dev/null || { echo "ERROR: kubeseal 미설치"; exit 1; }

mkdir -p "$(dirname "$OUT")"

# 클러스터의 컨트롤러 공개키로 봉인 (scope=strict: 네임스페이스+이름 고정)
kubeseal \
  --controller-namespace "$CONTROLLER_NS" \
  --controller-name "$CONTROLLER_NAME" \
  --format yaml \
  < "$PLAIN" > "$OUT"

echo "봉인 완료: $OUT"
