# 폐쇄망 — 새 DB / 새 테이블 추가 (쉬운 순서)

폐쇄망(인터넷 X) 운영 중 **소스 DB 추가** 또는 **테이블 추가**를 가장
쉬운 순서로. 깊은 배경·트러블슈팅은 [`ADD_NEW_DATABASE.md`](./ADD_NEW_DATABASE.md)
(레퍼런스), 설치는 [`INSTALL_AIRGAP.md`](./INSTALL_AIRGAP.md).

> **2가지 경우 — 먼저 어느 쪽인지 판단:**
> - **흐름 A — 이미 연결된 DB 에 테이블만 추가**: 쉬움. 시크릿 불요.
>   `ingestion-map.yaml` 한 줄 + 재적용. → §A
> - **흐름 B — 새 소스 DB 통째 추가**: 시크릿·소스 4종(같은 패턴) 추가.
>   → §B (먼저 §0 폐쇄망 원칙 숙지)

---

## §0. 폐쇄망에서 반드시 알아야 할 1가지 (정직한 제약)

SSOT 는 `config/ingestion-map.yaml`. Airbyte 커넥션·dbt 모델·DAG 가
전부 이걸 따른다. **단, 폐쇄망에는 작업이 두 군데로 갈린다:**

| 작업 | 어디서 | 인터넷 |
|---|---|---|
| ingestion-map 편집, 시크릿 봉인(`seal-from-env.sh --cert`), Airbyte 커넥션 적용(`airbyte-apply-ingestion-map.sh`, in-cluster), Trino 검증, `dbt run` | **폐쇄망 호스트 B** | 불요 (✅) |
| dbt 아티팩트 **재생성·재발행**(`airflow-artifact-publish.sh`) | **온라인 호스트 A** | 필요 — `dbt deps` 가 허브 접근 |

이유: `dbt_packages/`(dbt_utils/expectations)는 레포에 vendored 라
**런타임·`dbt run` 은 폐쇄망에서 자족**이지만, 아티팩트 *발행* 단계의
`dbt deps && dbt parse` 는 허브를 친다. 그래서 **DAG/dbt 모델이 바뀌면
(= 새 테이블·새 소스 항상 해당) 아티팩트는 온라인 호스트 A 에서
재생성해 운반**한다. INSTALL_AIRGAP 의 "A 온라인 빌드 → 운반 → B" 와
동일 사이클. (이미지 재빌드는 불요 — 아티팩트 패턴.)

> 따라서 §A·§B 모두: **(1) 온라인 호스트 A 에서 SSOT 편집+아티팩트
> 재생성+재번들 → (2) 운반 → (3) 폐쇄망 호스트 B 에서 적용·검증** 구조.

---

## §A. 흐름 A — 기존 DB 에 테이블 추가 (쉬움)

### A-1. [호스트 A] ingestion-map 에 한 줄 추가
`config/ingestion-map.yaml` 의 해당 `sources.<DB>.tables:` 에 추가.
모드 규칙(헤더와 동일): **merge = PK 있고 시간커서 NOT NULL / 그 외 replica**.

```yaml
# 예) maxplatform 에 새 테이블 public.work_orders
      - { name: "public.work_orders", mode: merge, cursorField: "updated_at", primaryKey: ["id"] }
      - { name: "public.audit_dump",  mode: replica }   # 커서 nullable/PK 없음 → replica
```
> 대문자 테이블명(MSSQL/Oracle)은 **원본 그대로**(소문자화 금지).

### A-2. [호스트 A] seed 메타 추가 (dbt-gen 전제)
`config/source-schema.json` 에 새 테이블의 컬럼/PK 인벤토리를 추가
(replica 도 PK 보유). 없으면 `dbt-gen-models.sh` 가 **즉시 실패**
(fallback 없음 — 의도된 안전장치). 조사 방법은 ADD_NEW_DATABASE §2.

### A-3. [호스트 A] 모델 생성 + 아티팩트 재발행 + 재번들
```bash
scripts/dbt-gen-models.sh            # ingestion-map → stg_/int_ + sources.yml + seed (멱등, 무접속)
scripts/dbt-gen-models.sh --check    # 드리프트 0 확인
scripts/airflow-artifact-publish.sh  # dbt deps+parse → 새 아티팩트 tar (★ 온라인 필요)
```
> 폐쇄망 SeaweedFS 가 호스트 A 에서 도달 불가하면, 아티팩트 tar 를
> 매체로 운반해 폐쇄망 SeaweedFS 에 올리거나 `airgap-bundle`/운반 절차에
> 포함(INSTALL_AIRGAP §운반). 변경 레포(ingestion-map/source-schema/
> 생성된 models)도 함께 운반.

