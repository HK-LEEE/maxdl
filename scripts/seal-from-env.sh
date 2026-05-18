#!/usr/bin/env bash
# =============================================================================
# seal-from-env.sh — 평문 SSOT(secrets.env) → 대상 클러스터 SealedSecret 일괄 봉인
# -----------------------------------------------------------------------------
# 목적: SealedSecret 이 봉인 시점 클러스터 컨트롤러 키에 묶이는 제약(FU-6)을
#       해소. 평문은 secrets.env(미커밋) 한 곳에만 두고, 배포 대상 클러스터의
#       컨트롤러 공개키로 그때그때 재봉인 → 어느 클러스터든 동일 SSOT 로 재현.
#
# 입력:
#   - deploy/secrets/secrets-spec.yaml : 토폴로지(어떤 Secret/NS/키, 출력 파일)
#   - deploy/secrets/secrets.env       : 평문 값(환경변수) — gitignore
#
# 동작: spec 순회 → 메모리에서 Secret 매니페스트 생성(평문 파일 미기록)
#       → kubeseal(대상 클러스터 키)로 봉인 → deploy/k8s/sealed/ 출력
#       → (--apply 시) kubectl apply.
#
# 사용:
#   scripts/seal-from-env.sh [옵션]
#     --env FILE            평문 env (기본 deploy/secrets/secrets.env)
#     --spec FILE           명세 (기본 deploy/secrets/secrets-spec.yaml)
#     --cert FILE           오프라인 봉인용 컨트롤러 공개키 PEM
#                           (미지정 시 --controller-* 로 온라인 조회)
#     --controller-namespace NS   (기본 maxdl-system)
#     --controller-name NAME      (기본 sealed-secrets-controller)
#     --only NAME           특정 Secret 이름만 처리(반복 가능)
#     --apply               봉인 후 kubectl apply 까지 수행
#     --dry-run             출력/적용 없이 검증만(누락 값 점검)
#
# 예) 운영 클러스터에 적용:
#   kubeseal --fetch-cert --controller-namespace maxdl-system \
#     --controller-name sealed-secrets-controller > /tmp/pub.pem
#   scripts/seal-from-env.sh --cert /tmp/pub.pem --apply
#
# 원칙: fallback/mock 없음 — 누락 값이 있으면 즉시 실패. 평문은 절대 미커밋.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/deploy/secrets/secrets.env"
SPEC_FILE="$REPO_ROOT/deploy/secrets/secrets-spec.yaml"
CERT_FILE=""
CTRL_NS="maxdl-system"
CTRL_NAME="sealed-secrets-controller"
APPLY=0
DRY=0
ONLY=()

# --- 인자 파싱 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2;;
    --spec) SPEC_FILE="$2"; shift 2;;
    --cert) CERT_FILE="$2"; shift 2;;
    --controller-namespace) CTRL_NS="$2"; shift 2;;
    --controller-name) CTRL_NAME="$2"; shift 2;;
    --only) ONLY+=("$2"); shift 2;;
    --apply) APPLY=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "ERROR: 알 수 없는 옵션: $1" >&2; exit 2;;
  esac
done

# --- 사전 조건(없으면 즉시 실패, fallback 없음) ---
command -v kubeseal >/dev/null || { echo "ERROR: kubeseal 미설치" >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "ERROR: kubectl 미설치" >&2; exit 1; }
command -v python3  >/dev/null || { echo "ERROR: python3 미설치" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "ERROR: python3 PyYAML 필요(pip install pyyaml)" >&2; exit 1; }
[[ -f "$ENV_FILE"  ]] || { echo "ERROR: env 파일 없음: $ENV_FILE" >&2; exit 1; }
[[ -f "$SPEC_FILE" ]] || { echo "ERROR: spec 파일 없음: $SPEC_FILE" >&2; exit 1; }
[[ -z "$CERT_FILE" || -f "$CERT_FILE" ]] || { echo "ERROR: cert 파일 없음: $CERT_FILE" >&2; exit 1; }

