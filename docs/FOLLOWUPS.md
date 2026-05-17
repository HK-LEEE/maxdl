# maxdl 후속과제 (운영 전환 전)

부트스트랩 0~8단계 완료 후, 운영 전 해결할 항목. 우선순위 순.
상태·근거는 플랜 현황 / `docs/RUNBOOK.md` 참조.

---

## FU-1. Oracle 인제스션 블로커 — ✅ 해결 (A안)

**문제**: Airbyte community 레지스트리의 Oracle 소스는 enterprise 전용
(`source-oracle-enterprise`) → OSS 에서 HTTP 403 entitlement.

**해결**: 커뮤니티 `airbyte/source-oracle:0.5.8`(Docker Hub 공개, postgres/
mssql 와 동일 라이선스 티어)를 **커스텀 소스 정의**로 등록 → entitlement 게이트
비대상(`custom:true, enterprise:false, isEntitled:true`). connection-check
succeeded. 4/4 소스 전부 검증.

**핵심 함정**: `create_custom` 은 kubectl port-forward 경유 큰 POST 에서
HTTP 000(연결 리셋). **반드시 in-cluster 호출**.
재현: `deploy/k8s/airbyte/register-oracle-connector.sh`(idempotent).

---

## FU-2. 권한 최소화 (root → 전용 principal) — ✅ 해결 〔P0·보안〕

**배경**: 스파이크 편의로 Polaris `root` principal 을 Trino(`polaris-oauth`)·
Airbyte 목적지가 공유 사용 중. 과도 권한.

**범위**:
- Polaris 서비스별 principal 생성: `svc-trino`(카탈로그 R/W),
  `svc-airbyte`(bronze W), `svc-dbt`(silver/gold R/W) — 카탈로그롤 분리·최소 grant
- SealedSecret(`polaris-oauth`, Airbyte 목적지 client) 교체, root 는
  부트스트랩 전용으로 봉인
- `catalog-bootstrap.sh` 에 principal/role 생성 idempotent 반영

**완료조건**: 각 서비스가 전용 principal 로 정상 동작 + root 토큰 미사용 확인,
권한 경계 negative test(Airbyte principal 로 silver 쓰기 거부 등).
**해결**: Polaris principal `svc-trino`(bronze RO + silver/gold RW),
`svc-airbyte`(bronze RW only) 생성. polaris-oauth(Trino)·Airbyte 목적지
자격을 전용 principal 로 교체, root 는 부트스트랩 전용. Positive/Negative
검증 통과(svc-trino bronze 쓰기 거부, Airbyte 목적지 check succeeded).
RBAC 배선 `catalog-bootstrap.sh` idempotent 반영. 자격은 SealedSecret 관리.

---

## FU-3. Airflow 커스텀 이미지 + DAG 전달 〔P1·기능·난이도 중〕

**배경**: 현 DAG 는 지연 import 스켈레톤. Cosmos/dbt-trino/providers-airbyte
미포함, DAG 는 PVC 빈 상태(git-sync 비활성).

**범위**:
- 커스텀 Airflow 이미지: `apache-airflow:3.2.0` + `astronomer-cosmos
  [kubernetes]`·`dbt-trino`·`apache-airflow-providers-airbyte` + dbt 프로젝트
  동봉 + 빌드시 `dbt parse` 로 `manifest.json` 베이크
- 사설 레지스트리 또는 `k3d image import` 결정
- DAG 전달: git-sync(원격 브랜치) 또는 PVC sync
- `maxdl_factory.py` placeholder → 실제 AirbyteTrigger/Cosmos DbtTaskGroup 활성

**완료조건**: 변환 DAG 가 Airflow UI 정상 파싱, dbt 태스크 실행 가능.
**의존성**: FU-4, 레지스트리 결정.

---

## FU-4. 실 Airbyte 커넥션 + dbt 모델 〔P1·기능·외부입력 필요〕

**배경**: `config/ingestion-map.yaml` `tables: []`, dbt sources `tables: []`
— mock 미생성 원칙으로 실 스키마 대기.

**범위**:
- 4개 소스 DB 대상 테이블·커서컬럼·PK·적재모드 확정(MES/LIMS/QMS/SPC)
- `ingestion-map.yaml` + `seeds/_source_ingestion_modes.csv` 채움
- Airbyte 커넥션 생성(스트림별 sync mode) → Bronze 적재
- dbt staging→intermediate(Silver)→marts(Gold, SPC 관제도-ready) 작성·테스트

**완료조건**: 1개 소스 end-to-end(Airbyte→Bronze→dbt→Superset) 통과.
**의존성**: **소스 테이블 스펙(도메인 제공)** — 핵심 블로커. FU-3.

---

## FU-5. 운영 시크릿 외부화 — ✅ 해결 〔P1·보안〕

**배경**: 개발 placeholder 가 chart values 평문 — Superset `SECRET_KEY`·
admin/admin, Airflow `webserverSecretKey`.