### A-4. [호스트 B] 폐쇄망에 적용
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; export PATH="/usr/local/bin:$PATH"
# (1) 변경 레포 반영 후 — Airbyte 커넥션 카탈로그를 ingestion-map 에 수렴(in-cluster, 무접속)
scripts/airbyte-apply-ingestion-map.sh --api http://localhost:30081 --set-airflow-vars
# (2) Airflow 가 새 아티팩트를 다시 받도록 재기동(initContainer 가 refetch)
kubectl -n maxdl-orchestrate rollout restart deploy/airflow-scheduler deploy/airflow-dag-processor
```
또는 변경 레포·아티팩트 반영 후 `helmfile -f helmfile.yaml sync` —
airbyte postsync(커넥션 수렴)·airflow presync 재실행으로 동일 수렴.

### A-5. [호스트 B] 검증
```bash
# Airbyte 동기화 1회(해당 소스 DAG 트리거 or UI) 후 Bronze 행수 확인
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "SELECT count(*) FROM iceberg_bronze.maxplatform.work_orders"
```
- [ ] Trino 로 Bronze 행수 > 0 · stg_/int_ 모델 빌드 통과(`dbt run --select staging intermediate`)
- [ ] (PII 컬럼 있으면) §C 마스킹 확인

---

## §B. 흐름 B — 새 소스 DB 추가

기존 4소스(maxplatform/maxapex/pfms/maxtdoracle)와 **완전 동일 패턴**.
새 이름을 `mynewdb`(PostgreSQL 예시)로 가정.

### B-1. [호스트 A] 시크릿 SSOT 3곳에 블록 추가
**(a)** `deploy/secrets/secrets.env.example`(커밋 템플릿) +
`deploy/secrets/secrets.env`(실제값, 미커밋) 에 블록 추가 — 기존
`SRC_MAXPLATFORM_*` 패턴 복제:
```bash
SRC_MYNEWDB_HOST='172.168.35.8'
SRC_MYNEWDB_PORT='5432'
SRC_MYNEWDB_DATABASE='mynewdb'
SRC_MYNEWDB_USERNAME='<계정>'
SRC_MYNEWDB_PASSWORD='<비밀번호>'
SRC_MYNEWDB_TYPE='postgres'          # postgres | mssql | oracle
# Oracle 이면 추가: SRC_MYNEWDB_SERVICENAME='xe'
```
**(b)** `deploy/secrets/secrets-spec.yaml` 에 Secret 항목 추가(기존
`src-db-maxplatform` 블록 복제, 이름/env 만 치환):
```yaml
  - name: src-db-mynewdb
    type: Opaque
    targets:
      - { namespace: maxdl-ingest, file: deploy/k8s/sealed/src-db-mynewdb.sealed.yaml }
    data:
      host: SRC_MYNEWDB_HOST
      port: SRC_MYNEWDB_PORT
      database: SRC_MYNEWDB_DATABASE
      username: SRC_MYNEWDB_USERNAME
      password: SRC_MYNEWDB_PASSWORD
      type: SRC_MYNEWDB_TYPE
      # Oracle 이면: serviceName: SRC_MYNEWDB_SERVICENAME
```

### B-2. [호스트 A] ingestion-map 에 소스 블록 추가
`config/ingestion-map.yaml` `sources:` 아래(기존 소스 블록과 동형):
```yaml
  mynewdb:
    connector: source-postgres        # source-postgres | source-mssql | source-oracle
    secret: src-db-mynewdb            # = secrets-spec 의 name
    replicationMethod: standard       # CDC 미사용(컬럼 커서)
    bronzeNamespace: mynewdb          # Bronze 네임스페이스(=소스명 권장)
    tables:
      - { name: "public.orders", mode: merge, cursorField: "updated_at", primaryKey: ["id"] }
      - { name: "public.audit_raw", mode: replica }
