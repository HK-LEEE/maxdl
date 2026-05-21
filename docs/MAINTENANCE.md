# Iceberg 유지보수 (maintain_iceberg DAG)

운영 시간이 갈수록 누적되는 작은 파일·스냅샷·고아 파일을 자동 정리.
**점진적 쿼리 둔화 + 스토리지 낭비** 방지가 목적.

## 1. 어디서 정하나 (SSOT = `config/maintenance.yaml`)

DAG `dags/maxdl_maintenance.py` 가 모듈 로드 시 이 파일을 읽음
(fallback 없음 — 누락 시 즉시 RuntimeError).

```yaml
schedule: "0 4 * * 0"        # 매주 일요일 04:00 KST (저활동)
retention:
  snapshots: "7d"            # expire_snapshots 보존 = time-travel 1주
  orphan: "7d"               # remove_orphan_files 보존 = in-flight 보호
layers: [iceberg_bronze, iceberg_silver, iceberg_gold]
```

대상 테이블은 `<layer>.information_schema.tables` 동적 발견 — **새 테이블
추가에 DAG 변경 0**.

## 2. 무엇을·왜 (절차 4단계, 순서 의미 있음)

| 단계 | Trino 절차 | 효과 |
|---|---|---|
| 1 | `optimize` | 작은 Parquet 파일을 큰 파일(~512MB)로 재작성 — 스캔 성능 |
| 2 | `optimize_manifests` | manifest list 정리 — 플래닝 비용 |
| 3 | `expire_snapshots(retention_threshold=…)` | 보존 이전 스냅샷·참조 파일 만료 — 메타 비대화 |
| 4 | `remove_orphan_files(retention_threshold=…)` | 메타 무참조 파일 제거 — 스토리지 낭비 |

3·4 순서 필수: 만료 → 그제서야 orphan 으로 잡힘 → 제거.

## 3. 안전 (정직)

| 위험 | 대응 |
|---|---|
| 동시 쓰기와 충돌(orphan 제거가 진행 중 쓰기 파일 삭제) | retention 7d ≫ in-flight 시간, 스케줄 저활동 시간(일요일 04:00 KST) |
| 공유 SeaweedFS 부하 | 주 1회. 운영 시간(주중 09–18 KST) 회피 |
| time-travel 손실 | retention 7d = 1주 보장. 감사 요건 있으면 길게 |
| 한 테이블 실패가 DAG 전체 중단 | 테이블별 try/except + 요약 로그(layer·step·ok/fail) |
| 첫 실행이 무거움(누적분) | 첫 실행은 maxapex 1소스만 수동 → 효과·시간 측정 → 단계 확장 |
| 마이그레이션 직후 실행(의도 파일 제거 위험) | 마이그레이션 윈도우엔 DAG pause(Airflow UI) |

**절대 금지**: `retention_threshold` 1d 미만(in-flight 쓰기 삭제 위험).

## 4. 적용 절차 (PR 머지 후, 운영자 수동)

```bash
# 1) (선택) 첫 실행은 1 소스/1 테이블만 수동 트라이얼:
#    - dag pause(maintain_iceberg) 후 수동 SQL 1개 테이블만 실행 → 시간 측정
#    - 그 후 unpause

# 2) 정상 배포 (코드 변경 시):
scripts/airflow-artifact-publish.sh                                # artifact 재발행
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor             # 새 artifact refetch

# 3) DAG 활성 확인 + 다음 실행 예정 시각
kubectl -n maxdl-orchestrate exec deploy/airflow-scheduler -- \
  airflow dags details maintain_iceberg | grep -iE 'is_paused|schedule|next'
```

## 5. 주기/보존 변경 (운영 중)

```bash
# config/maintenance.yaml 의 schedule·retention 수정 후
scripts/airflow-artifact-publish.sh                                # SSOT 재발행
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor
```

변경 적용은 코드 변경 0(YAML SSOT만). 폐쇄망 무접속(아티팩트 자족).

## 6. 운영 모니터링

DAG 마지막 task 로그 끝에 요약:
```
ALL DONE summary={'layers':{'iceberg_bronze':{'tables':N,'ok':4N,'fail':0}, ...}, 'ok':total_ok, 'fail':total_fail}
```
S3 원격 로깅 활성이므로 task 로그는 `s3://maxdl-warehouse/airflow-logs/
dag_id=maintain_iceberg/...` 에 보존(Airflow UI 자동 표시).

**fail > 0**: 해당 테이블·단계 로그 검토(다음 주기에 자동 재시도 — 본
DAG retries=0, schedule 재진입으로 자연 회복).

## 7. 정직한 한계

- 효과는 "쿼리 단축·스토리지 증가율 정체"의 **방향**이지 보장 수치 아님 —
  적재량·테이블 수에 따라 가변. 운영 측정으로 retention/주기 조정.
- 큰 테이블 `optimize` 는 Trino 메모리 의존 — 1순위 Trino 튜닝
  (docs/performance.md, values.yaml_bak) 미적용 상태에선 OOM 가능.
  → fail 발생 시 그 테이블만 skip 되고 다른 테이블 계속(설계상 격리).
- `expire_snapshots` 가 time-travel 한계를 만듦 — 감사·복구 요건이
  retention 보다 길면 retention 을 그만큼 늘리거나 별도 백업.
- 본 DAG 가 다루는 건 maxdl-warehouse 버킷 내부뿐. 운영 SeaweedFS 의
  타 버킷(maxplatform-*/maxapex-*) 절대 미접근(설계상 카탈로그 분리).
