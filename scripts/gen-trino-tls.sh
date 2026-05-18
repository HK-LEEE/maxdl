#!/usr/bin/env bash
# =============================================================================
# gen-trino-tls.sh — Trino 내부 self-signed TLS (FU-9 컷오버 선행)
# -----------------------------------------------------------------------------
# dbt-trino 비밀번호 인증이 HTTPS 를 강제(컷오버 리허설서 실증)하므로 Trino
# coordinator 에 클러스터 내부 self-signed TLS 를 적용한다. FU-7(외부 ingress
# +도메인+정식 CA)과 별개 — in-cluster 트래픽용. 정식 인증서로 추후 교체 가능.
#
# 산출(전부 메모리→시크릿, 평문 디스크 미기록):
#   - trino-tls (maxdl-query): keystore.p12  (Trino https keystore, 바이너리)
#   - trino-tls-ca (maxdl-orchestrate, maxdl-bi): tls.crt  (self-signed 공개
#     인증서 = CA. dbt(REQUESTS_CA_BUNDLE)·Superset(verify) 신뢰용)
#   각 SealedSecret 도 생성(커밋용).
#
# 입력: secrets.env 의 TRINO_TLS_KEYSTORE_PASSWORD (keystore 비번)
# SAN: trino.maxdl-query.svc.cluster.local / trino / localhost (유효기간 10y)
# 원칙: fallback 없음. Trino https 미활성 시 이 시크릿은 유휴(비파괴).
#
# 사용: scripts/gen-trino-tls.sh [--env FILE] [--apply] [--cert PEM]
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO/deploy/secrets/secrets.env"; APPLY=0; CERT=""
while [[ $# -gt 0 ]]; do case "$1" in
  --env) ENV_FILE="$2"; shift 2;; --apply) APPLY=1; shift;;
  --cert) CERT="$2"; shift 2;; -h|--help) sed -n '2,24p' "$0"; exit 0;;
  *) echo "ERROR: 알 수 없는 옵션 $1" >&2; exit 2;; esac; done
command -v openssl >/dev/null || { echo "ERROR: openssl 필요" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "ERROR: kubeseal 필요" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: env 없음 $ENV_FILE" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
PW="${TRINO_TLS_KEYSTORE_PASSWORD:-}"
[[ -n "$PW" && "$PW" != "CHANGE_ME" ]] || { echo "ERROR: TRINO_TLS_KEYSTORE_PASSWORD 미설정" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SAN="DNS:trino.maxdl-query.svc.cluster.local,DNS:trino,DNS:localhost"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=trino.maxdl-query.svc.cluster.local/O=maxdl" \
  -addext "subjectAltName=$SAN" 2>/dev/null
openssl pkcs12 -export -in "$TMP/cert.pem" -inkey "$TMP/key.pem" \
  -name trino -out "$TMP/keystore.p12" -passout "pass:$PW" 2>/dev/null
[[ -s "$TMP/keystore.p12" && -s "$TMP/cert.pem" ]] || { echo "ERROR: 생성 실패" >&2; exit 1; }

seal_apply(){  # $1=ns $2=name $3=key $4=file
  local NS="$1" N="$2" K="$3" F="$4"
  local MAN; MAN="$(K=$K F=$F N=$N NS=$NS python3 -c '
import os,base64,json
print(json.dumps({"apiVersion":"v1","kind":"Secret","type":"Opaque",
 "metadata":{"name":os.environ["N"],"namespace":os.environ["NS"]},
 "data":{os.environ["K"]: base64.b64encode(open(os.environ["F"],"rb").read()).decode()}}))')"
  [[ "$APPLY" == 1 ]] && echo "$MAN" | kubectl apply -f - >&2
  local SEAL=(kubeseal --format yaml)
  [[ -n "$CERT" ]] && SEAL+=(--cert "$CERT") \
    || SEAL+=(--controller-namespace maxdl-system --controller-name sealed-secrets-controller)
  echo "$MAN" | "${SEAL[@]}" > "$REPO/deploy/k8s/sealed/$N.$NS.sealed.yaml"
  echo "  봉인 → deploy/k8s/sealed/$N.$NS.sealed.yaml" >&2
}
# Trino 서버 keystore
seal_apply maxdl-query     trino-tls    keystore.p12 "$TMP/keystore.p12"
# 클라이언트 신뢰용 CA(self-signed 공개인증서) — dbt / Superset 네임스페이스
seal_apply maxdl-orchestrate trino-tls-ca tls.crt    "$TMP/cert.pem"
seal_apply maxdl-bi          trino-tls-ca tls.crt    "$TMP/cert.pem"
echo "완료(라이브 무영향 — Trino https 미활성 시 유휴). SAN=$SAN, 10y" >&2
