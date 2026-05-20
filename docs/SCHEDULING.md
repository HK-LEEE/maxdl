# maxdl 적재 주기(스케줄) 설정 가이드

데이터를 **얼마나 자주 가져올지**를 정하는 방법. 한 줄 요약:

> 주기는 **Airbyte 가 아니라 Airflow DAG 의 `schedule`** 에서 정한다.
> Airbyte 커넥션은 `scheduleType: "manual"` 로 고정되어 있고(Airflow
> 가 트리거하는 구조), Airbyte UI 에서 주기를 바꿔도 **무의미**하다.

---

## 1. 어디서 정하나 (SSOT = ingestion-map.yaml)

**소스별 schedule 은 `config/ingestion-map.yaml` 의
`sources.<name>.schedule` 단일 출처**에서 정한다. `dags/maxdl_factory.py`
는 모듈 로드 시 이 값을 읽어 DAG 에 주입(fallback 없음 — 누락 시 즉시
실패).

```yaml
sources:
  maxplatform:
    schedule: "@daily"               # ← 여기서 결정
    ...
  pfms:
    schedule: "0 */2 * * *"          # 예: 2시간마다 (소스별 차등 가능)
    ...
```

- **소스별 차등 가능** — 각자 다른 schedule 값 부여(아래 §5).
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

## 3. 타임존 (Asia/Seoul 로 설정됨)

`charts/airflow/values.yaml` 에 **`AIRFLOW__CORE__DEFAULT_TIMEZONE=
Asia/Seoul`** 가 코드화돼 있다. 따라서:

- `@daily` = **00:00 KST** (매일 자정 한국시각).
- cron `"0 2 * * *"` = **새벽 2시 KST** (의도 그대로).
- DAG 의 `start_date` 도 tz-인지 `pendulum.datetime(2026,1,1, tz="Asia/Seoul")`.

⚠ **첫 적용 시점**: 차트 변경이므로 `helmfile -f helmfile.yaml -l
name=airflow sync` 가 한 번 필요(아래 §6 절차에 포함). 적용 전엔
Airflow 기본 UTC 이고, 적용 후부터 KST 해석.

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

## 5. 소스별 차등 주기 (지원됨)

각 소스에 다른 주기를 지정 가능. `config/ingestion-map.yaml`:

```yaml
sources:
  maxplatform:
    schedule: "@daily"               # 일 1회 (설정성 위주)
    ...
  pfms:
    schedule: "0 */2 * * *"          # 2시간마다 (트랜잭션성 자주)
    ...
  maxapex:
    schedule: "0 3 * * *"            # 매일 03:00 KST
    ...
  maxtdoracle:
    schedule: "0 */6 * * *"          # 6시간마다
    ...
```

원칙: 각 소스에 **반드시 `schedule` 선언**(누락 시 DAG 파싱 즉시 실패
— fallback 없음). §4 의 모드 ↔ 주기 상호작용을 고려해 정한다.

---

## 6. 변경 적용 절차 (이미지 재빌드 0 · 폐쇄망 무접속)

주기 변경(schedule) 은 **DAG 아티팩트 + ingestion-map** 에 있다(둘
다 아티팩트 tar 에 포함). 타임존은 차트(env). 변경 종류별로:

### 6-1. 소스별 주기만 바꾸는 경우 (가장 흔함)
```bash
# config/ingestion-map.yaml 의 sources.<name>.schedule 수정 후
scripts/airflow-artifact-publish.sh          # 아티팩트 재발행(폐쇄망 무접속)
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor   # 새 아티팩트 refetch
#   또는: helmfile -f helmfile.yaml -l name=airflow sync
#         (presync 가 dbt-gen + 아티팩트 재발행까지 수행)
```

### 6-2. 타임존을 바꾸는 경우 (초기 1회)
```bash
# charts/airflow/values.yaml AIRFLOW__CORE__DEFAULT_TIMEZONE 수정 후
helmfile -f helmfile.yaml -l name=airflow sync
#   → Airflow pod 가 새 env 로 재기동, 이후 모든 cron 을 그 타임존으로 해석
```

> 폐쇄망: `airflow-artifact-publish.sh` 는 vendored `dbt_packages/`
> 덕에 인터넷 없이 동작(`dbt deps` 자동 스킵). 이미지 재빌드 불필요.
> 아티팩트 tar 에 **`config/ingestion-map.yaml` 자동 포함**되므로
> DAG 팩토리가 런타임에 소스별 schedule 을 SSOT 에서 읽는다.
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

- **타임존 = Asia/Seoul 코드화 완료**. 첫 적용 시 `helmfile -l
  name=airflow sync` 필요(§6-2). 적용 전엔 Airflow 기본 UTC.
- 소스별 차등 주기 **지원됨**(§5). 단 4 소스 전부 `schedule` 필수
  — 누락 시 DAG 파싱 즉시 실패(fallback 없음).
- `catchup=False` — 과거 미실행분 몰아치기 없음(의도). 과거 보정이
  필요하면 별도 backfill 전략 필요(자동 아님).
- 고빈도 + replica 대형 테이블 = 소스 DB/S3/Trino 부하. 주기는
  모드 구성 보고 보수적으로(§4).
- 주기를 줄여도(예: 매시간) 1순위 성능 튜닝(별도 docs/performance.md)
  미적용 상태면 Trino 처리량이 병목일 수 있음 — 적재 빈도와 처리
  용량을 함께 볼 것.
