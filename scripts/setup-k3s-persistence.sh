#!/usr/bin/env bash
# =============================================================================
# setup-k3s-persistence.sh — 메타DB PVC 를 호스트 폴더에 영속 고정 (실 k3s)
# -----------------------------------------------------------------------------
# 전용 디스크 대신 **지정 폴더**(기본 = 레포 하위 .maxdl-pv)를 local-path
# 저장경로로 삼고, maxdl-retain(Retain) 을 default SC 로 승격한다. 멱등.
# helmfile 1단계 presync 가 MAXDL_PERSIST=1 일 때만 호출(opt-in) →
# 라이브 k3d(미설정)는 무영향, 폐쇄망/실k3s(설정 시)는 자동.
#
# 동작:
#   1) $MAXDL_PV_DIR 생성(기본 <repo>/.maxdl-pv) — 호스트 영속 폴더
#   2) kube-system local-path-config 의 경로 → $MAXDL_PV_DIR (멱등)
#   3) local-path-provisioner 재기동
#   4) maxdl-retain SC apply + default 승격(내장 local-path default 해제)
#   → 이후 모든 PVC 가 maxdl-retain(Retain·$MAXDL_PV_DIR) 사용
#
# 환경변수:
#   MAXDL_PV_DIR   영속 폴더(기본 "<repo>/.maxdl-pv"). **이 호스트의 실경로**
#                  (실 k3s 는 호스트 직접; k3d 는 노드에 bind-mount 된 경로
#                   여야 함 — k3d 면 본 스크립트 비대상)
# 주의: 폴더가 레포 내부면 .gitignore 필수(DB 데이터·비밀 — 커밋 금지).
#       전용 디스크 아님 → 격리/쿼터 없음, 디스크 용량 충분히 확보.
#       reclaimPolicy=Retain → PVC 삭제해도 폴더 잔존(고의·수동정리).
#       local-path = 노드 종속(단일노드 가정).
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PV_DIR="${MAXDL_PV_DIR:-$REPO/.maxdl-pv}"
command -v kubectl >/dev/null || { echo "ERROR: kubectl 필요" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 필요" >&2; exit 1; }

echo "= 영속 폴더: $PV_DIR"
mkdir -p "$PV_DIR"

# k3s 클러스터 식별(local-path-config 존재). 없으면 비대상(안전 종료).
if ! kubectl -n kube-system get configmap local-path-config >/dev/null 2>&1; then
  echo "= kube-system/local-path-config 없음 — 본 클러스터 비대상, 건너뜀"
  exit 0
fi

# 2) local-path-config 경로 재지정(멱등) — 임베디드 JSON 안전 치환
CUR="$(kubectl -n kube-system get configmap local-path-config -o json)"
NEW="$(PV_DIR="$PV_DIR" python3 - "$CUR" <<'PY'
import os, sys, json
cm = json.loads(sys.argv[1]); pv = os.environ["PV_DIR"]
cfg = json.loads(cm["data"]["config.json"])
cfg["nodePathMap"] = [{"node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
                       "paths": [pv]}]
cm2 = {"apiVersion": "v1", "kind": "ConfigMap",
       "metadata": {"name": "local-path-config", "namespace": "kube-system"},
       "data": dict(cm["data"], **{"config.json": json.dumps(cfg, indent=2)})}
print(json.dumps(cm2))
PY
)"
echo "$NEW" | kubectl apply -f - >/dev/null
kubectl -n kube-system rollout restart deploy local-path-provisioner >/dev/null 2>&1 || true
echo "= local-path-config → $PV_DIR (provisioner 재기동)"

# 3) maxdl-retain SC + default 승격(내장 local-path default 해제)
kubectl apply -f "$REPO/deploy/k8s/storageclass-retain.yaml" >/dev/null
kubectl annotate sc local-path \
  storageclass.kubernetes.io/is-default-class- --overwrite >/dev/null 2>&1 || true
kubectl annotate sc maxdl-retain \
  storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
echo "= default SC = maxdl-retain (Retain). 이후 PVC 는 $PV_DIR 에 영속."
echo "  검증: kubectl get sc | grep '(default)'  →  maxdl-retain"
echo "  백업 대상: $PV_DIR  (+ 외부 SeaweedFS)"
