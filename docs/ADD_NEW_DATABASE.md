# 신규 데이터베이스 연결 가이드 (초보자용)

이 문서는 maxdl 레이크하우스에 **새 소스 DB 한 개를 처음부터 끝까지 연결**하는 절차를 단계별로 설명한다. 초보자가 그대로 따라 할 수 있도록 각 명령에 "이게 무엇을 하는지" 한 줄 설명을 붙였고, "왜 그렇게 하는지" 도 함께 적었다. 실제 이 프로젝트에서 4개 소스(maxplatform/maxapex/pfms/maxtdoracle)를 연결할 때 쓴 절차와 동일하다.

> **굵게 표시한 경고는 반드시 지킬 것.** 어기면 운영 장애 또는 보안 사고로 이어진다.
>
> **폐쇄망 운영 중이면** 쉬운 순서·2가지 흐름(테이블만 추가 / 새 DB)·
> 폐쇄망 제약은 [`ADD_DB_TABLE_AIRGAP.md`](./ADD_DB_TABLE_AIRGAP.md) 를
> 먼저 보고, 이 문서는 깊은 배경·트러블슈팅 레퍼런스로 사용한다.

---

## 0단계: 개념 — 왜 이렇게 하는가

### 0.1 `config/ingestion-map.yaml` 이 SSOT(단일 진실원천)다

어떤 소스의 어떤 테이블을 어떤 방식으로 가져올지는 **오직 `config/ingestion-map.yaml` 한 곳**에서 정의한다. Airbyte 커넥션·dbt seed·dbt 모델·Airflow DAG 가 전부 이 파일의 결정을 따른다. 그래서 이 파일을 먼저 정확히 채우는 것이 가장 중요하다.

### 0.2 merge 와 replica 규칙 (핵심)

`ingestion-map.yaml` 헤더에 명시된 규칙:

> **merge = PK 존재 AND temporal(시간) 커서 컬럼이 NOT NULL** / 그 외 전부 = **replica**

| 모드 | 동작 | 조건 |
|---|---|---|
| `merge` | Airbyte `incremental` + `append_dedup` (변경분만 가져와 PK 로 중복 제거) | PK 가 있고, `created_at`/`updated_at` 같은 시간 커서 컬럼이 **NOT NULL** |
| `replica` | Airbyte `full_refresh` + `overwrite` (매번 전체를 통째로 다시 가져옴) | 위 조건을 못 채우는 모든 경우 |

**왜 커서 컬럼이 NOT NULL 이어야 하나?**
Airbyte 의 PostgreSQL 소스는 incremental(증분) 동기화에서 커서 컬럼에 NULL 값이 있으면 그 동기화를 **거부**한다. NULL 인 행은 "언제 변경됐는지" 판단할 수 없어 누락/오류가 생기기 때문이다. 그래서 커서가 nullable 이면 안전하게 `replica`(매번 전체 복제)로 분류한다. 이 규칙은 실제로 nullable 커서 때문에 전체 동기화가 실패한 사례를 겪고 정밀화한 것이다(FOLLOWUPS FU-4).

> CDC(Change Data Capture)는 **사용하지 않는다**. 컬럼 커서만 쓴다(`replicationMethod: standard`). `created_at` 만 커서인 테이블은 원천 UPDATE 를 못 잡을 수 있으니, 필요하면 `updated` 컬럼 도입이나 주기적 replica 를 검토한다(RUNBOOK 참조).

---

## 1단계: 소스 DB 자격증명을 SealedSecret 으로 봉인

> **🚨 절대 평문 자격증명(비밀번호 포함 YAML)을 git 에 커밋하지 말 것.** `.gitignore` 가 `*.plain.yaml` 등을 차단하지만, 안전한 임시 경로(`/tmp`)에 만들고 봉인 직후 즉시 삭제(shred)한다.

### 1.1 평문 Secret YAML 임시 작성

키 구조는 `config/ingestion-map.yaml` 의 `sources.<name>` 와 `src-db-*` SealedSecret 규약을 따른다. 소스 타입에 따라 키가 다르다.

