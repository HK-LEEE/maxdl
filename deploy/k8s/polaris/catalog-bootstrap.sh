#!/usr/bin/env bash
# =============================================================================
# Polaris 카탈로그 부트스트랩 (idempotent)
# - bronze/silver/gold 3개 카탈로그를 SeaweedFS S3(공유, 전용 버킷)에 연결.
# - STS/vended-credential 미지원(SeaweedFS) → stsUnavailable=true + path-style.
#   서버 정적 자격증명(charts/polaris values.storage.secret=seaweedfs-s3) 사용.
# - root 자격증명은 K8s SealedSecret(polaris-bootstrap)에서 조회(평문 미보관).
# - 이미 존재하는 카탈로그는 건너뜀(재실행 안전).
#
# 사용법:  deploy/k8s/polaris/catalog-bootstrap.sh
# 사전:    kubectl 컨텍스트=maxdl, Polaris NodePort 30181 접근 가능.
# =============================================================================
set -euo pipefail

NS="maxdl-catalog"
POLARIS="http://localhost:30181"
WAREHOUSE_BUCKET="maxdl-warehouse"
REGION="kr-dw-pt-001"
S3_ENDPOINT="http://host.k3d.internal:8333"   # 클러스터→호스트 SeaweedFS S3
LAYERS=(bronze silver gold)

# --- root 자격증명 조회 (SealedSecret 복호화본) ---
RS="$(kubectl get secret polaris-bootstrap -n "$NS" -o jsonpath='{.data.clientSecret}' | base64 -d)"
CID="$(kubectl get secret polaris-bootstrap -n "$NS" -o jsonpath='{.data.clientId}'   | base64 -d)"

# --- OAuth2 client-credentials 토큰 발급 ---
AT="$(curl -s --max-time 10 -X POST "$POLARIS/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d "client_id=$CID" -d "client_secret=$RS" \
  -d 'scope=PRINCIPAL_ROLE:ALL' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"
[ -n "$AT" ] || { echo "ERROR: 토큰 발급 실패"; exit 1; }

# --- 기존 카탈로그 목록 ---
EXISTING="$(curl -s --max-time 10 -H "Authorization: Bearer $AT" \
  "$POLARIS/api/management/v1/catalogs" \
  | python3 -c 'import sys,json;print(" ".join(c["name"] for c in json.load(sys.stdin)["catalogs"]))')"

for L in "${LAYERS[@]}"; do
  if echo " $EXISTING " | grep -q " $L "; then
    echo "= $L : 이미 존재 — 건너뜀"
    continue
  fi
  BASE="s3://$WAREHOUSE_BUCKET/$L"
  BODY="$(python3 - "$L" "$BASE" "$REGION" "$S3_ENDPOINT" <<'PY'
import json,sys
L,base,region,ep=sys.argv[1:5]
print(json.dumps({"catalog":{"name":L,"type":"INTERNAL",
 "properties":{"default-base-location":base},
 "storageConfigInfo":{"storageType":"S3","allowedLocations":[base],
   "roleArn":"arn:aws:iam::000000000000:role/polaris","region":region,
   "endpoint":ep,"endpointInternal":ep,
   "pathStyleAccess":True,"stsUnavailable":True}}}))
PY
)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -X POST "$POLARIS/api/management/v1/catalogs" \
    -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "$BODY")"
  [ "$CODE" = "201" ] && echo "+ $L : 생성 완료 ($BASE)" \
                       || { echo "ERROR: $L 생성 실패 HTTP=$CODE"; exit 1; }
done

# --- 모든 카탈로그에 대해 권한/기능 보정 (재실행 안전) ---
# (1) catalog_admin 카탈로그롤에 CATALOG_MANAGE_CONTENT(테이블 drop/purge 포함) 부여
# (2) drop-with-purge 기능 활성화(Trino DROP TABLE / Airbyte 목적지 정리 필수)
# 미적용 시: Trino DROP TABLE 실패, Airbyte Iceberg 목적지 check 실패.
for L in "${LAYERS[@]}"; do
  curl -s -o /dev/null -X PUT -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
    "$POLARIS/api/management/v1/catalogs/$L/catalog-roles/catalog_admin/grants" \
    -d '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}' || true
  CUR="$(curl -s -H "Authorization: Bearer $AT" "$POLARIS/api/management/v1/catalogs/$L")"
  PUTBODY="$(CUR="$CUR" python3 -c '
import os,json
c=json.loads(os.environ["CUR"]); p=dict(c.get("properties") or {})
p["polaris.config.drop-with-purge.enabled"]="true"
print(json.dumps({"currentEntityVersion":c["entityVersion"],"properties":p}))')"
  curl -s -o /dev/null -X PUT -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
    "$POLARIS/api/management/v1/catalogs/$L" -d "$PUTBODY" || true
  echo "= $L : CATALOG_MANAGE_CONTENT + drop-with-purge 보정 적용"
done
echo "Polaris 카탈로그 부트스트랩 완료."