```
+ §A-2 와 동일하게 각 테이블을 `config/source-schema.json` 에 인벤토리.

### B-3. [호스트 A] DAG 소스 목록에 등록
`dags/maxdl_factory.py`:
```python
SOURCES = ("maxplatform", "pfms", "maxapex", "maxtdoracle", "mynewdb")
```
> 이 파일은 아티팩트로 배포됨 → **이미지 재빌드 불요**(B-5 재발행이면 충분).

### B-4. [호스트 A] 모델 생성 + 아티팩트 재발행 + 재번들
§A-3 와 동일: `dbt-gen-models.sh` → `--check` → `airflow-artifact-publish.sh`
(★온라인). 변경 레포 + 아티팩트 운반.

### B-5. [호스트 B] 폐쇄망 봉인·적용
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; export PATH="/usr/local/bin:$PATH"
# (1) 폐쇄망 클러스터 키로 새 시크릿만 재봉인·적용 (평문 디스크 미기록)
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/seal-from-env.sh --cert /tmp/pub.pem --only src-db-mynewdb --apply
shred -u /tmp/pub.pem
# (2) 소스/목적지/커넥션 멱등 생성 + Airflow Variable 세팅 (in-cluster, 무접속)
scripts/airbyte-apply-ingestion-map.sh --api http://localhost:30081 --set-airflow-vars
#   · Oracle 신규면 register-oracle-connector.sh 가 이 경로에 포함(idempotent)
# (3) Airflow 새 아티팩트 refetch
kubectl -n maxdl-orchestrate rollout restart deploy/airflow-scheduler deploy/airflow-dag-processor
```
> 또는 변경 레포+아티팩트 반영 후 `helmfile -f helmfile.yaml sync`
> (sealed postsync·airbyte postsync·airflow presync 가 동일 결과로 수렴.
> 단 새 시크릿은 sealed yaml 이 먼저 생성돼 있어야 하므로 (1) 선행).

### B-6. [호스트 B] 검증
- [ ] `kubectl get secret src-db-mynewdb -n maxdl-ingest` 존재
- [ ] Airbyte 소스 `src-mynewdb` connection-check succeeded
- [ ] `SELECT count(*) FROM iceberg_bronze.mynewdb.orders` > 0
- [ ] `ingest_mynewdb` DAG 노출, `airbyte_conn_mynewdb` Variable 설정됨

---

## §C. PII 컬럼이 있으면 (거버넌스)

표준 어휘만 Silver/Gold 노출. 소스 원본명이 다르면
`config/ingestion-map.yaml` 해당 테이블에:
```yaml
      - { name: "public.users", mode: merge, cursorField: "updated_at",
          primaryKey: ["id"], piiRename: { user_email: email, hp: phone } }
```
표준 어휘 자체가 늘면 `config/pii-columns.yaml` 갱신 후
`scripts/gen-trino-acl.sh` → `--check`. 적용 후:
```bash
kubectl rollout restart deployment trino-coordinator -n maxdl-query
```
(ACL ConfigMap 변경은 coordinator 자동 롤 안 됨 — 수동 재기동 필수.)

---

## §D. 보안·정직한 잔여 (필수 인지)

- **평문 시크릿 미커밋**: `secrets.env` 는 gitignore. 봉인본
  (`*.sealed.yaml`)·`secrets.env.example`(CHANGE_ME)만 커밋. `seal-from-
  env.sh` 는 평문을 디스크에 안 쓴다(메모리→kubeseal 파이프).
- **SeaweedFS 공유 주의**: 새 소스 적재는 `maxdl-warehouse` 전용 버킷
  안에서만. `maxplatform-*`/`maxapex-*` 버킷·`s3.json` 절대 미접근
  (운영 S3 다운 위험).
- **폐쇄망 아티팩트 제약(반복)**: `airflow-artifact-publish.sh` 의
  `dbt deps` 는 인터넷 필요 → **온라인 호스트 A 에서만** 재발행, 결과
  운반. 폐쇄망에서 직접 실행 시 실패(설계상, fallback 없음). `dbt run`
  자체와 `dbt-gen-models.sh` 는 폐쇄망 무접속 동작(packages vendored).
- **merge↔replica 오분류 위험**: 커서 nullable 인데 merge 로 두면
  Airbyte 증분 전체 실패. 불확실하면 replica(안전). 근거·사례
  ADD_NEW_DATABASE §0.2 / FOLLOWUPS FU-4.
- 첫 신규 소스는 폐기형 동일버전 호스트에서 1회 리허설 권장.
