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
# SSOT 일원화: 버킷/리전/엔드포인트는 seaweedfs-s3 시크릿(=secrets.env)
# 단일출처 파생. 개발=내부 Docker SeaweedFS, 운영=폐쇄망 외부 S3 —
# secrets.env 값만 교체하면 코드 변경 없이 전환(하드코딩 제거).
_s3() { kubectl get secret seaweedfs-s3 -n "$NS" -o jsonpath="{.data.$1}" | base64 -d; }
WAREHOUSE_BUCKET="$(_s3 warehouseBucket)"
REGION="$(_s3 region)"
S3_ENDPOINT="$(_s3 endpoint)"
[ -n "$WAREHOUSE_BUCKET" ] && [ -n "$REGION" ] && [ -n "$S3_ENDPOINT" ] \
  || { echo "ERROR: seaweedfs-s3 시크릿에서 bucket/region/endpoint 미해석"; exit 1; }
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
# --- FU-2 최소권한 RBAC 배선 (재실행 안전, 결정적) ---
# principal 자체(자격증명 비재현)는 1회 부트스트랩 + SealedSecret 봉인:
#   POST /principals {name}  → credentials(clientId:clientSecret) 캡처 →
#   polaris-oauth(maxdl-query, svc-trino) / Airbyte 목적지 config(svc-airbyte)
# 아래는 결정적 요소(역할/권한/할당)만 idempotent 적용한다.
PR_API="$POLARIS/api/management/v1"
ensure_pr(){ curl -s -o /dev/null -X POST "$PR_API/principal-roles" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "{\"principalRole\":{\"name\":\"$1\"}}"; }
ensure_cr(){ curl -s -o /dev/null -X POST "$PR_API/catalogs/$1/catalog-roles" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "{\"catalogRole\":{\"name\":\"$2\"}}"; }
grant(){ curl -s -o /dev/null -X PUT "$PR_API/catalogs/$1/catalog-roles/$2/grants" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "{\"grant\":{\"type\":\"catalog\",\"privilege\":\"$3\"}}"; }
bind(){ curl -s -o /dev/null -X PUT "$PR_API/principal-roles/$1/catalog-roles/$2" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d "{\"catalogRole\":{\"name\":\"$3\"}}"; }

ensure_pr pr-trino; ensure_pr pr-airbyte

# --- principal 자격 캡처(클린 재구축 재현) ---------------------------------
# Polaris 는 principal 생성 시 credentials(clientId:clientSecret)를 1회만 반환
# (이후 평문 비재현, rotate 는 별도 권한). 따라서 "신규 생성(201)일 때만"
# 자격을 캡처해 K8s Secret 으로 영속한다. 이미 존재(409)면 기존 Secret 신뢰
# 하고 건너뜀(동작 중 자격을 깨지 않음 — 멱등·안전).
#   svc-trino   → polaris-oauth(maxdl-query) key 'credential'  (Trino 소비)
#   svc-airbyte → polaris-airbyte(maxdl-ingest) client_id/secret (목적지 소비)
ensure_principal_secret(){   # $1=principal $2=secretNS $3=secretName $4=fmt(credential|split)
  local P="$1" SNS="$2" SN="$3" FMT="$4"
  if kubectl get secret "$SN" -n "$SNS" >/dev/null 2>&1; then
    echo "= principal $P : Secret $SN 존재 — 자격 캡처 건너뜀(멱등)"; return 0; fi
  local RESP CODE
  RESP="$(curl -s -w '\n%{http_code}' -X POST "$PR_API/principals" \
    -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
    -d "{\"principal\":{\"name\":\"$P\"}}")"
  CODE="$(printf '%s' "$RESP" | tail -1)"
  if [ "$CODE" != "201" ]; then
    echo "= principal $P : 생성 HTTP=$CODE (기존 추정) — 자격 비재현, Secret 미생성"
    echo "  ⚠ 클린 재구축이 아닌 환경: $SN 을 운영자가 1회 주입 필요(문서 참조)"
    return 0; fi
  printf '%s' "$RESP" | sed '$d' | CRED_NS="$SNS" CRED_SN="$SN" CRED_FMT="$FMT" \
    python3 - "$P" <<'PY'
