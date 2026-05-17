#!/usr/bin/env bash
# =============================================================================
# Airbyte 커뮤니티 Oracle 소스 커스텀 커넥터 등록 (idempotent) — maxdl / FU-1
# ---------------------------------------------------------------------------
# 배경: Airbyte community 레지스트리의 Oracle 소스는 enterprise 전용
#       (`source-oracle-enterprise`) → OSS 에서 HTTP 403 entitlement.
# 해법(A안): 커뮤니티 `airbyte/source-oracle`(Docker Hub 공개, postgres/mssql 와
#       동일 라이선스 티어) 를 "커스텀 정의" 로 등록 → entitlement 게이트 우회
#       (custom 정의는 enterprise 플래그 비대상; isEntitled=true).
#
# 중요: Airbyte server 의 create_custom 엔드포인트는 kubectl port-forward 를
#       통한 큰 POST 에서 연결 리셋(HTTP 000)이 발생한다. 반드시 **클러스터
#       내부**에서 호출한다(아래 in-cluster curl Pod 사용).
#
# 사용법:  deploy/k8s/airbyte/register-oracle-connector.sh
# 사전:    kubectl 컨텍스트=maxdl, Airbyte(maxdl-ingest) 가동.
# =============================================================================
set -euo pipefail

NS="maxdl-ingest"
SVC="airbyte-airbyte-server-svc:8001"
WSID="a9096faa-970f-477b-9730-780a613592bb"   # maxdl 워크스페이스
IMG_REPO="airbyte/source-oracle"
IMG_TAG="0.5.8"                                # 커뮤니티 최신(2026-03). enterprise 아님
NAME="Oracle Community"

# instance-admin client → Bearer 토큰
CID="$(kubectl get secret airbyte-auth-secrets -n "$NS" -o jsonpath='{.data.instance-admin-client-id}' | base64 -d)"
CSEC="$(kubectl get secret airbyte-auth-secrets -n "$NS" -o jsonpath='{.data.instance-admin-client-secret}' | base64 -d)"

incurl() {  # in-cluster curl (port-forward 회피)
  kubectl run "abreg-$RANDOM" --rm -i --restart=Never \
    --image=curlimages/curl:8.11.1 -n "$NS" --timeout=90s -- "$@" 2>/dev/null \
    | grep -viE 'pods .* deleted|recorded in container|command prompt|press enter|^If you'
}

AT="$(incurl -s -X POST "http://$SVC/api/public/v1/applications/token" \
  -H 'Content-Type: application/json' \
  -d "{\"client_id\":\"$CID\",\"client_secret\":\"$CSEC\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"

# 이미 등록돼 있으면 skip(재실행 안전)
EXIST="$(incurl -s -X POST "http://$SVC/api/v1/source_definitions/list" \
  -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c "import sys,json;print(any(d.get('dockerRepository')=='$IMG_REPO' for d in json.load(sys.stdin)['sourceDefinitions']))")"
if [ "$EXIST" = "True" ]; then
  echo "= Oracle 커스텀 커넥터 이미 등록됨 — 건너뜀"
  exit 0
fi

RESP="$(incurl -s -X POST "http://$SVC/api/v1/source_definitions/create_custom" \
  -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
  -d "{\"workspaceId\":\"$WSID\",\"sourceDefinition\":{\"name\":\"$NAME\",\"dockerRepository\":\"$IMG_REPO\",\"dockerImageTag\":\"$IMG_TAG\",\"documentationUrl\":\"https://docs.airbyte.com/integrations/sources/oracle\"}}")"
echo "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print('+ 등록 완료 id=',d['sourceDefinitionId'],'enterprise=',d.get('enterprise'))"
