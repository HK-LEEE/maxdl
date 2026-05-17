# =============================================================================
# maxdl 커스텀 Airflow 이미지 (FU-3)
# - 기반: apache/airflow 3.2.x
# - 추가: astronomer-cosmos(dbt→Airflow), dbt-trino, providers-airbyte
# - 동봉: dbt 프로젝트(maxdl_transform) + 빌드시 dbt deps/parse 로 manifest 생성
#   (Cosmos LoadMode.DBT_MANIFEST → 런타임 dbt ls 오버헤드 제거)
# =============================================================================
FROM apache/airflow:3.2.1-python3.12

USER airflow
# Airflow 베이스의 PIP_CONSTRAINT 가 비-Airflow 패키지(cosmos/dbt)를 차단
# ("from versions: none") → 해당 설치에 한해 제약 해제(표준 패턴).
# 버전 정책: 호환 확인된 안정 핀.
RUN PIP_CONSTRAINT= pip install --no-cache-dir \
      "astronomer-cosmos[kubernetes]==1.14.1" \
      "dbt-trino==1.10.1" \
      "dbt-core==1.11.10" \
      "apache-airflow-providers-airbyte"

# dbt 프로젝트 동봉
COPY --chown=airflow:0 dbt/maxdl_transform /opt/airflow/dbt/maxdl_transform
WORKDIR /opt/airflow/dbt/maxdl_transform
# deps + manifest 베이크 (profiles 는 런타임 env 주입; parse 는 무접속)
RUN dbt deps --profiles-dir . || true && \
    DBT_PROFILES_DIR=. dbt parse --no-partial-parse || true
WORKDIR /opt/airflow
# DAG 동봉(재현성 — git-sync/PVC 불필요)
COPY --chown=airflow:0 dags /opt/airflow/dags
ENV DBT_PROJECT_DIR=/opt/airflow/dbt/maxdl_transform \
    DBT_MANIFEST=/opt/airflow/dbt/maxdl_transform/target/manifest.json
