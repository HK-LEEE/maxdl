# maxdl 적재 주기(스케줄) 설정 가이드

데이터를 **얼마나 자주 가져올지**를 정하는 방법. 한 줄 요약:

> 주기는 **Airbyte 가 아니라 Airflow DAG 의 `schedule`** 에서 정한다.
> Airbyte 커넥션은 `scheduleType: "manual"` 로 고정되어 있고(Airflow
> 가 트리거하는 구조), Airbyte UI 에서 주기를 바꿔도 **무의미**하다.

---

## 1. 어디서 정하나

`dags/maxdl_factory.py` 의 `build_ingest_dag()` → `schedule=` 인자.

```python
def build_ingest_dag(source: str) -> DAG:
    with DAG(
        dag_id=f"ingest_{source}",
        schedule="@daily", start_date=datetime(2026, 1, 1),
        catchup=False, default_args=DEFAULT_ARGS,
        ...
```

- **현재**: 4개 소스(maxplatform/pfms/maxapex/maxtdoracle) 전부
  `@daily`(매일 1회) — **균일**.
- **Gold 변환 DAG 은 시간 스케줄이 아님**: `build_transform_dag()` 의
  `schedule=list(BRONZE_READY.values())` = **Dataset(Asset) 트리거**.
  4개 소스 Bronze 적재가 끝나면 자동 실행된다.
  → **ingest 주기만 정하면 Silver/Gold 는 따라온다.** 변환 주기를
  따로 설정할 필요 없음.

---

## 2. `schedule` 형식

| 형식 | 예시 | 의미 |
|---|---|---|
| 프리셋 | `"@hourly"` | 매시 0분 |
| 프리셋 | `"@daily"` | 매일 00:00 |
| 프리셋 | `"@weekly"` | 매주 일요일 00:00 |
| cron | `"0 */2 * * *"` | 2시간마다 |
| cron | `"0 18 * * *"` | 매일 18:00 |
| cron | `"*/30 * * * *"` | 30분마다 |
| timedelta | `timedelta(hours=6)` | 직전 실행 +6시간 |
| 수동 | `None` | 스케줄 없음(수동 트리거만) |

cron 5필드 = `분 시 일 월 요일`.

---

## 3. ⚠ 한국 환경 주의 — 타임존 (중요)

현재 `AIRFLOW__CORE__DEFAULT_TIMEZONE` **미설정 → Airflow 기본 UTC**.
따라서:

- `@daily` = **00:00 UTC = 09:00 KST** 에 실행됨.
- cron `"0 2 * * *"` 로 적으면 **02:00 UTC = 11:00 KST** (의도와 다름).

한국 기준 시각으로 운영하려면 둘 중 하나:

1. **(권장)** `charts/airflow/values.yaml` 의 env 에 추가:
   ```yaml
   - name: AIRFLOW__CORE__DEFAULT_TIMEZONE
     value: "Asia/Seoul"
   ```
   이후 모든 cron 을 **KST 로 해석**(예: `"0 2 * * *"` = 새벽 2시 KST).
   적용은 Airflow 차트 변경이므로 `helmfile -l name=airflow sync`.
2. 타임존을 안 바꾸고 cron 을 **UTC 로 환산**해 기입(예: 새벽 2시
   KST → `"0 17 * * *"` = 전일 17:00 UTC).

> 운영 배포 전 타임존 정책을 먼저 확정할 것. 안 그러면 "매일 새벽
> 적재" 의도가 실제로는 업무시간(09:00 KST)에 도는 식의 사고 발생.

---

## 4. 주기 ↔ 적재 모드 상호작용 (설계 팁)

`config/ingestion-map.yaml` 의 테이블 mode 와 함께 고려해야 한다:

- **`merge`(증분 커서)**: 매 실행 **델타만** 가져옴 → 자주 돌려도
  가볍다. 트랜잭션성/고변경 테이블은 짧은 주기 적합.
- **`replica`(full refresh + overwrite)**: 매 실행 **테이블 전체**
  재적재 → 큰 replica 테이블을 고빈도로 돌리면 소스 DB·S3·Trino
  부하가 큼. 설정성/소형 테이블 위주여야 하고 주기를 길게.

