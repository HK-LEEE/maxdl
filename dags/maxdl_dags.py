"""
maxdl DAG 등록 — 소스 4종 + 변환
---------------------------------------------------------------------------
팩토리(maxdl_factory)를 호출해 DAG 를 globals 에 노출만 한다(소형 유지).
airbyte_connection_id 는 실 소스 테이블 확정 후 ingestion-map 기반으로
주입한다(현재 None → placeholder 태스크로 안전 파싱).
"""
from maxdl_factory import build_ingest_dag, build_transform_dag

for _src in ("maxplatform", "pfms", "maxapex", "maxtdoracle"):
    globals()[f"ingest_{_src}"] = build_ingest_dag(_src, airbyte_connection_id=None)

transform_silver_gold = build_transform_dag()
