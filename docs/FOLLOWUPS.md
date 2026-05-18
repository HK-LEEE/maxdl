# maxdl 후속과제 현황 (운영 전환 전)

부트스트랩 0~8단계 + 후속과제(FU-1~FU-8) 진행 현황을 **해결 / 잔여(제약) /
남은·보류** 로 통합 정리. 최종 갱신: 2026-05-18.
상태·근거 상세는 플랜 현황(`mes-lims-qms-fluffy-bubble.md`) / `docs/RUNBOOK.md` 참조.

---

## 1. ✅ 해결 완료

### 1.1 부트스트랩 0~8단계 (전 스택 가동)

7개 네임스페이스 0 비정상. 검증된 데이터 경로:
Airbyte→Polaris→SeaweedFS(path-style) / Trino→Polaris→SeaweedFS R/W /
dbt→Trino(Iceberg TIMESTAMP6) / Superset→Trino. 엔드포인트 200:
Trino(30080)·Airflow(30082)·Superset(30088)·OpenMetadata(30085)·
Polaris(30181, Iceberg REST/관리 API). 양대 최고리스크(SeaweedFS path-style,
Airbyte beta 목적지) 해소.

### 1.2 FU-1. Oracle 인제스션 블로커 — ✅ 해결 (A안)

community 레지스트리 Oracle 소스가 enterprise 전용(HTTP 403). 커뮤니티
`airbyte/source-oracle:0.5.8` 을 **커스텀 소스 정의**로 등록 → entitlement
비대상. connection-check succeeded, 4/4 소스 검증.
함정: `create_custom` 은 in-cluster 호출 필수(port-forward 시 HTTP 000).
재현: `deploy/k8s/airbyte/register-oracle-connector.sh`(idempotent).

### 1.3 FU-2. 권한 최소화 (root → 전용 principal) — ✅ 해결 〔보안〕

Polaris principal `svc-trino`(bronze RO + silver/gold RW)·`svc-airbyte`
(bronze RW only) 생성, root 는 부트스트랩 전용. Positive/Negative 검증 통과
(svc-trino bronze 쓰기 거부, Airbyte 목적지 check succeeded). RBAC 배선은
`catalog-bootstrap.sh` idempotent 반영, 자격은 SealedSecret 관리.

### 1.4 FU-3. Airflow 커스텀 이미지 + Cosmos 오케스트레이션 — ✅ 해결

- 커스텀 이미지 `maxdl/airflow:fu3`(apache/airflow 3.2.1 +
  astronomer-cosmos[kubernetes] 1.14.1 + dbt-trino 1.10.1 + dbt-core
  1.11.10 + providers-airbyte, dbt 프로젝트·DAG 동봉, 빌드시 manifest
  베이크). `k3d image import` → `pullPolicy: Never`.
- `maxdl_factory.py`: Airbyte API sync(폴링) → Cosmos DbtTaskGroup
  (staging+intermediate, 소스별) → 전 소스 완료 시 Asset 트리거로
  transform_gold(marts). Airflow 3.x API(`airflow.sdk`, providers.standard)
  반영.
- **동시성 상한 적용**: `MAX_ACTIVE_RUNS_PER_DAG=1`,
  `MAX_ACTIVE_TASKS_PER_DAG=4`, `PARALLELISM=8`(env 가 chart cfg 보다 우선·
  KE pod 전파 확실). unpause 자동 scheduled run 과 manual 트리거가 동일
  Airbyte 커넥션에서 충돌하던 문제를 구조적으로 차단.
- **E2E 검증 완료**: 4개 ingest DAG + transform_gold 전부 성공
  (pfms 9/9, maxtdoracle 3/3, maxapex 149/149, maxplatform 209/209,
  transform_gold 5/5).

### 1.5 FU-4. 실 인제스션 매핑 + dbt 모델 — ✅ 해결

- `config/ingestion-map.yaml`(183 테이블, SSOT) + `config/source-schema.json`
  (2450 컬럼 인벤토리, 메타데이터만). 적재모드 규칙 정밀화:
  **merge = PK 존재 AND temporal 커서 NOT NULL / 그 외 replica**
  (Airbyte Postgres 소스는 nullable 커서를 incremental 에서 거부).