→ 한 소스 안에 merge/replica 가 섞여 있으므로, 주기는 그 소스에서
가장 무거운 replica 테이블 기준으로 보수적으로 잡는 게 안전하다.

---

## 5. 소스별로 다른 주기를 주고 싶다면

**현재는 4소스 균일**(`build_ingest_dag` 가 모든 source 에 동일
`"@daily"` 적용). 소스별 차등(예: pfms 는 1시간, maxapex 는 1일)은
지금 구조로는 안 됨 — 팩토리 파라미터화가 필요하다(개요):

- 안 A: `config/ingestion-map.yaml` 의 `sources.<name>` 에 `schedule`
  키를 추가하고, `build_ingest_dag(source)` 가 그 값을 읽어
  `schedule=` 에 주입(없으면 기본값 fallback 없이 명시 기본).
- 안 B: 팩토리 내부에 `SCHEDULES = {"pfms": "@hourly", ...}` 매핑.

SSOT 일관성상 안 A(ingestion-map)가 권장. 이 리팩터가 필요하면 별도
요청 — 본 문서는 "현재 구조에서 주기 정하는 법"이 범위.

---

## 6. 변경 적용 절차 (이미지 재빌드 0 · 폐쇄망 무접속)

`schedule` 은 **DAG 아티팩트**에 있다(커스텀 이미지에 미동봉 —
아티팩트 패턴). 따라서:

```bash
# 1) 주기 수정
#    dags/maxdl_factory.py 의 build_ingest_dag schedule= (전 소스 공통)
#    (또는 §5 구조면 config/ingestion-map.yaml 의 소스별 schedule)

# 2) 아티팩트 재발행 (vendored dbt_packages → dbt deps 없이, 무접속)
scripts/airflow-artifact-publish.sh

# 3) Airflow 가 새 아티팩트 refetch
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor
#   또는: helmfile -f helmfile.yaml -l name=airflow sync
#         (airflow presync 가 dbt-gen + 아티팩트 재발행까지 수행)
```

> 폐쇄망: `airflow-artifact-publish.sh` 는 vendored `dbt_packages/`
> 덕에 인터넷 없이 동작(`dbt deps` 자동 스킵). 이미지 재빌드 불필요.
> Airbyte 커넥션은 `scheduleType: "manual"` 그대로 — 건드리지 말 것
> (주기 권위는 Airflow DAG).

---

## 7. 검증 (변경이 먹었는지)

```bash
# DAG 의 현재 스케줄 확인
kubectl -n maxdl-orchestrate exec deploy/airflow-scheduler -- \
  airflow dags details ingest_maxplatform -o json 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("schedule:",d.get("timetable_summary") or d.get("schedule_interval"))'

# 다음 실행 예정 시각
kubectl -n maxdl-orchestrate exec deploy/airflow-scheduler -- \
  airflow dags next-execution ingest_maxplatform
```
- [ ] schedule 이 의도한 값으로 표시
- [ ] next-execution 이 **KST 환산상 의도한 시각**인지(§3 타임존)
- [ ] 1회 실제 실행 후 Trino 로 Bronze 증가 확인

---

## 8. 정직한 잔여·주의

- **타임존 미설정(UTC)** 이 가장 흔한 사고 지점 — 운영 전 §3 확정.
- 소스별 차등 주기는 **현재 미지원**(§5, 균일 `@daily`). 필요 시
  팩토리 파라미터화(별도 작업).
- `catchup=False` — 과거 미실행분 몰아치기 없음(의도). 과거 보정이
  필요하면 별도 backfill 전략 필요(자동 아님).
- 고빈도 + replica 대형 테이블 = 소스 DB/S3/Trino 부하. 주기는
  모드 구성 보고 보수적으로(§4).
- 주기를 줄여도(예: 매시간) 1순위 성능 튜닝(별도 docs/performance.md)
  미적용 상태면 Trino 처리량이 병목일 수 있음 — 적재 빈도와 처리
  용량을 함께 볼 것.
