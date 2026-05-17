"""
maxdl DAG 등록 (FU-3) — 팩토리 호출만(소형 유지)
소스 4개 ingest DAG + Gold 변환 DAG 를 globals 에 노출.
Airbyte 커넥션 ID 는 Airflow Variable `airbyte_conn_<source>` 로 주입
(배포 후 1회 설정; ingestion-map 기반).
"""
from maxdl_factory import build_ingest_dag, build_transform_dag, SOURCES

for _s in SOURCES:
    globals()[f"ingest_{_s}"] = build_ingest_dag(_s)

transform_gold = build_transform_dag()
