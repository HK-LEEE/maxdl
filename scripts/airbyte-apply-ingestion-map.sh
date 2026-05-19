#!/usr/bin/env bash
# =============================================================================
# airbyte-apply-ingestion-map.sh — ingestion-map.yaml → Airbyte 커넥션 멱등 적용
# -----------------------------------------------------------------------------
# config/ingestion-map.yaml 을 단일 권위로, 소스별 Airbyte 커넥션의 syncCatalog
# 를 yaml 에 수렴시킨다(드리프트 교정·클린 재구축 재현).
#   - yaml 에 있는 테이블만 selected=true + mode 매핑(merge/replica/append)
#   - yaml 에 없는 스트림(뷰 등)은 selected=false (예: maxapex v_* 6개 제거)
#   - yaml 에 있으나 커넥션에 없던 테이블 선택(예: maxtdoracle PRODUCTION_LOG)
#   - 커넥션 없으면 생성, 있으면 갱신. Airflow Variable airbyte_conn_<src> 세팅
#
# 전제(없으면 명시적 실패 — fallback/mock 없음):
#   - 소스(src-<name>)·목적지(dst-iceberg-bronze)가 이미 존재(자격/커넥터는
#     SealedSecret + register-oracle-connector.sh + 문서 절차로 선행 생성).
#   - 본 스크립트는 "커넥션 카탈로그 선택"의 IaC 화 담당(소스/목적지 프로비저닝
#     자체는 범위 밖 — ADD_NEW_DATABASE.md 1~3.1 절차).
#
# 사용:
#   scripts/airbyte-apply-ingestion-map.sh [옵션]
#     --api URL          Airbyte API base
#                        (기본 http://airbyte-airbyte-server-svc.maxdl-ingest:8001
#                         수동 실행 시 --api http://localhost:30081)
#     --map FILE         ingestion-map (기본 config/ingestion-map.yaml)
#     --workspace NAME   (기본 maxdl)
#     --only SRC         특정 소스만 (반복 가능)
#     --set-airflow-vars kubectl 로 airbyte_conn_<src> Variable 세팅
#     --no-provision     소스/목적지 프로비저닝 생략(커넥션 카탈로그만)
#     --dry-run          변경 없이 계획(선택/해제/모드 diff)만 출력
#
# 자격: 환경변수 AIRBYTE_CLIENT_ID/SECRET (airbyte-api 시크릿). 없으면 즉시 실패.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="http://airbyte-airbyte-server-svc.maxdl-ingest:8001"
MAP="$REPO_ROOT/config/ingestion-map.yaml"
WS_NAME="maxdl"
DRY=0
SET_VARS=0
NO_PROV=0
ONLY=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) API="$2"; shift 2;;
    --map) MAP="$2"; shift 2;;
    --workspace) WS_NAME="$2"; shift 2;;
    --only) ONLY+=("$2"); shift 2;;
    --set-airflow-vars) SET_VARS=1; shift;;
    --no-provision) NO_PROV=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "ERROR: 알 수 없는 옵션: $1" >&2; exit 2;;
  esac
done

command -v python3 >/dev/null || { echo "ERROR: python3 미설치" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "ERROR: PyYAML 필요" >&2; exit 1; }
[[ -f "$MAP" ]] || { echo "ERROR: map 없음: $MAP" >&2; exit 1; }

# 자격: env 우선, 없으면 airbyte-api 시크릿에서 조회
if [[ -z "${AIRBYTE_CLIENT_ID:-}" || -z "${AIRBYTE_CLIENT_SECRET:-}" ]]; then
  command -v kubectl >/dev/null || { echo "ERROR: 자격 env 없음 + kubectl 없음" >&2; exit 1; }
  AIRBYTE_CLIENT_ID="$(kubectl get secret airbyte-api -n maxdl-orchestrate -o jsonpath='{.data.AIRBYTE_CLIENT_ID}' | base64 -d)"
  AIRBYTE_CLIENT_SECRET="$(kubectl get secret airbyte-api -n maxdl-orchestrate -o jsonpath='{.data.AIRBYTE_CLIENT_SECRET}' | base64 -d)"
