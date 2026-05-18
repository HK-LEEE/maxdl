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
ONLY=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) API="$2"; shift 2;;
    --map) MAP="$2"; shift 2;;
    --workspace) WS_NAME="$2"; shift 2;;
    --only) ONLY+=("$2"); shift 2;;
    --set-airflow-vars) SET_VARS=1; shift;;
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
export SEAL_SET_VARS="$SET_VARS"
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

# 목적지(yaml destination → dst-iceberg-bronze 이름 규약)
dests = _req("/api/v1/destinations/list", {"workspaceId": wsid}, tok)["destinations"]
dst = next((d for d in dests if d["name"] == "dst-iceberg-bronze"), None)
if not dst:
    raise SystemExit("ERROR: 목적지 'dst-iceberg-bronze' 없음 — 소스/목적지 선행 생성 필요")
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