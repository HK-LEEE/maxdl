#!/usr/bin/env bash
# =============================================================================
# gen-trino-acl.sh — config/pii-columns.yaml → Trino rules.json 컬럼마스크 동기
# -----------------------------------------------------------------------------
# PII 표준 어휘 SSOT(config/pii-columns.yaml)에서 charts/trino/values.yaml 의
# accessControl rules.json 안 analysts 컬럼 마스크 목록을 자동 생성·갱신.
# 수동 1:1 미러링/드리프트 제거. file-based ACL 은 컬럼 name 리터럴이라
# 표준 어휘만 enumerate(table:.* 라 전 테이블 적용, 길이 고정).
#
# 사용:
#   scripts/gen-trino-acl.sh           # 제자리 동기(멱등)
#   scripts/gen-trino-acl.sh --check   # 드리프트 검사(CI/커밋 전), 불일치=exit1
#
# 변경 후: 정책 반영하려면 deploy 시 또는
#   kubectl rollout restart deployment trino-coordinator -n maxdl-query
# 원칙: fallback 없음. 단일 "columns": [ ... ] 블록만 치환(다른 규칙 불변).
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-write}"; [[ "$MODE" == "--check" ]] && MODE=check
python3 -c "import yaml" 2>/dev/null || { echo "ERROR: PyYAML 필요" >&2; exit 1; }

REPO="$REPO" MODE="$MODE" python3 - <<'PY'
import os, re, sys, yaml
repo = os.environ["REPO"]; mode = os.environ["MODE"]
pii = yaml.safe_load(open(f"{repo}/config/pii-columns.yaml"))["canonical"]
if not pii:
    sys.exit("ERROR: config/pii-columns.yaml canonical 비어있음")
vpath = f"{repo}/charts/trino/values.yaml"
cur = open(vpath).read()

MASK = "'***-MASKED-***'"
lines = [f'              {{ "name": "{c}", "mask": "{MASK}" }}' for c in pii]
block = ('            "columns": [\n'
         + ",\n".join(lines) + "\n"
         + "            ]")

# 단일 columns 배열(12스페이스 "columns": [ ... 12스페이스 ])만 치환
pat = re.compile(r'            "columns": \[\n.*?\n            \]', re.DOTALL)
m = pat.search(cur)
if not m:
    sys.exit("ERROR: values.yaml 에서 columns 블록 1개를 못 찾음")
if len(pat.findall(cur)) != 1:
    sys.exit("ERROR: columns 블록이 1개가 아님(예상=1) — 수동 확인")
new = cur[:m.start()] + block + cur[m.end():]

if mode == "check":
    if new != cur:
        print("드리프트: pii-columns.yaml ≠ values.yaml 컬럼마스크. "
              "scripts/gen-trino-acl.sh 실행 필요"); sys.exit(1)
    print(f"동기 OK — 마스크 {len(pii)}개: {', '.join(pii)}"); sys.exit(0)

if new == cur:
    print(f"이미 동기 상태 — 마스크 {len(pii)}개: {', '.join(pii)}")
else:
    open(vpath, "w").write(new)
    print(f"values.yaml 컬럼마스크 갱신 — {len(pii)}개: {', '.join(pii)}")
    print("→ 반영: helmfile sync trino + "
          "kubectl rollout restart deployment trino-coordinator -n maxdl-query")
PY