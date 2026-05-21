"""
maxdl Iceberg 유지보수 DAG — compaction + snapshot expire + orphan cleanup
---------------------------------------------------------------------------
- 주기·보존·대상 카탈로그는 config/maintenance.yaml (SSOT, fallback 없음).
- 절차(순서 의미 있음): optimize → optimize_manifests → expire_snapshots
  → remove_orphan_files. orphan 은 반드시 expire 다음(만료된 snapshot
  의 파일이 그제서야 orphan 으로 잡힘).
- 테이블 발견: <layer>.information_schema.tables 동적 조회 → 새 테이블
  추가에 DAG 변경 0.
- 격리: 테이블별 try/except — 한 테이블 실패가 다른 테이블 중단 안 시킴.
- 자격: svc-dbt (Trino password-file, ACL OWNERSHIP). TRINO_* env 는
  Airflow chart 가 주입(이미 운영 ingest DAG 와 동일 통로).
- 안전: 공유 SeaweedFS 의 maxdl-warehouse 버킷 내부만 작업(타 운영 버킷
  미접근). retention >> in-flight 쓰기 시간(주 1회·일 04:00 KST 저활동).
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

import pendulum
import yaml

from airflow.sdk import DAG
from airflow.providers.standard.operators.python import PythonOperator

# SSOT 로드 (artifact tar 에 포함 — airflow-artifact-publish.sh).
_CONF_PATH = Path(__file__).resolve().parent.parent / "config" / "maintenance.yaml"
_CONF = yaml.safe_load(open(_CONF_PATH))
SCHEDULE = _CONF["schedule"]
RETENTION_SNAP = _CONF["retention"]["snapshots"]
RETENTION_ORPHAN = _CONF["retention"]["orphan"]
LAYERS = list(_CONF["layers"])
if not (SCHEDULE and RETENTION_SNAP and RETENTION_ORPHAN and LAYERS):
    raise RuntimeError(f"maintenance.yaml 필수 키 누락: {_CONF}")

START_DATE = pendulum.datetime(2026, 1, 1, tz="Asia/Seoul")
DEFAULT_ARGS = {"owner": "maxdl", "retries": 0}  # 재시도 0 — 다음 주기에 자연 회복


def _connect():
    """Trino 연결(svc-dbt, HTTPS+self-signed CA). 환경변수는 Airflow chart 주입."""
    import trino
    host = os.environ["TRINO_HOST"]
    port = int(os.environ["TRINO_PORT"])
    user = "svc-dbt"
    pw = os.environ["TRINO_PASSWORD"]
    return trino.dbapi.connect(
        host=host, port=port, user=user,
        http_scheme=os.environ.get("TRINO_HTTP_SCHEME", "https"),
        auth=trino.auth.BasicAuthentication(user, pw),
        verify=os.environ.get("TRINO_CERT") or False,
    )


def _maintain(**_):
    """전 레이어·전 테이블에 4개 절차 직렬 실행. 테이블별 격리·요약 로그."""
    log = logging.getLogger(__name__)
    conn = _connect()
    cur = conn.cursor()
    summary = {"layers": {}, "ok": 0, "fail": 0}
    for layer in LAYERS:
        layer_stats = {"tables": 0, "ok": 0, "fail": 0}
        cur.execute(
            f"SELECT table_schema, table_name FROM {layer}.information_schema.tables "
            "WHERE table_schema NOT IN ('information_schema','system')"
        )
        tables = cur.fetchall()
        log.info("layer=%s tables=%d", layer, len(tables))
        for schema, table in tables:
            layer_stats["tables"] += 1
            fq = f'{layer}."{schema}"."{table}"'
            # 순서 의미: optimize → optimize_manifests → expire → orphan.
            steps = [
                ("optimize",
                 f"ALTER TABLE {fq} EXECUTE optimize"),
                ("optimize_manifests",
                 f"ALTER TABLE {fq} EXECUTE optimize_manifests"),
                ("expire_snapshots",
                 f"ALTER TABLE {fq} EXECUTE expire_snapshots("
                 f"retention_threshold => '{RETENTION_SNAP}')"),
                ("remove_orphan_files",
                 f"ALTER TABLE {fq} EXECUTE remove_orphan_files("
                 f"retention_threshold => '{RETENTION_ORPHAN}')"),
            ]
            for step, sql in steps:
                try:
                    c2 = conn.cursor()
                    c2.execute(sql)
                    c2.fetchall()  # consume
                    layer_stats["ok"] += 1
                    summary["ok"] += 1
                except Exception as e:
                    layer_stats["fail"] += 1
                    summary["fail"] += 1
                    # 정직: 실패는 로그만 — 다른 테이블/단계 계속.
                    log.warning("SKIP %s %s: %s", fq, step, str(e)[:300])
        summary["layers"][layer] = layer_stats
        log.info("layer=%s done: %s", layer, layer_stats)
    log.info("ALL DONE summary=%s", summary)
    # 합계 fail > 0 이어도 task 는 success 처리(부분 부패는 다음 주기에 회복).
    # 운영자가 모니터링: 로그 ALL DONE 의 summary 확인.


with DAG(
    dag_id="maintain_iceberg",
    description="Iceberg compaction + snapshot expire + orphan files cleanup",
    schedule=SCHEDULE,
    start_date=START_DATE,
    catchup=False,
    default_args=DEFAULT_ARGS,
    tags=["maxdl", "maintenance", "iceberg"],
) as maintain_iceberg_dag:
    PythonOperator(task_id="run", python_callable=_maintain)