```bash
# 이게 무엇인지: 새 소스 'mynewdb'(PostgreSQL 예시) 의 접속 정보를 임시 평문으로 작성.
#               namespace 는 반드시 maxdl-ingest (Airbyte 가 읽는 곳).
cat > /tmp/src-db-mynewdb.plain.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: src-db-mynewdb
  namespace: maxdl-ingest
type: Opaque
stringData:
  type: postgres            # postgres | mssql | oracle
  host: "172.168.35.8"
  port: "5432"
  username: "<소스 계정>"
  password: "<소스 비밀번호>"
  database: "<DB 이름>"
  # Oracle 인 경우 database 대신 serviceName 키 사용
EOF
```

> 키 구조(`type/host/port/username/password/database`, Oracle 은 `serviceName`)는 `ingestion-map.yaml` 의 `sources` 구조 및 기존 `src-db-*` 패턴을 따른다. 정확한 키 이름이 불확실하면 기존 봉인본을 참고하거나 [RUNBOOK §3](./RUNBOOK.md) 을 확인한다.

### 1.2 봉인 → 적용 → 평문 즉시 삭제

```bash
# 이게 무엇인지: 클러스터 컨트롤러 공개키로 평문 Secret 을 SealedSecret 으로 봉인.
#               (scripts/seal-secret.sh 는 kubeseal 래퍼; scope=strict)
scripts/seal-secret.sh /tmp/src-db-mynewdb.plain.yaml \
  deploy/k8s/sealed/src-db-mynewdb.sealed.yaml

# 이게 무엇인지: 봉인된 SealedSecret 을 클러스터에 적용(컨트롤러가 자동 복호화).
kubectl apply -f deploy/k8s/sealed/src-db-mynewdb.sealed.yaml

# 이게 무엇인지: 평문 파일을 복구 불가능하게 삭제 (커밋되는 일이 없도록).
shred -u /tmp/src-db-mynewdb.plain.yaml
```

봉인 결과(`deploy/k8s/sealed/src-db-mynewdb.sealed.yaml`)만 git 에 커밋한다.

---

## 2단계: 소스 introspection (테이블/컬럼/PK/nullable 조사)

규칙(0.2)을 적용하려면 소스의 **모든 테이블에 대해 PK 존재 여부와 커서 컬럼의 nullable 여부**를 알아야 한다. 이 프로젝트가 쓴 방식은 다음과 같다.

- **클러스터 내부에 임시 python pod** 를 띄워서 조사한다(클러스터→소스 DB 경로가 외부에서와 다를 수 있으므로 in-cluster 에서 본다).
- 드라이버: PostgreSQL → `psycopg2`, MSSQL → `pymssql`, Oracle → `oracledb`.
- **자격증명은 1단계의 SealedSecret 에서만 읽는다**(평문 재작성 금지).
- 조사 후 **pod 는 즉시 삭제**한다(자격이 메모리에만 머물도록).

조사 결과로 다음을 갱신한다.

1. `config/ingestion-map.yaml` 의 `sources.<name>` — 0.2 규칙으로 각 테이블에 `mode`(필요 시 `cursorField`/`primaryKey`) 부여.
2. `dbt/maxdl_transform/seeds/_source_ingestion_modes.csv` — `source,table,mode,cursor_field,primary_key` 한 줄씩 추가.
3. `config/source-schema.json` — 컬럼 인벤토리(`columns/primaryKey/cursor/mode`) 추가.

`ingestion-map.yaml` 항목 예시(실제 형식):

```yaml
sources:
  mynewdb:
    connector: source-postgres        # source-postgres | source-mssql | source-oracle
    secret: src-db-mynewdb            # 1단계에서 만든 SealedSecret 이름
    replicationMethod: standard       # CDC 미사용
    bronzeNamespace: mynewdb          # Bronze 네임스페이스(=소스 이름 권장)
    tables:
      - { name: "public.orders", mode: merge, cursorField: "updated_at", primaryKey: ["id"] }
      - { name: "public.audit_raw", mode: replica }
```

`_source_ingestion_modes.csv` 예시:

```csv
mynewdb,public.orders,merge,updated_at,id
mynewdb,public.audit_raw,replica,,
```

---

## 3단계: Airbyte — 소스/커넥션 생성 및 동기화

