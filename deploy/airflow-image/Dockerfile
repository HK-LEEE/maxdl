# =============================================================================
# maxdl 커스텀 Airflow 이미지 (FU-3 / 아티팩트 패턴)
# - 기반: apache/airflow 3.2.x
# - 추가: astronomer-cosmos(dbt→Airflow), dbt-trino, providers-airbyte
# - **dbt 프로젝트/DAG/manifest 는 굽지 않는다**(SeaweedFS 아티팩트 패턴):
#   런타임 initContainer 가 s3artifact.py 로 내려받아 /opt/airflow/artifact 에
#   전개. 이미지는 "안정적인 pip 패키지층 + 작은 다운로더"만 유지 →
#   새 테이블/모델 추가 시 이미지 재빌드 불필요(아티팩트 재발행만).
# =============================================================================
FROM apache/airflow:3.2.1-python3.12

USER airflow
# Airflow 베이스의 PIP_CONSTRAINT 가 비-Airflow 패키지(cosmos/dbt)를 차단
# ("from versions: none") → 해당 설치에 한해 제약 해제(표준 패턴).
# 버전 정책: 호환 확인된 안정 핀. 이 층은 거의 변하지 않음(이미지 안정).
RUN PIP_CONSTRAINT= pip install --no-cache-dir \
      "astronomer-cosmos[kubernetes]==1.14.1" \
      "dbt-trino==1.10.1" \
      "dbt-core==1.11.10" \
      "apache-airflow-providers-airbyte"

# 의존성 없는 S3(SigV4) 다운로더 — initContainer 가 이걸로 아티팩트 fetch.
# (boto3/aws CLI 불필요, 폐쇄망 친화. 거의 불변 → 이미지 안정 유지)
COPY --chown=airflow:0 scripts/s3artifact.py /opt/airflow/s3artifact.py

# dbt 프로젝트/DAG/manifest 는 런타임 아티팩트(/opt/airflow/artifact)에서 옴
ENV DBT_PROJECT_DIR=/opt/airflow/artifact/dbt/maxdl_transform \
    DBT_MANIFEST=/opt/airflow/artifact/dbt/maxdl_transform/target/manifest.json \
    AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/artifact/dags
