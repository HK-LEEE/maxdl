#!/usr/bin/env bash
# =============================================================================
# dbt-gen-models.sh — ingestion-map.yaml → dbt staging/Silver 모델 결정적 생성
# -----------------------------------------------------------------------------
# staging/intermediate 모델은 100% 기계적 템플릿(테이블명·mode·cursor·PK 만
# 다름). 손으로 짤 게 아니라 SSOT 에서 생성한다. 새 테이블 추가 시
# ingestion-map.yaml 한 줄 + 본 스크립트 실행 + publish 면 Silver 까지 자동.
#
# 생성물(기존 183쌍과 바이트 동일하게 재현):
#   models/staging/<src>/stg_<src>__<t>.sql        (Bronze→정제 view)
#   models/intermediate/<src>/int_<src>__<t>.sql   (merge=incremental dedup /
#                                                   replica=table passthrough)
#   models/staging/_staging__sources.yml           (Bronze source 선언)
#   seeds/_source_ingestion_modes.csv              (mode/cursor/pk 시드)
#     · .sql/sources.yml = config/ingestion-map.yaml 에서
#     · seed csv = config/source-schema.json 에서(replica 도 pk 보유)
#
# Gold(marts)는 도메인 로직 → 본 스크립트 대상 아님(수작업 유지).
#
# 사용:
#   scripts/dbt-gen-models.sh             # 제자리 생성(멱등)
#   scripts/dbt-gen-models.sh --check     # 임시 생성 후 기존과 diff(드리프트 0 검증)
#
# 원칙: fallback/mock 없음. merge 인데 cursor/PK 없으면 즉시 실패.
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-write}"
[[ "$MODE" == "--check" ]] && MODE=check
python3 -c "import yaml" 2>/dev/null || { echo "ERROR: PyYAML 필요" >&2; exit 1; }

REPO="$REPO" GEN_MODE="$MODE" python3 - <<'PY'
import os, sys, json, yaml, tempfile, subprocess, shutil

REPO = os.environ["REPO"]
CHECK = os.environ["GEN_MODE"] == "check"
MAP = yaml.safe_load(open(f"{REPO}/config/ingestion-map.yaml"))
SCHEMA = json.load(open(f"{REPO}/config/source-schema.json"))

DBT = f"{REPO}/dbt/maxdl_transform"
OUT = tempfile.mkdtemp(prefix="dbtgen_") if CHECK else DBT

def norm(name):                       # "schema.Table" → "table"(소문자)
    return name.split(".", 1)[1].lower() if "." in name else name.lower()

def w(rel, content):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(content)

def stg_sql(src, t):
    return (f"-- 자동 생성: {src}.{t} Bronze → staging cleaned view\n"
            "{{ config(materialized='view') }}\n"
            "select\n"
            f"    {{{{ dbt_utils.star(from=source('{src}', '{t}'), "
            "except=['_airbyte_raw_id', '_airbyte_meta', "
            "'_airbyte_generation_id', '_airbyte_extracted_at']) }},\n"
            "    _airbyte_extracted_at as _bronze_extracted_at_epoch,\n"
            "    {{ maxdl_audit_columns() }}\n"
            f"from {{{{ source('{src}', '{t}') }}}}\n")

def int_replica(src, t):
    r = f"stg_{src}__{t}"
    return (f"-- 자동생성: {src}.{t} Silver (replica: 정제 passthrough, 전체교체)\n"
            "{{ config(materialized='table') }}\n"
            f"select {{{{ dbt_utils.star(from=ref('{r}')) }}}}\n"
            f"from {{{{ ref('{r}') }}}}\n")

def int_merge(src, t, cur, pk):
    r = f"stg_{src}__{t}"
    uk = ", ".join(f"'{c}'" for c in pk)
    part = ", ".join(f'"{c}"' for c in pk)
    return (f"-- 자동생성: {src}.{t} Silver (merge: PK 최신 dedup, incremental)\n"
            "{{ config(materialized='incremental', incremental_strategy='merge',\n"
            f"    unique_key=[{uk}], on_schema_change='append_new_columns') }}}}\n"
            "with src as (\n"
            f"    select * from {{{{ ref('{r}') }}}}\n"
            "    {% if is_incremental() %}\n"
            f'    where "{cur}" > (select coalesce(max("{cur}"), '
            "timestamp '1970-01-01') from {{ this }})\n"
            "    {% endif %}\n"
            "),\n"
            "dedup as (\n"
            f'    select *, row_number() over (partition by {part} '
            f'order by "{cur}" desc) as _rn\n'
            "    from src\n"
            ")\n"
            f"select {{{{ dbt_utils.star(from=ref('{r}')) }}}}\n"
            "from dedup where _rn = 1\n")