- 4/4 소스 Bronze 적재·Trino 실데이터 조회 검증
  (maxplatform/maxapex Postgres, pfms MSSQL, maxtdoracle Oracle).
- dbt: staging 183 + intermediate(Silver) 183 + marts(Gold) 5개 샘플
  (mes/qms, 의미상 적정 판단). `dbt debug`/`deps`/run 검증, Iceberg
  TIMESTAMP(6) 리스크 해소.
- **커넥션 카탈로그 IaC 화 완료**: `scripts/airbyte-apply-ingestion-map.sh`
  (멱등) — ingestion-map.yaml 을 단일 권위로 4커넥션 syncCatalog 수렴
  + Airflow Variable `airbyte_conn_<src>` 세팅, helmfile airbyte hook 배선.
  드리프트 실측·교정: maxapex 뷰 6개(yaml 비대상) 해제, maxtdoracle
  PRODUCTION_LOG 등록 → 4/4 라이브 = yaml 정확 일치, 재실행 변경 0.
- **소스/목적지 프로비저닝 IaC 화 완료**: applier 에 프로비저닝 단계 추가
  — 소스 4종은 `src-db-*` 시크릿 + 라이브 역추출 known-good 템플릿
  (postgres/mssql/oracle)으로 멱등 ensure(검증: check_connection
  succeeded). 목적지는 `seaweedfs-s3` + `polaris-airbyte` 시크릿으로 ensure.
  svc-airbyte Polaris 자격은 `catalog-bootstrap.sh` 가 principal 신규
  생성(201) 시 캡처 → `polaris-airbyte`(maxdl-ingest) Secret 영속(기존이면
  멱등 스킵, 동작 자격 미파손). → **사람은 secrets.env + ingestion-map.yaml
  만 관리**, 나머지(소스/목적지/커넥션/Airflow Var) 전부 자동.
- **정직한 단일 잔여**: *이미 부트스트랩된* 클러스터의 기존 svc-airbyte
  자격은 Polaris 가 평문 비반환·rotate 권한 제약(403)으로 회수 불가 →
  현재 클러스터의 목적지는 기존 자격 보존(스킵). **클린/폐쇄망 재구축은
  201 캡처 경로로 완전 재현**(이 경우만 영향, 신규 환경엔 무해).

### 1.6 FU-4b. pfms 대문자 식별자 — ✅ 해결 (정석)

근본 원인은 Trino 설정. Trino Iceberg REST 카탈로그에
`iceberg.rest-catalog.case-insensitive-name-matching=true`(+`.cache-ttl`)
적용(앞선 크래시는 잘못된 generic 속성명 때문). Trino 480→**481**(이미지
태그 오버라이드). pfms 4테이블 stream.name 원본 유지 → 소스 매칭 + Trino
case-insensitive 조회. **실데이터 검증 완료**. 커스텀 코드 불필요,
**테이블 수 무관 무한 확장**(카탈로그 속성 1개).

### 1.7 FU-5. 운영 시크릿 외부화 — ✅ 해결 〔보안〕

Superset SECRET_KEY → SealedSecret(env 주입), admin 비번 → SealedSecret
(배포시 --set), Airflow webserverSecretKey → SealedSecret. 차트 values
평문 시크릿 0(grep 통과). SECRET_KEY 회전으로 Superset 메타DB 초기화
(개발, 무가치 상태).

### 1.8 FU-6. helmfile 통합 — ✅ 해결 (IaC)

`helmfile.yaml` — 9개 릴리스(버전 정확히 핀)·`needs` 의존순서·hooks
(네임스페이스/SealedSecret/Polaris bootstrap/카탈로그·RBAC/Oracle 커넥터/
Superset admin/OM NodePort)로 명령형 단계를 idempotent 스크립트 호출로
코드화. 비파괴 검증: `helmfile build`/`list` 통과, 평문 시크릿 0.
(→ 클린 클러스터 재구축 검증은 §2.1 잔여)

### 1.9 FU-8. Superset 6.x 업그레이드 — ✅ 해결