fi
[[ -n "$AIRBYTE_CLIENT_ID" && -n "$AIRBYTE_CLIENT_SECRET" ]] || { echo "ERROR: Airbyte 자격 비어있음" >&2; exit 1; }

export SEAL_API="$API" SEAL_MAP="$MAP" SEAL_WS="$WS_NAME" SEAL_DRY="$DRY"
export SEAL_SET_VARS="$SET_VARS" SEAL_NO_PROVISION="$NO_PROV"
export SEAL_ONLY="$(IFS=,; echo "${ONLY[*]:-}")"
export AIRBYTE_CLIENT_ID AIRBYTE_CLIENT_SECRET

python3 - <<'PY'
import os, sys, json, urllib.request, yaml

API   = os.environ["SEAL_API"].rstrip("/")
MAP   = yaml.safe_load(open(os.environ["SEAL_MAP"]))
WS    = os.environ["SEAL_WS"]
DRY   = os.environ["SEAL_DRY"] == "1"
ONLY  = {x for x in os.environ.get("SEAL_ONLY","").split(",") if x}

def _req(path, body, token=None, method="POST"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=180).read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"\nERROR {path} HTTP {e.code}: {e.read().decode()[:500]}\n")
        raise SystemExit(1)

# 토큰
tok = _req("/api/public/v1/applications/token",
           {"client_id": os.environ["AIRBYTE_CLIENT_ID"],
            "client_secret": os.environ["AIRBYTE_CLIENT_SECRET"]})["access_token"]

# 워크스페이스 (public API — v1 config 의 workspaces/list 는 토큰 스코프상 403)
wss = _req("/api/public/v1/workspaces", None, tok, method="GET").get("data", [])
ws = next((w for w in wss if w.get("name") == WS), None)
if not ws:
    raise SystemExit(f"ERROR: 워크스페이스 '{WS}' 없음")
wsid = ws["workspaceId"]

import subprocess, base64

def k8s_secret(name, ns):
    """K8s Secret → {key: 평문}. 없으면 None(예외 아님 — 호출부서 판단)."""
    p = subprocess.run(["kubectl", "get", "secret", name, "-n", ns, "-o", "json"],
                        capture_output=True, text=True)
    if p.returncode != 0:
        return None
    d = json.loads(p.stdout).get("data", {})
    return {k: base64.b64decode(v).decode() for k, v in d.items()}

def def_id(kind, repo_substr):
    """워크스페이스의 커넥터 정의에서 dockerRepository 매칭 ID 해석
    (인스턴스마다 ID 가 달라 이름 기준 — Oracle 커스텀 포함)."""
    ep = ("source_definitions" if kind == "source" else "destination_definitions")
    key = "sourceDefinitions" if kind == "source" else "destinationDefinitions"
    idk = "sourceDefinitionId" if kind == "source" else "destinationDefinitionId"
    r = _req(f"/api/v1/{ep}/list_for_workspace", {"workspaceId": wsid}, tok)
    for x in r.get(key, []):
        if repo_substr in (x.get("dockerRepository") or ""):
            return x[idk]
    raise SystemExit(f"ERROR: 커넥터 정의 미발견: {kind}/{repo_substr}")