# --- .sql + sources.yml (ingestion-map.yaml 기준) ---
src_yaml = ["version: 2\n", "\nsources:\n"]
for src, sdef in MAP["sources"].items():
    src_yaml.append(f"  - name: {src}\n    database: iceberg_bronze\n"
                     f"    schema: {src}\n"
                     f'    description: "{src} Bronze (Airbyte 적재)"\n'
                     "    tables:\n")
    for tdef in sdef["tables"]:
        t = norm(tdef["name"])
        mode = tdef["mode"]
        w(f"models/staging/{src}/stg_{src}__{t}.sql", stg_sql(src, t))
        if mode == "replica":
            w(f"models/intermediate/{src}/int_{src}__{t}.sql",
              int_replica(src, t))
        elif mode == "merge":
            cur = tdef.get("cursorField"); pk = tdef.get("primaryKey")
            if not cur or not pk:
                sys.exit(f"ERROR: merge 인데 cursor/PK 누락: {src}.{t}")
            w(f"models/intermediate/{src}/int_{src}__{t}.sql",
              int_merge(src, t, cur, pk))
        else:
            sys.exit(f"ERROR: 미지원 mode '{mode}': {src}.{t}")
        src_yaml.append(f"      - name: {t}\n")
w("models/staging/_staging__sources.yml", "".join(src_yaml))

# --- seed csv: mode/cursor 는 ingestion-map(정밀화 반영), replica pk 는
#     source-schema.json(ingestion-map 은 replica 에 pk 미기재). 순서=map.
#     기존 파일이 CRLF 라 동일하게 \r\n 으로 기록(바이트 동일). ---
csv = ["source,table,mode,cursor_field,primary_key\r\n"]
for src, sdef in MAP["sources"].items():
    for tdef in sdef["tables"]:
        full = tdef["name"]
        mode = tdef["mode"]
        cur = tdef.get("cursorField") or ""
        pk = tdef.get("primaryKey") or (SCHEMA[src].get(full, {})
                                        .get("primaryKey") or [])
        csv.append(f"{src},{full},{mode},{cur},{'|'.join(pk)}\r\n")
# CRLF 보존 위해 바이너리 기록(텍스트 모드 개행 변환 회피)
_csv_p = os.path.join(OUT, "seeds/_source_ingestion_modes.csv")
os.makedirs(os.path.dirname(_csv_p), exist_ok=True)
open(_csv_p, "wb").write("".join(csv).encode())

if not CHECK:
    print(f"생성 완료(제자리): {DBT}")
    sys.exit(0)

# --check: 기존과 바이트 diff
rc = 0
for root, _, files in os.walk(OUT):
    for f in files:
        gen = os.path.join(root, f)
        rel = os.path.relpath(gen, OUT)
        cur = os.path.join(DBT, rel)
        if not os.path.exists(cur):
            print(f"  + 신규(기존 없음): {rel}"); rc = 1; continue
        if open(gen, "rb").read() != open(cur, "rb").read():
            d = subprocess.run(["diff", cur, gen], capture_output=True, text=True)
            print(f"  ✗ 불일치: {rel}\n{d.stdout[:600]}"); rc = 1
n_gen = sum(len(fs) for _, _, fs in os.walk(OUT))
n_cur = (sum(len(fs) for _, _, fs in os.walk(f"{DBT}/models/staging"))
         + sum(len(fs) for _, _, fs in os.walk(f"{DBT}/models/intermediate")))
shutil.rmtree(OUT)
print(f"\n생성 {n_gen}개 vs 기존 staging+intermediate {n_cur}개")
print("드리프트 0 — 바이트 동일 ✅" if rc == 0 else "드리프트 발견 ❌")
sys.exit(rc)
PY