> **✅ 이 3단계는 이제 자동화됨.** `secrets.env`(자격) + `ingestion-map.yaml`
> (테이블/모드)만 채우면 `scripts/airbyte-apply-ingestion-map.sh` 가 소스·
> 목적지·커넥션을 멱등 생성/수렴하고 Airflow Variable 까지 세팅한다
> (helmfile airbyte hook 에 배선됨). 아래는 자동화가 내부적으로 수행하는
> 절차의 설명(수동 디버깅/이해용). Oracle 커뮤니티 커넥터 등록
> (`register-oracle-connector.sh`)과 svc-airbyte Polaris 자격 캡처
> (`catalog-bootstrap.sh`, 클린 재구축 시 201 자동)도 자동 경로에 포함.

### 3.1 소스 커넥터 정의

- PostgreSQL → `source-postgres`, MSSQL → `source-mssql` 은 Airbyte 기본 제공.
- **Oracle 은 커뮤니티 커스텀 등록이 필요**하다. enterprise 전용이라 OSS 에서 HTTP 403 이 나므로, 커뮤니티 `airbyte/source-oracle:0.5.8` 을 커스텀 정의로 등록한다.

```bash
# 이게 무엇인지: Oracle 커뮤니티 커넥터를 커스텀 소스 정의로 등록(idempotent).
#               이미 등록돼 있으면 건너뛴다.
bash deploy/k8s/airbyte/register-oracle-connector.sh
```

> **🚨 in-cluster 호출 필수.** Airbyte 의 `create_custom` 엔드포인트는 `kubectl port-forward` 경유 큰 POST 에서 연결 리셋(**HTTP 000**)이 난다. 위 스크립트는 클러스터 내부 curl Pod 로 호출하도록 작성되어 있으니 스크립트를 그대로 쓴다(FU-1).

### 3.2 소스 생성 → 스키마 discover → 커넥션 생성

Airbyte API 로 (a) 소스 생성(자격은 1단계 SealedSecret), (b) `discover_schema`, (c) 커넥션 생성을 수행한다. 커넥션 생성 시 **스트림별 syncMode 를 `ingestion-map.yaml` 의 mode 로 매핑**한다(`merge`→incremental/append_dedup, `replica`→full_refresh/overwrite). 목적지는 `ingestion-map.yaml` 의 `destination`(destination-s3-data-lake, Polaris 카탈로그 warehouse=`bronze`, SeaweedFS 버킷 `maxdl-warehouse`).

> **🚨 stream.name 은 소스 원본 그대로 둘 것 (대문자 소문자화 금지).**
> 과거 pfms(MSSQL) 의 대문자 테이블명(`PBATPRCDAT` 등)을 소문자로 바꿨다가 소스 매칭에 실패한 사례가 있다. Airbyte S3-Data-Lake 목적지는 connection `aliasName` 을 무시하고 `stream.name` 을 Iceberg 테이블명으로 쓴다. Trino 쪽은 `iceberg.rest-catalog.case-insensitive-name-matching=true`(FU-4b, `charts/trino/values.yaml` 에 적용됨)로 대소문자 무관 조회가 해결되므로, **stream.name 은 소스 원본(대문자 포함)을 유지**한다.

### 3.3 동기화 후 검증

```bash
# 이게 무엇인지: Bronze 에 적재된 행 수를 Trino 로 확인 (적재 성공 여부).
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "SELECT count(*) FROM iceberg_bronze.mynewdb.orders"
```

---

## 4단계: dbt 모델 생성 (Staging → Silver → 필요 시 Gold)