**범위**: 해당 값을 SealedSecret + 차트 `existingSecret`/`extraSecretEnv`
참조로 전환, 강한 무작위 값 재생성.
**해결**: Superset SECRET_KEY→SealedSecret(superset-secret, env 주입)·
admin 비번→SealedSecret(superset-admin, 배포시 --set)·Airflow
webserverSecretKey→SealedSecret(airflow-webserver-secret,
webserverSecretKeySecretName). 차트 values 평문 시크릿 0(grep 통과),
신규 admin 비번 로그인 검증. SECRET_KEY 회전으로 Superset 메타DB
초기화(개발, 무가치 상태).

---

## FU-6. helmfile 통합 + 재현성 — ✅ 해결(IaC) 〔P2·운영〕

**배경**: 계획상 `helmfile.yaml` 이 SSOT 였으나 실제론 개별 `helm install`.
부트스트랩 순서·의존성 미코드화.

**범위**: 8단계 배포를 `helmfile.yaml` 로 선언(릴리스·NS·values·needs
의존순서·hooks: SealedSecret apply, catalog-bootstrap, OM 시크릿, Oracle
커넥터 등록). 클린 클러스터에서 `helmfile apply` 단일 재현 검증.
**해결(IaC)**: `helmfile.yaml` 작성 — 9개 릴리스(버전 정확히 핀)·
`needs` 의존순서·hooks(네임스페이스/SealedSecret/Polaris bootstrap·
카탈로그·RBAC/Oracle 커넥터/Superset admin/OM NodePort)로 명령형 단계를
기존 idempotent 스크립트 호출로 코드화. 비파괴 검증: `helmfile build`/
`list` 통과, 평문 시크릿 0.
**잔여 AC**: 완전 클린 클러스터 `helmfile apply` 재구축 검증은 라이브 스택
파괴 방지를 위해 **폐기형 클러스터에서 수행 권장**(미수행).

---

## FU-7. 노출/관측/백업 〔P2·운영·난이도 중〕

- **노출**: NodePort(30000번대) → Ingress/TLS(운영). Airbyte 노출 방식 결정.
- **관측**: Prometheus/Grafana(ServiceMonitor 활성), 로그 수집.
- **백업**: Polaris PG·Airbyte/Airflow/Superset/OM 메타DB·Iceberg 스냅샷
  정책. SeaweedFS 는 maxplatform 공유 → 백업 책임 경계 명확화.

---

## 우선순위 요약

| 그룹 | 항목 |
|---|---|
| ✅ 완료 | FU-1, FU-2, FU-5, FU-6(IaC) |
| 외부 입력/결정 필요 | FU-4(소스 스펙), FU-3(레지스트리) |
| **독립 진행 완료** | ~~FU-2~~ ~~FU-5~~ ~~FU-6~~ ✅ (잔여: 클린 재구축 검증) |
| 운영 단계 | FU-7 |

독립 진행 항목(FU-2/5/6) **전부 완료**. 남은 항목: FU-3·FU-4(외부
입력/레지스트리 결정 필요), FU-7(운영 단계), FU-6 클린 재구축 검증.


## FU-4 진행 결과 (2026-05-17)

- ✅ **maxplatform/maxapex (Postgres)**: 전체 테이블 Bronze 적재 성공, Trino
  실데이터 조회 검증. 커서 규칙 정밀화 적용:
  **merge = PK 존재 AND temporal 커서가 NOT NULL** / 그 외 replica
  (Airbyte Postgres 소스는 nullable 커서를 incremental 에서 거부 → 전체 실패).
- ✅ maxtdoracle (Oracle): 커넥션 검증 완료(소스 빈 테이블, replica 분류).
- ⚠️ **pfms (MSSQL) 한계 (후속 과제 FU-4b)**: 소스 테이블명이 대문자
  (`PBATPRCDAT` 등). Airbyte S3-Data-Lake 목적지는 connection `aliasName`
  무시하고 `stream.name` 을 Iceberg 테이블명으로 사용. Trino Iceberg 커넥터는
  소문자 식별자만 load 가능(case-insensitive 옵션 없음). → 소스 매칭(대문자
  필요)과 Trino 조회(소문자 필요)가 양립 불가. 4개 테이블.
  옵션: (a) sync 후 Polaris renameTable 자동화(merge엔 부적합/replica 매 sync
  재생성), (b) 별도 케이스 변환/뷰 계층, (c) Spark 등 case-sensitive 엔진으로
  해당 네임스페이스 조회. 결정 필요.
- 운영 주의: `created_at`-만 커서인 테이블은 원천 UPDATE 미포착 가능 → 추후
  updated 컬럼 도입/주기 replica 검토(기존 기재 유지).
- 인시던트 학습: 디스크 회복 시 CoreDNS `host.k3d.internal` 항목 소실 →
  복구 필요(`kubectl patch cm coredns`). RUNBOOK 참조.
