#!/usr/bin/env bash
# =============================================================================
# gen-trino-password-db.sh — Trino 파일기반 PASSWORD 인증 db(htpasswd) 생성
# -----------------------------------------------------------------------------
# secrets.env 의 평문 유저 비번 → bcrypt 해시 → Trino password-file 포맷
# (username:$2b$...) → K8s Secret 'trino-password-db'(key=password.db,
# maxdl-query) 생성/적용 + 커밋용 SealedSecret. chart auth.passwordAuthSecret
# 가 이 시크릿을 마운트(password.db 키)한다.
#
# 입력 평문(secrets.env, gitignore):
#   SVC_DBT_PASSWORD                 dbt/Airflow 전용 서비스계정(svc-dbt)
#   TRINO_USER_<NAME>_PASSWORD       사람 유저(선택, 여럿 가능 — <name> 소문자)
#
# 안전: 평문 디스크 미기록(파이프), bcrypt cost 10(Trino 최소 8 충족),
#       fallback 없음(값 없으면 실패). Trino 인증을 켜지 않는 한 이 시크릿은
#       유휴 — 생성·적용해도 라이브 무영향(컷오버 전 안전).
#
# 사용:
#   scripts/gen-trino-password-db.sh [--env FILE] [--apply] [--cert PEM]
#     --apply   K8s 에 Secret 직접 적용(maxdl-query)
#     --cert    대상 클러스터 공개키로 SealedSecret 출력(미지정 시 컨트롤러 조회)
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO/deploy/secrets/secrets.env"
APPLY=0; CERT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2;;
    --apply) APPLY=1; shift;;
    --cert) CERT="$2"; shift 2;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "ERROR: 알 수 없는 옵션 $1" >&2; exit 2;;
  esac
done
command -v python3 >/dev/null || { echo "ERROR: python3 필요" >&2; exit 1; }
python3 -c "import bcrypt" 2>/dev/null || { echo "ERROR: python bcrypt 필요" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "ERROR: kubeseal 필요" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: env 없음 $ENV_FILE" >&2; exit 1; }
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a

# 평문 → bcrypt → password.db 본문 (메모리)
PWDB="$(python3 - <<'PY'
import os, sys, bcrypt
users = {}
svc = os.environ.get("SVC_DBT_PASSWORD")
if not svc or svc == "CHANGE_ME":
    sys.exit("ERROR: SVC_DBT_PASSWORD 미설정(secrets.env)")
users["svc-dbt"] = svc
for k, v in os.environ.items():                # 사람 유저: TRINO_USER_<NAME>_PASSWORD
    if k.startswith("TRINO_USER_") and k.endswith("_PASSWORD") and v and v != "CHANGE_ME":
        users[k[len("TRINO_USER_"):-len("_PASSWORD")].lower()] = v
lines = []
for u, p in users.items():
    h = bcrypt.hashpw(p.encode(), bcrypt.gensalt(rounds=10)).decode()
    lines.append(f"{u}:{h}")
sys.stdout.write("\n".join(lines) + "\n")
sys.stderr.write(f"users: {','.join(users)}\n")
PY
)"
echo "$PWDB" | tail -0  # PWDB 비표시(평문해시 로그 방지)

# Secret 매니페스트(메모리) → 적용 + 봉인
MANIFEST="$(python3 - "$PWDB" <<'PY'
import sys, base64, json
db = sys.argv[1]
print(json.dumps({"apiVersion":"v1","kind":"Secret","type":"Opaque",
 "metadata":{"name":"trino-password-db","namespace":"maxdl-query"},
 "data":{"password.db": base64.b64encode(db.encode()).decode()}}))
PY
)"
if [[ "$APPLY" == 1 ]]; then
  echo "$MANIFEST" | kubectl apply -f - >&2
fi
SEAL=(kubeseal --format yaml)
if [[ -n "$CERT" ]]; then SEAL+=(--cert "$CERT")
else SEAL+=(--controller-namespace maxdl-system --controller-name sealed-secrets-controller); fi
OUT="$REPO/deploy/k8s/sealed/trino-password-db.maxdl-query.sealed.yaml"
echo "$MANIFEST" | "${SEAL[@]}" > "$OUT"
echo "봉인 → deploy/k8s/sealed/trino-password-db.maxdl-query.sealed.yaml" >&2
echo "완료(라이브 무영향 — Trino 인증 켜기 전까지 유휴)" >&2
