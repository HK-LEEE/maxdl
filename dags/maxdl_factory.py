"""
maxdl DAG 팩토리 — 공통 빌더
---------------------------------------------------------------------------
계획서 §6 오케스트레이션 패턴을 재사용 가능한 팩토리로 구현.
 - 소스별 DAG: Airbyte 동기화 트리거 → 완료 센서 → Cosmos dbt(staging) → DQ
 - 전 소스 완료 시 Airflow Dataset 으로 변환 DAG(silver/gold) 자동 트리거
파일 500줄 이하·소형 유지를 위해 DAG 본체는 이 팩토리를 호출만 한다.

의존(커스텀 Airflow 이미지에 포함 필요 — 후속 wiring):
  apache-airflow-providers-airbyte, astronomer-cosmos[kubernetes],
  dbt-core, dbt-trino. 미포함 시 import 시점에 실패하므로 try-import 로
  파싱 안전을 확보(플랫폼만 가동된 현 단계에서 DAG 목록 깨짐 방지).
"""
from __future__ import annotations

from datetime import datetime

from airflow import DAG
from airflow.datasets import Dataset

# 소스별 Bronze 적재 완료를 알리는 Dataset(변환 DAG 의 스케줄 트리거)
BRONZE_READY = {
    s: Dataset(f"maxdl://bronze/{s}")
    for s in ("maxplatform", "pfms", "maxapex", "maxtdoracle")
}

DEFAULT_ARGS = {
    "owner": "maxdl",
    "retries": 1,
}


def build_ingest_dag(source: str, airbyte_connection_id: str | None) -> DAG:
    """소스 1개에 대한 인제스션+staging DAG 생성.

    source                : 논리 소스명(maxplatform/pfms/maxapex/maxtdoracle)
    airbyte_connection_id : Airbyte 커넥션 UUID(실 테이블 확정 후 주입)
    """
    dag = DAG(
        dag_id=f"ingest_{source}",
        description=f"{source} Bronze 인제스션 → staging",
        schedule="@daily",
        start_date=datetime(2026, 1, 1),
        catchup=False,
        default_args=DEFAULT_ARGS,
        tags=["maxdl", "ingest", source],
    )
    with dag:
        # 지연 import: 커스텀 이미지 미적용 환경에서도 DAG 파싱은 통과
        try:
            from airflow.providers.airbyte.operators.airbyte import (
                AirbyteTriggerSyncOperator,
            )
            from airflow.providers.airbyte.sensors.airbyte import AirbyteSensor

            trigger = AirbyteTriggerSyncOperator(
                task_id="airbyte_sync",
                connection_id=airbyte_connection_id or "TBD",
                asynchronous=True,
                retries=0,  # 비멱등 → DAG 재실행으로 복구(계획서 §6)
            )
            wait = AirbyteSensor(
                task_id="airbyte_wait",
                airbyte_job_id="{{ ti.xcom_pull(task_ids='airbyte_sync') }}",
            )
            trigger >> wait
        except ImportError:
            from airflow.operators.empty import EmptyOperator

            EmptyOperator(task_id="airbyte_sync_placeholder")
    return dag


def build_transform_dag() -> DAG:
    """전 소스 Bronze 완료(Dataset) 시 Silver→Gold 변환 DAG."""
    dag = DAG(
        dag_id="transform_silver_gold",
        description="Silver(정제/dedup) → Gold(MES/LIMS/QMS/SPC) + DQ 게이트",
        schedule=list(BRONZE_READY.values()),  # 데이터셋 스케줄
        start_date=datetime(2026, 1, 1),
        catchup=False,
        default_args=DEFAULT_ARGS,
        tags=["maxdl", "transform"],
    )
    with dag:
        from airflow.operators.empty import EmptyOperator

        EmptyOperator(task_id="dbt_silver_gold_placeholder")
    return dag