> **✅ Staging/Silver 는 자동화됨.** `scripts/dbt-gen-models.sh` 가
> `ingestion-map.yaml` 에서 `stg_*`/`int_*`(merge/replica) + `_staging__
> sources.yml` + seed CSV 를 결정적 생성한다(기존과 바이트 동일 검증됨,
> helmfile presync 배선). **새 테이블에 staging/Silver 를 손으로 짜지
> 않는다** — ingestion-map 갱신 후 이 스크립트만 실행. 아래 4.1~4.2 는
> 생성 결과의 구조 설명(이해/디버깅용). **Gold(4.3)만 도메인 수작업.**
>
> **PII 거버넌스(FU-9/A)**: PII 컬럼은 `config/pii-columns.yaml` 표준
> 어휘(email/phone/ssn/...)로만 Silver/Gold 에 노출한다. 소스 원본명이
> 다르면 `ingestion-map.yaml` 의 해당 테이블에
> `piiRename: { <원본컬럼>: <표준명> }` 선언 → 생성기가 stg_ 에서 표준명
> 으로 alias. Trino 컬럼 마스킹은 그 표준 어휘만 보므로 소스/테이블 수가
> 늘어도 마스킹 설정은 불변(rules.json 변경 시 `kubectl rollout restart
> deployment trino-coordinator -n maxdl-query` 필수).

### 4.1 staging (Bronze → 정제 view)

`models/staging/<source>/stg_<source>__<table>.sql` 을 생성한다. 실제 패턴(`stg_maxtdoracle__production_log.sql` 참고):

```sql
-- Bronze → staging cleaned view (저장 비용 0)
{{ config(materialized='view') }}
select
    {{ dbt_utils.star(from=source('mynewdb', 'orders'),
        except=['_airbyte_raw_id', '_airbyte_meta',
                '_airbyte_generation_id', '_airbyte_extracted_at']) }},
    _airbyte_extracted_at as _bronze_extracted_at_epoch,
    {{ maxdl_audit_columns() }}
from {{ source('mynewdb', 'orders') }}
```

- `dbt_utils.star(... except=[...])` 로 Airbyte 메타 컬럼을 제외한다.
- `maxdl_audit_columns()` 매크로로 `_maxdl_loaded_at` / `_maxdl_run_id` 감사 컬럼을 표준 부착한다(`macros/trino_overrides.sql`).
- staging 결과는 `iceberg_silver` 의 `staging` 스키마에 view 로 만들어진다(`svc-trino` 가 bronze 에 RO 이므로). 소스 정의는 `models/staging/_staging__sources.yml` 에 `name/database=iceberg_bronze/schema=<source>` + 테이블 목록으로 추가한다.

### 4.2 intermediate (Silver)

`models/intermediate/<source>/int_<source>__<table>.sql`. 모드별로 다르다.

- `replica` → 정제 passthrough, 전체 교체(`materialized='table'`). 실제 예(`int_maxtdoracle__production_log.sql`):

```sql
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_mynewdb__audit_raw')) }}
from {{ ref('stg_mynewdb__audit_raw') }}
```

- `merge` → incremental + `merge` 전략(`unique_key`=PK 기준 최신 dedup). 증분전략은 `macros/get_incremental_strategy.sql` 의 `maxdl_incremental_strategy('merge')` 로 데이터 주도한다.

### 4.3 Gold 마트(필요 시)

도메인 규칙(MES/LIMS/QMS/SPC)이 필요하므로 자동 생성 대상이 아니다. 기존 `models/marts/` 패턴을 참고해 도메인 요구에 맞게 작성한다.

### 4.4 실행

```bash
# 이게 무엇인지: 새 소스의 staging + intermediate 모델만 빌드.
cd dbt/maxdl_transform
TRINO_HOST=localhost TRINO_PORT=30080 \
  /tmp/dbtvenv/bin/dbt run --select staging intermediate --profiles-dir .
```

> 대량 모델 빌드 시 `--threads 2` 등으로 동시성을 낮춘다. Trino 메모리 부족(OOM) 교훈이 있으니 단일 노드에서 무리한 병렬을 피한다([RUNBOOK](./RUNBOOK.md) OOM 항목).

---

## 5단계: 오케스트레이션 등록

`dags/maxdl_factory.py` 가 `SOURCES` 튜플 기반으로 DAG 를 자동 생성한다. 신규 소스를 추가하려면:

1. `dags/maxdl_factory.py` 의 `SOURCES = ("maxplatform", "pfms", "maxapex", "maxtdoracle")` 에 새 소스 이름을 추가한다(`maxdl_dags.py` 가 이를 읽어 `ingest_<source>` DAG 와 Gold 트리거를 자동 등록).
2. Airflow Variable `airbyte_conn_<source>` 에 3단계에서 만든 Airbyte 커넥션 ID 를 주입한다.