Superset 5.0.0(2단계 stale) → **6.1.0**(이미지 태그 오버라이드, 차트는
5.0.0 까지만 발행). bootstrapScript 로 psycopg2-binary + trino[sqlalchemy]
설치. Trino 데이터소스 등록 + test_connection 200, Gold 마트 대시보드
렌더 검증.

---

## 2. ⚠️ 잔여 (제약 — 사용자 결정으로 보류)

### 2.1 FU-6 클린 클러스터 helmfile 재구축 검증

완전 클린 클러스터에서 `helmfile apply` 단일 재현 검증은 **미수행**.
- **제약(해소)**: SealedSecret 의 클러스터 키 바인딩 문제는 평문 SSOT
  재봉인 도구로 해결됨 — `deploy/secrets/{secrets-spec.yaml,
  secrets.env.example}` + `scripts/seal-from-env.sh`. 대상 클러스터
  공개키로 `seal-from-env.sh --cert <pub> --apply` 1회면 전
  SealedSecret 재봉인·적용(현재 16개 역추출·검증 완료, 서버 dry-run
  `configured`). 평문 `secrets.env` 는 gitignore.
- **잔여**: 완전 클린 클러스터에서의 `helmfile apply` 단일 실증 자체는
  폐기형 클러스터에서 수행 권장(사용자 보류 중). IaC·시크릿 이식 경로는
  완비.

---

## 3. 📋 남은 · 보류 Task

### 3.1 FU-7 노출(Ingress/TLS) — 사용자 보류

NodePort(30000번대) → Ingress/TLS 운영 노출. 사용자가 추후 직접 요청 시
진행. 전제(사용자 제공 예정): ① ingress-nginx ② 확정 도메인
③ 정식 SSL 인증서. 단일노드 self-signed/NodePort 우회가 아닌, 실 도메인 +
정식 인증서 기반 ingress-nginx 구성.

### 3.2 FU-7 관측 / 백업 — 미착수

- **관측**: Prometheus/Grafana(ServiceMonitor 활성), 로그 수집.
- **백업**: Polaris PG · Airbyte/Airflow/Superset/OM 메타DB · Iceberg
  스냅샷 정책. SeaweedFS 는 maxplatform 공유 → 백업 책임 경계 명확화.

### 3.3 Gold 실 KPI 정의 — 도메인 입력 필요

현재 Gold 마트는 5개 샘플(mes/qms). 실 MES/LIMS/QMS/SPC KPI(예: SPC
관제도 Cp/Cpk, 수율, 불량률)는 **도메인 스펙 입력**이 있어야 정의 가능.

### 3.4 (선택) `_airbyte_sync` 동시 sync 처리 개선

현재 동일 Airbyte 커넥션 동시 sync 충돌은 `max_active_runs_per_dag=1`
구조로 회피. 코드 레벨의 실행중 사전체크/큐잉은 선택 개선 사항.

### 3.5 운영 주의 (기재 유지)

- `created_at`-만 커서인 테이블은 원천 UPDATE 미포착 가능 → 추후
  updated 컬럼 도입/주기 replica 검토.
- 디스크 회복 시 CoreDNS `host.k3d.internal` 항목 소실 → 복구 필요
  (`kubectl patch cm coredns`). RUNBOOK 참조.
- maxtdoracle 는 소문자 stream.name 적재 — 일관성 위해 추후 원본명
  재생성 가능(소스 빈 테이블, 우선순위 낮음).

---

## 4. 요약 표

| 그룹 | 항목 |
|---|---|
| ✅ 해결 완료 | 부트스트랩 0~8, FU-1, FU-2, FU-3(동시성 상한 포함), FU-4, FU-4b, FU-5, FU-6(IaC), FU-8 |
| ⚠️ 잔여(보류) | FU-6 클린 클러스터 재구축 검증(SealedSecret 클러스터 키 결합 — 사용자 보류) |
| 📋 남은·보류 | FU-7 노출(사용자 보류, nginx+도메인+SSL 대기) · FU-7 관측/백업 · Gold 실 KPI(도메인 입력) · `_airbyte_sync` 개선(선택) |