def src_config(sdef, sec):
    """ingestion-map sources.<>.connector + src-db-* 시크릿 → 커넥터별 config
    (라이브 역추출 known-good 구조 기준 — 추측 배제)."""
    c = sdef["connector"]; host = sec["host"]; port = int(sec["port"])
    usr = sec["username"]; pw = sec["password"]
    if c == "source-postgres":
        return {"host": host, "port": port, "database": sec["database"],
                "username": usr, "password": pw, "ssl_mode": {"mode": "disable"},
                "tunnel_method": {"tunnel_method": "NO_TUNNEL"},
                "replication_method": {"method": "Standard"}}
    if c == "source-mssql":
        return {"host": host, "port": port, "database": sec["database"],
                "username": usr, "password": pw,
                "ssl_method": {"ssl_method": "unencrypted"},
                "tunnel_method": {"tunnel_method": "NO_TUNNEL"},
                "replication_method": {"method": "STANDARD"}}
    if c == "source-oracle":
        return {"host": host, "port": port, "username": usr, "password": pw,
                "encryption": {"encryption_method": "unencrypted"},
                "tunnel_method": {"tunnel_method": "NO_TUNNEL"},
                "connection_data": {"service_name": sec["serviceName"],
                                    "connection_type": "service_name"}}
    raise SystemExit(f"ERROR: 미지원 커넥터: {c}")

def dst_config(s3, pol):
    """seaweedfs-s3 시크릿(=secrets.env SSOT) + ingestion-map.catalog +
    polaris-airbyte → 목적지 config. endpoint/bucket 은 시크릿 단일출처
    (ingestion-map.destination.s3 의 endpoint/bucket 은 비권위·정보용 —
    개발/운영 전환은 secrets.env 값 교체만)."""
    D = MAP["destination"]; cat = D["catalog"]
    cu = cat["server_uri"].rstrip("/")
    bucket = s3["warehouseBucket"]
    return {"s3_endpoint": s3["endpoint"], "access_key_id": s3["accessKey"],
            "secret_access_key": s3["secretKey"], "s3_bucket_name": bucket,
            # region 은 Airbyte 커넥터 AWS enum 제약상 더미(SeaweedFS/외부S3
            # 무시) — 의도된 고정값(계획서 §5단계). SSOT 대상 아님.
            "s3_bucket_region": "us-east-1", "main_branch_name": "main",
            "warehouse_location": f"s3://{bucket}/{cat['warehouse']}",
            "catalog_type": {"catalog_type": "POLARIS", "scope": "PRINCIPAL_ROLE:ALL",
                "server_uri": cu, "oauth2_server_uri": f"{cu}/v1/oauth/tokens",
                "catalog_name": cat["warehouse"], "namespace": cat["warehouse"],
                "client_id": pol["client_id"], "client_secret": pol["client_secret"]}}

# --- 프로비저닝(소스 4종 + 목적지) — 멱등 ensure --------------------------
srcs  = _req("/api/v1/sources/list", {"workspaceId": wsid}, tok)["sources"]
dests = _req("/api/v1/destinations/list", {"workspaceId": wsid}, tok)["destinations"]
DEF = {}  # connector → definitionId (지연 해석·캐시)