```bash
# 이게 무엇인지: 새 소스의 Airbyte 커넥션 ID 를 Airflow 변수로 등록
#               (DAG 가 var.value.get('airbyte_conn_<source>') 로 읽는다).
kubectl exec -n maxdl-orchestrate deploy/airflow-scheduler -- \
  airflow variables set airbyte_conn_mynewdb "<커넥션 UUID>"
```

> **이미지 재빌드 불요(아티팩트 패턴).** DAG·dbt 는 이미지에 동봉되지
> 않고 SeaweedFS 아티팩트 tar 로 배포된다. `SOURCES` 를 바꿨으면
> `scripts/airflow-artifact-publish.sh` 로 아티팩트만 재발행하고 Airflow
> 컴포넌트를 재기동(initContainer 가 refetch)하면 된다. 폐쇄망에서는
> 재발행이 온라인 호스트 몫(`dbt deps` 인터넷 필요) — `ADD_DB_TABLE_AIRGAP.md` §0.

---

## 6단계: 트러블슈팅 표

| 증상 | 원인 | 해결책 |
|---|---|---|
| Airbyte incremental 동기화 전체 실패 | 커서 컬럼이 nullable(NULL 포함) | 해당 테이블을 `replica` 로 재분류(0.2 규칙). `ingestion-map.yaml`/seed/커넥션 수정 |
| Trino 에서 대문자 테이블 미조회 | stream.name 을 소문자화함 / 카탈로그 옵션 미적용 | stream.name 을 소스 원본(대문자) 유지. Trino 카탈로그에 `case-insensitive-name-matching=true` 확인(`charts/trino/values.yaml`, FU-4b) |
| Trino "Failed to list views" | bronze 카탈로그롤에 VIEW_* 권한 부재 | `catalog-bootstrap.sh` 재실행(`cr-bronze-ro` 에 VIEW_LIST/VIEW_READ_PROPERTIES/VIEW_FULL_METADATA 부여, idempotent) |
| `host.k3d.internal` 미해석(클러스터→호스트/SeaweedFS 끊김) | 디스크 회복 후 CoreDNS 항목 소실 | `kubectl patch cm coredns` 로 항목 복구([RUNBOOK](./RUNBOOK.md) 인시던트 학습) |
| Polaris/Airbyte 토큰 만료 또는 401 | OAuth2 토큰 수명 만료 | 부트스트랩/검증 스크립트 재실행으로 토큰 재발급(`catalog-bootstrap.sh` 등) |
| Airbyte `create_custom` HTTP 000 | port-forward 경유 큰 POST 연결 리셋 | **in-cluster 호출**(`register-oracle-connector.sh` 그대로 사용, FU-1) |
| dbt run 중 Trino OOM | 과도한 동시성 | `--threads` 축소(예: 2), 모델 분할 실행([RUNBOOK](./RUNBOOK.md)) |

---

## 7. 최종 체크리스트

- [ ] 0단계: merge/replica 규칙(PK + NOT NULL 커서)을 이해했다
- [ ] 1단계: `src-db-<name>` SealedSecret 봉인·적용 완료, **평문 shred 완료**, 봉인본만 커밋
- [ ] 2단계: in-cluster pod 로 introspection, pod 삭제 완료
- [ ] 2단계: `ingestion-map.yaml` + `_source_ingestion_modes.csv` + `source-schema.json` 갱신
- [ ] 3단계: (Oracle 시) 커스텀 커넥터 등록, 소스/커넥션 생성, **stream.name 원본 유지**
- [ ] 3단계: Trino 로 `iceberg_bronze.<name>.<table>` 행 수 검증
- [ ] 4단계: staging/intermediate 모델 생성·`dbt run` 통과
- [ ] 5단계: `SOURCES` 추가 + `airbyte_conn_<name>` Variable 주입 + 아티팩트 재발행(이미지 재빌드 아님)
- [ ] 보안: **평문 시크릿 미커밋**, **운영 SeaweedFS 버킷(`maxdl-warehouse` 외) 미침범** 재확인