import os,sys,json,base64,subprocess
P=sys.argv[1]; body=json.load(sys.stdin)
cr=body.get("credentials",body)
cid=cr.get("clientId"); csec=cr.get("clientSecret")
if not cid or not csec: sys.exit(f"ERROR: {P} 자격 파싱 실패")
ns,sn,fmt=os.environ["CRED_NS"],os.environ["CRED_SN"],os.environ["CRED_FMT"]
if fmt=="credential": data={"credential": f"{cid}:{csec}"}
else: data={"client_id":cid,"client_secret":csec}
man={"apiVersion":"v1","kind":"Secret","type":"Opaque",
 "metadata":{"name":sn,"namespace":ns},
 "data":{k:base64.b64encode(v.encode()).decode() for k,v in data.items()}}
p=subprocess.run(["kubectl","apply","-f","-"],input=json.dumps(man),
                  text=True,capture_output=True)
print(("  + " if p.returncode==0 else "  ERROR ")+p.stdout.strip()+p.stderr.strip())
sys.exit(p.returncode)
PY
  echo "= principal $P : 신규 자격 캡처 → Secret $SN ($SNS)"
}
ensure_principal_secret svc-trino   maxdl-query  polaris-oauth   credential
ensure_principal_secret svc-airbyte maxdl-ingest polaris-airbyte split
# principal ↔ principal-role 할당(멱등)
curl -s -o /dev/null -X PUT "$PR_API/principals/svc-trino/principal-roles" \
  -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
  -d '{"principalRole":{"name":"pr-trino"}}' || true
curl -s -o /dev/null -X PUT "$PR_API/principals/svc-airbyte/principal-roles" \
  -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
  -d '{"principalRole":{"name":"pr-airbyte"}}' || true

# svc-airbyte: bronze 만 manage(쓰기/생성/드롭)
ensure_cr bronze cr-bronze-rw; grant bronze cr-bronze-rw CATALOG_MANAGE_CONTENT
bind pr-airbyte bronze cr-bronze-rw
# svc-trino: bronze 읽기 전용 + silver/gold manage
ensure_cr bronze cr-bronze-ro
# VIEW_* 부재 시 Trino "Failed to list views" → 테이블 해석 전체 실패(검증됨)
for P in TABLE_READ_DATA TABLE_LIST TABLE_READ_PROPERTIES NAMESPACE_LIST NAMESPACE_READ_PROPERTIES CATALOG_READ_PROPERTIES VIEW_LIST VIEW_READ_PROPERTIES VIEW_FULL_METADATA; do
  grant bronze cr-bronze-ro "$P"
done
bind pr-trino bronze cr-bronze-ro
# 유지보수 DAG(maintain_iceberg: compaction/expire_snapshots/orphan) 가
# bronze 도 청소하려면 RW 필요 → cr-bronze-rw 도 함께 바인드(read role
# 과 병존, Polaris grants 합산). 사용자별 차단은 Trino file-based ACL
# 이 담당(svc-dbt 외 bronze INSERT/DELETE 불가). docs/MAINTENANCE.md.
bind pr-trino bronze cr-bronze-rw
for L in silver gold; do
  ensure_cr "$L" cr-rw; grant "$L" cr-rw CATALOG_MANAGE_CONTENT; bind pr-trino "$L" cr-rw
done
echo "= FU-2 RBAC(pr-trino/pr-airbyte 역할·권한·할당) 보정 적용"
echo "  (principal 자격: 신규 생성 시 캡처→Secret 영속, 기존이면 멱등 스킵)"
echo "Polaris 카탈로그 부트스트랩 완료."