# --- 평문 SSOT 로드(현재 셸 환경으로) ---
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a

# --- 봉인 처리: python3 가 spec/env 로 Secret 매니페스트 생성 → kubeseal 파이프 ---
ONLY_CSV="$(IFS=,; echo "${ONLY[*]:-}")"
export SEAL_SPEC="$SPEC_FILE" SEAL_ONLY="$ONLY_CSV" SEAL_REPO="$REPO_ROOT"
export SEAL_CERT="$CERT_FILE" SEAL_CTRL_NS="$CTRL_NS" SEAL_CTRL_NAME="$CTRL_NAME"
export SEAL_APPLY="$APPLY" SEAL_DRY="$DRY"

python3 - <<'PY'
import os, sys, base64, subprocess, yaml

repo   = os.environ["SEAL_REPO"]
spec   = yaml.safe_load(open(os.environ["SEAL_SPEC"]))
only   = {x for x in os.environ.get("SEAL_ONLY", "").split(",") if x}
cert   = os.environ.get("SEAL_CERT", "")
ctrlns = os.environ["SEAL_CTRL_NS"]
ctrln  = os.environ["SEAL_CTRL_NAME"]
apply  = os.environ["SEAL_APPLY"] == "1"
dry    = os.environ["SEAL_DRY"] == "1"

missing, planned = [], []
# 1차: 전 항목 값 존재 검증(누락 시 한 번에 보고 후 실패 — fallback 없음)
for s in spec["secrets"]:
    if only and s["name"] not in only:
        continue
    for k, env_var in s["data"].items():
        v = os.environ.get(env_var)
        if v is None or v == "" or v == "CHANGE_ME":
            missing.append(f"{s['name']}.{k}  (env: {env_var})")
    planned.append(s["name"])

if missing:
    print("ERROR: 다음 값이 secrets.env 에 비어있음/미설정(CHANGE_ME 포함):",
          file=sys.stderr)
    for m in missing:
        print("  -", m, file=sys.stderr)
    sys.exit(1)

print(f"검증 OK — 대상 Secret {len(planned)}종: {', '.join(planned)}")
if dry:
    print("--dry-run: 출력/적용 생략."); sys.exit(0)

def seal(secret_yaml: bytes) -> bytes:
    """평문 Secret 매니페스트(bytes) → kubeseal 봉인 결과(bytes).
    --cert 지정 시 오프라인, 아니면 컨트롤러 온라인 조회."""
    cmd = ["kubeseal", "--format", "yaml"]
    if cert:
        cmd += ["--cert", cert]
    else:
        cmd += ["--controller-namespace", ctrlns,
                "--controller-name", ctrln]
    p = subprocess.run(cmd, input=secret_yaml,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.stderr.write(p.stderr.decode())
        raise SystemExit(f"ERROR: kubeseal 실패(rc={p.returncode})")
    return p.stdout

count = 0
for s in spec["secrets"]:
    if only and s["name"] not in only:
        continue
    for tgt in s["targets"]:
        ns      = tgt["namespace"]
        outpath = os.path.join(repo, tgt["file"])
        # 평문 Secret 매니페스트를 메모리에서 구성(디스크에 평문 미기록)
        data = {k: base64.b64encode(os.environ[v].encode()).decode()
                for k, v in s["data"].items()}
        manifest = yaml.safe_dump({
            "apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": s["name"], "namespace": ns},
            "type": s.get("type", "Opaque"),
            "data": data,
        }, sort_keys=False).encode()

        sealed = seal(manifest)
        os.makedirs(os.path.dirname(outpath), exist_ok=True)
        with open(outpath, "wb") as f:
            f.write(sealed)
        print(f"  봉인 → {tgt['file']}  (ns={ns})")
        count += 1

        if apply:
            a = subprocess.run(["kubectl", "apply", "-f", outpath],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print("   ", a.stdout.decode().strip())
            if a.returncode != 0:
                raise SystemExit("ERROR: kubectl apply 실패")

print(f"완료 — SealedSecret {count}개 봉인" + (" + 적용" if apply else ""))
PY