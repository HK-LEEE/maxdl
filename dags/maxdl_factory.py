"""
maxdl DAG 팩토리 (FU-3) — Cosmos 기반 dbt 오케스트레이션 + Airbyte 트리거
---------------------------------------------------------------------------
- 소스별 DAG: Airbyte 동기화(API 트리거+폴링) → Cosmos dbt(staging+silver, 해당 소스)
- 전 소스 완료 → Dataset 트리거로 Gold 변환 DAG(Cosmos marts)
- Cosmos: LoadMode.DBT_MANIFEST(이미지에 manifest 베이크) + ExecutionMode.LOCAL
  (KubernetesExecutor 가 태스크 pod 격리하므로 LOCAL 이 효율적)
환경변수(차트 env 주입): TRINO_HOST/PORT/USER, AIRBYTE_* (sync 트리거용)
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import yaml
import pendulum                  # Airflow 번들(타임존-인지 datetime 표준)

from airflow.sdk import DAG
from airflow.sdk import Asset
from airflow.providers.standard.operators.python import PythonOperator

from cosmos import (
    DbtTaskGroup, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig,
)
from cosmos.constants import LoadMode, ExecutionMode

DBT_PROJECT = os.environ.get("DBT_PROJECT_DIR", "/opt/airflow/dbt/maxdl_transform")
MANIFEST = os.environ.get("DBT_MANIFEST", f"{DBT_PROJECT}/target/manifest.json")

# SSOT: 소스 목록·주기는 config/ingestion-map.yaml 단일 출처에서 로드.
# 경로는 dev(REPO/config) / pod(/opt/airflow/artifact/config) 모두 동일하게
# dags/ 의 부모 + config/ 로 해석됨(아티팩트 tar 에 config/ 포함).
# 원칙: fallback 없음 — 누락 시 즉시 실패(주기 SSOT 강제).
_INGESTION_MAP_PATH = Path(__file__).resolve().parent.parent / "config" / "ingestion-map.yaml"
_MAP = yaml.safe_load(open(_INGESTION_MAP_PATH))
SOURCES = tuple(_MAP["sources"].keys())
SCHEDULES = {}
for _s, _sdef in _MAP["sources"].items():
    _sch = _sdef.get("schedule")
    if _sch is None:
        raise RuntimeError(
            f"ingestion-map.yaml: sources.{_s}.schedule 누락 — "
            "주기는 필수(fallback 없음). docs/SCHEDULING.md 참고.")
    SCHEDULES[_s] = _sch

BRONZE_READY = {s: Asset(f"maxdl://bronze/{s}") for s in SOURCES}
DEFAULT_ARGS = {"owner": "maxdl", "retries": 1}
# tz-인지 start_date(Asia/Seoul). Airflow chart DEFAULT_TIMEZONE=Asia/Seoul
# 와 짝(09:00 KST=00:00 UTC 의도 사고 방지 — docs/SCHEDULING.md §3).
START_DATE = pendulum.datetime(2026, 1, 1, tz="Asia/Seoul")

# dbt-trino: Cosmos profile 은 프로젝트의 profiles.yml(env_var) 재사용
PROFILE = ProfileConfig(
    profile_name="maxdl_transform",
    target_name="default",
    profiles_yml_filepath=f"{DBT_PROJECT}/profiles.yml",
)
EXEC = ExecutionConfig(execution_mode=ExecutionMode.LOCAL)


def _airbyte_sync(connection_id: str, **_):
    """Airbyte API 로 동기화 트리거 후 완료까지 폴링(provider 비멱등 회피).
    자격: 환경변수 AIRBYTE_API/CLIENT_ID/CLIENT_SECRET (차트 env 주입)."""
    import json, urllib.request
    base = os.environ["AIRBYTE_API"]  # http://airbyte-airbyte-server-svc.maxdl-ingest:8001
    cid = os.environ["AIRBYTE_CLIENT_ID"]
    csec = os.environ["AIRBYTE_CLIENT_SECRET"]

    def _post(path, body, token=None):
        req = urllib.request.Request(
            base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json",
                     **({"Authorization": f"Bearer {token}"} if token else {})})
        return json.loads(urllib.request.urlopen(req, timeout=60).read())

    tok = _post("/api/public/v1/applications/token",
                {"client_id": cid, "client_secret": csec})["access_token"]
    job = _post("/api/v1/connections/sync", {"connectionId": connection_id}, tok)["job"]["id"]
    for _ in range(120):  # 최대 ~60분
        st = _post("/api/v1/jobs/get", {"id": job}, tok)["job"]["status"]
        if st == "succeeded":
            return
        if st in ("failed", "cancelled"):
            raise RuntimeError(f"Airbyte sync {job} {st}")
        time.sleep(30)
    raise TimeoutError(f"Airbyte sync {job} timeout")


def build_ingest_dag(source: str) -> DAG:
    """소스 1개: Airbyte 동기화 → Cosmos dbt(staging+silver, 해당 소스).
    schedule 은 ingestion-map.yaml 의 sources.<source>.schedule(SSOT)."""
    with DAG(
        dag_id=f"ingest_{source}",
        description=f"{source}: Airbyte→Bronze → dbt staging/silver",
        schedule=SCHEDULES[source], start_date=START_DATE,
        catchup=False, default_args=DEFAULT_ARGS,
        tags=["maxdl", "ingest", source],
    ) as dag:
        sync = PythonOperator(
            task_id="airbyte_sync",
            python_callable=_airbyte_sync,
            op_kwargs={"connection_id":
                       "{{ var.value.get('airbyte_conn_" + source + "', 'TBD') }}"},
            retries=0,  # 비멱등 → DAG 재실행으로 복구
        )
        dbt = DbtTaskGroup(
            group_id=f"dbt_{source}",
            # install_dbt_deps=False: Cosmos 가 모델당 임시 project_dir(/tmp/tmpXXX)
            # 만들 때 vendored dbt_packages 를 symlink 포함시켜 자동 dbt deps
            # (hub.getdbt.com 접근) 호출을 차단. 폐쇄망/SSL 차단 환경에서 필수.
            # (Cosmos 1.14: install_deps=False+copy_dbt_packages=False →
            #  ignore_dbt_packages=False → dbt_packages symlink 생성)
            project_config=ProjectConfig(DBT_PROJECT, manifest_path=MANIFEST, install_dbt_deps=False),
            profile_config=PROFILE, execution_config=EXEC,
            render_config=RenderConfig(
                load_method=LoadMode.DBT_MANIFEST,
                select=[f"path:models/staging/{source}",
                        f"path:models/intermediate/{source}"]),
            operator_args={"outlets": [BRONZE_READY[source]]},
        )
        sync >> dbt
    return dag


def build_transform_dag() -> DAG:
    """전 소스 Bronze 완료(Dataset) → Gold 마트(Cosmos marts)."""
    with DAG(
        dag_id="transform_gold",
        description="Silver → Gold 마트 (Cosmos marts)",
        schedule=list(BRONZE_READY.values()),
        start_date=START_DATE,
        catchup=False, default_args=DEFAULT_ARGS,
        tags=["maxdl", "transform", "gold"],
    ) as dag:
        DbtTaskGroup(
            group_id="dbt_marts",
            # install_dbt_deps=False: Cosmos 가 모델당 임시 project_dir(/tmp/tmpXXX)
            # 만들 때 vendored dbt_packages 를 symlink 포함시켜 자동 dbt deps
            # (hub.getdbt.com 접근) 호출을 차단. 폐쇄망/SSL 차단 환경에서 필수.
            # (Cosmos 1.14: install_deps=False+copy_dbt_packages=False →
            #  ignore_dbt_packages=False → dbt_packages symlink 생성)
            project_config=ProjectConfig(DBT_PROJECT, manifest_path=MANIFEST, install_dbt_deps=False),
            profile_config=PROFILE, execution_config=EXEC,
            render_config=RenderConfig(load_method=LoadMode.DBT_MANIFEST,
                                       select=["path:models/marts"]),
        )
    return dag