if os.environ.get("SEAL_NO_PROVISION") != "1":
    for sname, sdef in MAP["sources"].items():
        if ONLY and sname not in ONLY:
            continue
        sec = k8s_secret(sdef["secret"], "maxdl-ingest")
        if sec is None:
            print(f"[{sname}] ERROR: 시크릿 '{sdef['secret']}' 없음 — 소스 프로비저닝 불가")
            raise SystemExit(1)
        cfg = src_config(sdef, sec)
        cur = next((s for s in srcs if s["name"] == f"src-{sname}"), None)
        if DRY:
            print(f"[{sname}] 소스 {'갱신' if cur else '생성'} (src-{sname}, {sdef['connector']})")
        elif cur:
            _req("/api/v1/sources/update",
                 {"sourceId": cur["sourceId"], "name": cur["name"],
                  "connectionConfiguration": cfg}, tok)
            print(f"[{sname}] 소스 갱신 ✓")
        else:
            did = DEF.setdefault(sdef["connector"],
                                 def_id("source", sdef["connector"]))
            _req("/api/v1/sources/create",
                 {"workspaceId": wsid, "sourceDefinitionId": did,
                  "name": f"src-{sname}", "connectionConfiguration": cfg}, tok)
            print(f"[{sname}] 소스 생성 ✓")

    # 목적지: polaris-airbyte 시크릿 필요. 없고 이미 존재하면 자격 보존(스킵).
    dst0 = next((d for d in dests if d["name"] == "dst-iceberg-bronze"), None)
    s3sec  = k8s_secret("seaweedfs-s3", "maxdl-ingest")
    polsec = k8s_secret("polaris-airbyte", "maxdl-ingest")
    if polsec and s3sec:
        dcfg = dst_config(s3sec, polsec)
        if DRY:
            print(f"[목적지] {'갱신' if dst0 else '생성'} (dst-iceberg-bronze)")
        elif dst0:
            _req("/api/v1/destinations/update",
                 {"destinationId": dst0["destinationId"], "name": dst0["name"],
                  "connectionConfiguration": dcfg}, tok)
            print("[목적지] 갱신 ✓")
        else:
            did = def_id("destination", "destination-s3-data-lake")
            _req("/api/v1/destinations/create",
                 {"workspaceId": wsid, "destinationDefinitionId": did,
                  "name": "dst-iceberg-bronze", "connectionConfiguration": dcfg}, tok)
            print("[목적지] 생성 ✓")
    elif dst0:
        print("[목적지] polaris-airbyte 시크릿 없음 + 목적지 기존 존재 "
              "→ 자격 보존(스킵). 클린 재구축은 catalog-bootstrap 이 생성.")
    else:
        raise SystemExit("ERROR: 목적지 부재 + polaris-airbyte 시크릿 없음 — "
                         "catalog-bootstrap(클린 재구축) 또는 운영자 1회 주입 필요")

# 프로비저닝 후 최신 목록 재조회
dests = _req("/api/v1/destinations/list", {"workspaceId": wsid}, tok)["destinations"]
dst = next((d for d in dests if d["name"] == "dst-iceberg-bronze"), None)
if not dst:
    raise SystemExit("ERROR: 목적지 'dst-iceberg-bronze' 없음")
dstid = dst["destinationId"]
srcs = _req("/api/v1/sources/list", {"workspaceId": wsid}, tok)["sources"]
conns = _req("/api/v1/web_backend/connections/list", {"workspaceId": wsid}, tok)["connections"]

def mode_cfg(t):
    """yaml 테이블 항목 → Airbyte stream config 의 모드 관련 필드."""
    md = MAP["modes"][t["mode"]]
    cfg = {"syncMode": md["syncMode"], "destinationSyncMode": md["destinationSyncMode"],
           "cursorField": [], "primaryKey": []}
    if "cursorField" in md.get("requires", []):
        cfg["cursorField"] = [t["cursorField"]]
    if "primaryKey" in md.get("requires", []):
        cfg["primaryKey"] = [[c] for c in t["primaryKey"]]
    return cfg

