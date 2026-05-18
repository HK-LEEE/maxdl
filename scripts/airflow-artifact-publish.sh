#!/usr/bin/env bash
# =============================================================================
# airflow-artifact-publish.sh — dbt 프로젝트+DAG+manifest 를 SeaweedFS 아티팩트로
# -----------------------------------------------------------------------------
# 커스텀 Airflow 이미지에 dbt/DAG 를 굽지 않고, 버전 태그 tar 로 S3(SeaweedFS)에
# 올린다. Airflow pod 의 initContainer 가 런타임에 내려받아 emptyDir 로 전개.
#  → 새 테이블/모델 추가 시 "이미지 재빌드" 불필요(아티팩트 재발행 + 롤아웃만).
#
# 동작:
#   1) maxdl/airflow 이미지로 `dbt deps && dbt parse` (manifest.json 생성, 무접속)
#   2) dbt/maxdl_transform(+target) + dags 를 tar.gz
#   3) s3artifact.py 로 s3://<bucket>/<prefix>/maxdl-airflow-<버전>.tgz 업로드
#
# 환경변수화(전부 env, 미설정 시 seaweedfs-s3 시크릿에서 보충):
#   ARTIFACT_VERSION       기본: git short SHA (결정적·핀 가능)
#   ARTIFACT_S3_ENDPOINT   기본: http://localhost:8333 (빌드머신→Docker SeaweedFS)
#   ARTIFACT_S3_PREFIX     기본: airflow-artifacts
#   ARTIFACT_S3_BUCKET/REGION, AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY
#
# 원칙: fallback/mock 없음. 실패 즉시 중단.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${AIRFLOW_IMAGE:-maxdl/airflow:fu3}"
PREFIX="${ARTIFACT_S3_PREFIX:-airflow-artifacts}"
VER="${ARTIFACT_VERSION:-$(cd "$REPO_ROOT" && git rev-parse --short HEAD)}"

command -v docker  >/dev/null || { echo "ERROR: docker 필요(dbt parse 실행)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 필요" >&2; exit 1; }

# S3 자격: env 없으면 seaweedfs-s3 시크릿에서 보충
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  command -v kubectl >/dev/null || { echo "ERROR: 자격 env 없음 + kubectl 없음" >&2; exit 1; }
  g(){ kubectl get secret seaweedfs-s3 -n maxdl-ingest -o jsonpath="{.data.$1}" | base64 -d; }
  export AWS_ACCESS_KEY_ID="$(g accessKey)"
  export AWS_SECRET_ACCESS_KEY="$(g secretKey)"
  export ARTIFACT_S3_REGION="${ARTIFACT_S3_REGION:-$(g region)}"
  export ARTIFACT_S3_BUCKET="${ARTIFACT_S3_BUCKET:-$(g warehouseBucket)}"
fi
export ARTIFACT_S3_ENDPOINT="${ARTIFACT_S3_ENDPOINT:-http://localhost:8333}"

echo "= 아티팩트 버전: $VER  → s3://$ARTIFACT_S3_BUCKET/$PREFIX/maxdl-airflow-$VER.tgz"

# 1) manifest 생성 (이미지의 dbt 로, 무접속 parse)
echo "= dbt deps + parse (이미지 $IMAGE)"
# 빌드(온라인)측: dbt deps 로 패키지 설치 후 parse. --network=host 로 컨테이너
# DNS 해소(이 프로젝트 알려진 해법). 설치된 dbt_packages 는 아티팩트에 포함
# → 폐쇄망 런타임은 deps 불필요(자족).
# 이미지 ENV(DBT_PROJECT_DIR=아티팩트경로)는 빌드 컨테이너에 무의미 → override.
# 컨테이너를 호스트 uid 로 실행 → 마운트 디렉토리(target/dbt_packages) 쓰기 가능.
# 로그/HOME 은 컨테이너 내 /tmp(쓰기 가능)로.
docker run --rm --network=host --user "$(id -u):0" \
  -e HOME=/tmp -e DBT_LOG_PATH=/tmp/dbtlogs \
  -e DBT_PROJECT_DIR=/dbtp -e DBT_MANIFEST=/dbtp/target/manifest.json \
  -v "$REPO_ROOT/dbt/maxdl_transform:/dbtp" -w /dbtp "$IMAGE" \
  bash -c "dbt deps --profiles-dir . && DBT_PROFILES_DIR=. dbt parse --no-partial-parse --log-path /tmp/dbtlogs" \
  || { echo "ERROR: dbt deps/parse 실패" >&2; exit 1; }
[[ -f "$REPO_ROOT/dbt/maxdl_transform/target/manifest.json" ]] \
  || { echo "ERROR: manifest.json 미생성" >&2; exit 1; }

# 2) tar (dbt 프로젝트+target + dags)
TAR="$(mktemp --suffix=.tgz)"; trap 'rm -f "$TAR"' EXIT
# dbt_packages 포함(폐쇄망 런타임 자족 — deps 불필요). target 도 포함(manifest).
tar czf "$TAR" -C "$REPO_ROOT" dbt/maxdl_transform dags
echo "= 패키징: $(du -h "$TAR" | cut -f1)"

# 3) 업로드 — 버전 핀 + latest 별칭(차트 기본값 동작용)
python3 "$REPO_ROOT/scripts/s3artifact.py" put \
  "$PREFIX/maxdl-airflow-$VER.tgz" "$TAR"
python3 "$REPO_ROOT/scripts/s3artifact.py" put \
  "$PREFIX/maxdl-airflow-latest.tgz" "$TAR"

echo "완료. 결정적 핀: MAXDL_ARTIFACT_VERSION=$VER (기본값 latest 도 갱신됨)"
echo "  (운영 권장: helm --set ...MAXDL_ARTIFACT_VERSION=$VER 로 핀 → 롤아웃)"