rc = 0
for sname, sdef in MAP["sources"].items():
    if ONLY and sname not in ONLY:
        continue
    src = next((s for s in srcs if s["name"] == f"src-{sname}"), None)
    if not src:
        print(f"[{sname}] ERROR: 소스 'src-{sname}' 없음 — 선행 생성 필요(스킵)")
        rc = 1; continue
    srcid = src["sourceId"]

    # yaml 기대 테이블: (namespace, name) → 항목
    want = {}
    for t in sdef["tables"]:
        sch, _, tb = t["name"].partition(".")
        want[(sch, tb)] = t

    # 소스 스키마 discover (스트림 정의 원천 — 특히 커넥션에 없던 신규 테이블)
    disc = _req("/api/v1/sources/discover_schema",
                {"sourceId": srcid, "disable_cache": True}, tok)
    disc_streams = {((s["stream"].get("namespace") or ""), s["stream"]["name"]): s
                    for s in disc["catalog"]["streams"]}

    # 기존 커넥션의 현재 syncCatalog = 라이브 진실(드리프트 비교 기준)
    conn = next((c for c in conns if c["name"] == f"conn-{sname}"), None)
    cur = {}
    if conn:
        full = _req("/api/v1/web_backend/connections/get",
                    {"connectionId": conn["connectionId"],
                     "withRefreshedCatalog": False}, tok)
        for s in full.get("syncCatalog", {}).get("streams", []):
            k = ((s["stream"].get("namespace") or ""), s["stream"]["name"])
            cur[k] = s
    cur_selected = {k for k, s in cur.items() if s["config"].get("selected")}

    # 대상 스트림 풀 = 기존 커넥션 ∪ discover (정의는 기존 우선, 신규는 discover)
    pool = dict(disc_streams); pool.update(cur)

    found, streams_out = set(), []
    for key, st in pool.items():
        ns, nm = key
        base = cur.get(key, disc_streams.get(key, st))
        cfg = dict(base["config"])
        cfg["aliasName"] = nm
        for k, v in (("suggested", False), ("includeFiles", False),
                     ("fieldSelectionEnabled", False), ("selectedFields", []),
                     ("hashedFields", []), ("mappers", [])):
            cfg.setdefault(k, v)
        if key in want:
            cfg.update(mode_cfg(want[key])); cfg["selected"] = True
            found.add(key)
        else:
            cfg["selected"] = False
        out = dict(base); out["config"] = cfg
        streams_out.append(out)

    missing = [f"{a}.{b}" for (a, b) in want if (a, b) not in found]
    if missing:
        print(f"[{sname}] ERROR: yaml 테이블이 소스 스키마에 없음: {missing}")
        rc = 1; continue

    target = set(want)
    add  = sorted(f"{a}.{b}" for a, b in (target - cur_selected))
    drop = sorted(f"{a}.{b}" for a, b in (cur_selected - target))
    chg  = sorted(f"{a}.{b}" for a, b in (target & cur_selected)
                  if cur[(a, b)]["config"].get("syncMode")
                  != MAP["modes"][want[(a, b)]["mode"]]["syncMode"])
    print(f"[{sname}] {'신규커넥션' if not conn else '갱신'} "
          f"| 라이브선택 {len(cur_selected)} → 목표 {len(target)} "
          f"| +선택 {len(add)} -해제 {len(drop)} ~모드변경 {len(chg)}")
    if drop: print(f"   - 해제: {', '.join(drop)}")
    if add and conn: print(f"   + 선택: {', '.join(add)}")
    if chg: print(f"   ~ 모드변경: {', '.join(chg)}")

    if DRY:
        continue

    payload = {
        "name": f"conn-{sname}", "sourceId": srcid, "destinationId": dstid,
        "namespaceDefinition": "customformat",
        "namespaceFormat": sdef.get("bronzeNamespace", sname),
        "prefix": "", "scheduleType": "manual", "status": "active",
        "syncCatalog": {"streams": streams_out},
    }
    if conn:
        payload["connectionId"] = conn["connectionId"]
        res = _req("/api/v1/web_backend/connections/update", payload, tok)
    else:
        res = _req("/api/v1/web_backend/connections/create", payload, tok)
    cid = res["connectionId"]
    print(f"   ✓ connectionId={cid}")

    if os.environ.get("SEAL_SET_VARS") == "1":
        import subprocess
        p = subprocess.run(
            ["kubectl", "exec", "-n", "maxdl-orchestrate",
             "deploy/airflow-scheduler", "--",
             "airflow", "variables", "set", f"airbyte_conn_{sname}", cid],
            capture_output=True, text=True)
        print(f"   Airflow Var airbyte_conn_{sname} <- {cid}"
              + ("" if p.returncode == 0 else f"  (실패: {p.stderr.strip()[:120]})"))

sys.exit(rc)
PY