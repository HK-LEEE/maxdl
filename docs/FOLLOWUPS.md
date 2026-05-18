# maxdl 후속과제 현황 (운영 전환 전)

부트스트랩 0~8단계 + 후속과제(FU-1~FU-8) 진행 현황을 **해결 / 잔여(제약) /
남은·보류** 로 통합 정리. 최종 갱신: 2026-05-18.
상태·근거 상세는 플랜 현황(`mes-lims-qms-fluffy-bubble.md`) / `docs/RUNBOOK.md` 참조.

---

## 1. ✅ 해결 완료

### 1.1 부트스트랩 0~8단계 (전 스택 가동)

부트스트랩 검증 데이터 경로:
Airbyte→Polaris→SeaweedFS(path-style) / Trino→Polaris→SeaweedFS R/W /
dbt→Trino(Iceberg TIMESTAMP6) / Superset→Trino. 엔드포인트 200:
Trino(30080)·Airflow(30082)·Superset(30088)·Polaris(30181, Iceberg
REST/관리 API). 양대 최고리스크(SeaweedFS path-style, Airbyte beta 목적지)
해소. (OpenMetadata 는 FU-9 에서 제거 — §3.0 참조. 계보=dbt docs.)

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
- **SeaweedFS 아티팩트 패턴 전환(이미지 재빌드 제거)**: dbt 프로젝트·DAG·
  manifest 를 이미지에 굽지 않고 버전 tar 로 SeaweedFS 발행
  (`scripts/airflow-artifact-publish.sh`), pod initContainer 가
  `scripts/s3artifact.py`(stdlib SigV4, 무의존)로 fetch→emptyDir 전개.
  이미지는 pip 패키지층만(안정). 새 모델/테이블 시 **이미지 재빌드 불필요**
  (아티팩트 재발행+롤아웃). 버전 env(`MAXDL_ARTIFACT_VERSION`, 기본 latest·
  운영 SHA 핀). helmfile presync 훅 배선. **라이브 컷오버 검증**: 슬림
  이미지로 4컴포넌트 initContainer fetch 성공, 5 DAG·manifest 아티팩트
  로드 확인. seaweedfs-s3 를 maxdl-orchestrate 에도 봉인(SSOT 반영).

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
- **dbt staging/Silver 모델 생성 IaC 화 완료**: `scripts/dbt-gen-models.sh`
  (멱등) — ingestion-map.yaml → 183 stg_ + 183 int_(merge=incremental
  dedup/replica=table) + `_staging__sources.yml` + seed CSV 결정적 생성.
  `--check` 로 **기존 366 .sql + sources.yml + CSV 바이트 동일 검증(드리프트
  0, CSV CRLF 보존)**. helmfile presync(publish 직전) 배선. Gold(marts)는
  도메인 로직이라 대상 아님(수작업 유지). → 새 테이블: ingestion-map 한 줄
  + gen + publish 면 Silver 까지 무인.
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

### 2.1 FU-6 클린 클러스터 재구축 — 핵심 블로커 ✅ 실증 해소

- **클러스터 키 결합 블로커 = 폐기형 클린 클러스터에서 실증 해소**:
  신규 k3d(`maxdl-rh`, 독립 sealed-secrets 키) 생성 → `seal-from-env.sh
  --cert <폐기형 공개키> --apply` 로 secrets.env SSOT 를 그 키로 재봉인·
  적용 → **폐기형 컨트롤러가 19개 SealedSecret 전부 복호화**(src-db host
  / seaweedfs endpoint / trino-svc-dbt 비번 교차검증). 즉 "SealedSecret
  클러스터 키 결합으로 클린 재구축 불가"라는 FU-6 의 실제 블로커는
  **닫힘**. 운영 클러스터 무영향·레포 churn 0(폐기형 삭제·복원).
  (앞서 단일노드 2nd 클러스터 미기동은 `--no-lb`+traefik disable 설정
  탓이었고 기본설정으로는 정상 — 정정.)
- **남은 것(블로커 아님, 환경 제약)**: 전 7릴리스 `helmfile apply` +
  거버넌스 데이터경로 풀 E2E 는 **공유 SeaweedFS(운영)와 co-tenant
  불가**(동일 Iceberg 버킷 손상 위험) → 격리 S3/전용 환경에서만 가능.
  IaC·시크릿·이미지번들·재봉인 이식 경로는 전부 완비·개별 검증됨;
  남은 것은 "격리 스토리지 1회 통합 실행"이며 코드 잔여 아님.
- **메타DB 영속 — 자동화 완료(실 k3s, 폴더 방식)**: `storageclass-
  retain.yaml`(maxdl-retain, Retain) + `scripts/setup-k3s-persistence.sh`
  (멱등: 폴더 생성→local-path-config 재지정→provisioner 재기동→
  maxdl-retain default 승격). helmfile 1단계 presync 에서 **`MAXDL_PERSIST=1`
  일 때만** 자동 실행(opt-in). 폴더=`MAXDL_PV_DIR`(기본 `<repo>/.maxdl-pv`,
  .gitignore). 전용 디스크 불요·번들 차트 values 무수정으로 전 PVC 영속.
  → 운영자 수동 = "폴더 선택" 하나, 나머지 helmfile apply 자동.
  **라이브 k3d 무손상**(MAXDL_PERSIST 미설정 → default SC 안 건드림,
  실측 확인). 정직: 레포내부 폴더면 격리/쿼터 없음·용량 확보 필요,
  Retain=수동정리, local-path=노드종속(멀티노드는 CSI 로 SC 교체).

---

## 3. 📋 남은 · 보류 Task

### 3.0 FU-9 조회 거버넌스 (유저단위·컬럼마스킹·중앙정책) — 진행 중

쿼리 접근 집행 부재(Trino 인증 없음, Polaris=서비스계정 레벨, OM=서술 전용)
확인. **최종 결정(스파이크·재검증 거쳐 수렴)**: 인증=Trino 파일기반
PASSWORD(SSO/JWT 미사용 — 단순화), 집행=**Trino 내장 file-based access
control**(Ranger 폐기 — 공식이미지 ZK/Solr/KDC 결합·무차트·폐쇄망 부담).
유저단위·컬럼마스킹·중앙정책을 신규 인프라 0 + 정책=git SSOT 로 충족.
GUI 정책편집만 포기(코드리뷰 거버넌스로 대체).

- **1단계 완료(코드화·검증, 라이브 미적용)**: `charts/trino/values.yaml`
  `authenticationType: password` + `auth.passwordAuthSecret=trino-password-db`
  + `allow-insecure-over-http=true`(사내망, TLS 는 FU-7). SSO/JWT 관련
  (`trino-sso`, `MAXDL_SSO_*`)은 제거. `helmfile template` exit 0 렌더 검증.
  **라이브 Trino 무변경** — 지금 켜면 자격 없는 Superset/dbt 즉시 차단되므로
  의도적 보류.
- **컷오버 전제(동시 충족 필요)**: ① Trino PASSWORD 인증 ②
  `trino-password-db`(htpasswd, secrets.env 유저비번→Secret 생성) +
  Airflow/dbt 프로필에 svc-dbt 주입 ③ Superset→Trino 실유저 임퍼소네이션.
  셋 다 준비돼야 1회 조율 컷오버.
- **2단계 완료(코드화·시크릿 생성, 비파괴)**: `scripts/gen-trino-password-db.sh`
  (secrets.env 평문→bcrypt→`trino-password-db` Secret key=password.db,
  멱등) + `trino-svc-dbt`(seal-from-env, TRINO_PASSWORD) 생성·봉인·적용.
  `profiles.yml`·Airflow env 를 **TRINO_METHOD 게이트(기본 none=현 무인증
  동작 그대로)**, TRINO_USER=svc-dbt, extraEnvFrom trino-svc-dbt 배선.
  helmfile trino presync 훅. `helmfile template` exit 0. **라이브 무변경**
  (시크릿만 생성, 재배포·인증 미적용 — 컷오버 때 TRINO_METHOD=ldap 플립).
- **3단계 완료(코드/자격 준비, 비파괴)**: svc-superset 신뢰 principal —
  gen-trino-password-db 에 포함(password-db = svc-dbt+svc-superset),
  `trino-svc-superset`(seal-from-env, SUPERSET_TRINO_PASSWORD, maxdl-bi)
  생성·봉인. Superset Trino 자산(`maxdl-trino-gold.yaml`) 목표상태로 갱신:
  `sqlalchemy_uri` svc-superset + `impersonate_user: true`(비번 평문 미커밋,
  컷오버 import 시 주입). **라이브 무변경**(Superset 재배포·재import 안 함,
  대시보드 무영향).
- **자원 실측(게이트 통과)**: 노드 ~90GiB 중 실사용 ~26GiB(여유 ~63GiB),
  CPU 2%. 과거 "2nd 클러스터 미기동"은 자원 아닌 k3d 부트스트랩 문제로
  판명 — 자원은 게이트 아님(추정 정정, 실측 기반).
- **4단계 전환·완료(코드화, 비파괴) — Ranger 폐기, B안 채택**: 스파이크로
  Ranger 공식 이미지는 있으나 ZK/Solr/KDC 결합 데브하니스라 폐쇄망·무차트
  부담 큼 확인 → **Trino 내장 file-based access control(B)** 로 전환
  (인프라 0, 정책=git JSON SSOT, 폐쇄망 부담 0). `charts/trino/values.yaml`
  `accessControl(configmap)` rules.json: svc-dbt 전계층 R/W, analysts 그룹
  Gold/Silver RO + **PII 컬럼명 패턴 마스킹**, svc-superset 임퍼소네이션,
  미매칭 거부. **정규식/그룹/계층 패턴 — 테이블 열거 없음 → 1000+ 테이블도
  규칙 한 줌**(group provider=file, groups.txt 가 운영 편집 표면).
  부수: 중복 키(server/coordinator) 통합 — Stage-1 잠재버그(server.workers
  유실) 동시 수정. `helmfile template` exit 0. **라이브 무변경**(코드-only,
  컷오버 활성).
- **5단계 = OpenMetadata 제거 확정·실행(✅)**: Ranger 폐기로 OM↔Ranger
  무의미 + OM 은 빈 상태(서비스 0)로 ~8 pod·~6GiB 데드웨이트 + 접근
  거버넌스는 Trino file-based 로 해결됨 → **OM 폐기**. 라이브
  `helm uninstall openmetadata/openmetadata-deps` + `maxdl-governance` NS
  삭제(타 NS 무영향 확인). IaC: helmfile 릴리스·repo, charts/openmetadata,
  deploy/k8s/openmetadata, sealed(airflow/mysql-secrets), secrets-spec/
  env.example OM 항목, namespaces·globals(30085) 제거. helmfile build OK
  (9→7 릴리스). 계보/카탈로그 = **dbt docs**(`dbt docs generate --static`
  를 artifact-publish 에 추가, manifest 기반 단일 HTML, 추가 인프라 0 —
  `target/static_index.html` or `dbt docs serve`). 계획서 거버넌스=OM
  결정 의도적 번복(근거 기록). 잔여: ARCHITECTURE/INSTALL/RUNBOOK 문서의
  OM 서술은 후속 문서패스 필요(상태 SSOT 는 본 문서).
- **컷오버 리허설 실시(라이브, 격리호스트 없음 — 롤백 대비)**: 리허설이
  실 버그 4건 적발(인터넷 있을 때 잡음 = 리허설 가치 입증):
  1. 차트 `auth.passwordAuthSecret` 가 `password-authenticator.properties`
     미생성 → 차트 auth 헬퍼 폐기, `additionalConfigFiles` 명시 생성(수정✅)
  2. `/etc/trino/password.db` subPath 가 차트관리 볼륨과 충돌(`not a
     directory`) → 별도 `/etc/trino-secrets` 시크릿마운트(수정✅)
  3. 인증 활성 시 `internal-communication.shared-secret` 필수 →
     `trino-internal` 시크릿 + `${ENV:}` 주입(수정✅)
  - **위 3건 수정 후 Trino 컷오버 검증 성공**: anon=401(인증강제)·
    svc-dbt=200·access-control=file 로드 확인.
  4. **(블로커) dbt-trino `method:ldap` 가 HTTPS 강제** → 평문 HTTP Trino 에
     `SSL WRONG_VERSION_NUMBER`. `http_scheme:http` 무시됨. 즉 **dbt(사람
     아닌 기계) 비밀번호 인증이 TLS 요구 → FU-9 컷오버가 FU-7(TLS, 사용자
     보류)에 결합**. 미해결.
  - 결과: dbt 경로 불가로 **라이브 즉시 롤백**(helm rollback trino r5/
    airflow r6) → 무인증 운영 복구 확인(anon=200, 전 pod 정상). 코드의
    Trino 측 3버그 수정은 보존(검증됨), `TRINO_METHOD` 는 none 게이트 유지.
- **컷오버 실행·검증 성공(라이브)**: 내부 self-signed TLS 적용 후 재시도
  성공. 추가버그(worker keystore.key 전역적용 crash)도 적발·수정
  (coordinatorExtraConfig 분리). 검증: Trino anon=401·svc-dbt=200·
  svc-superset=200·TLS8443·access-control=file, **dbt 'All checks passed!'**
  (https svc-dbt+CA), Superset 커넥션 갱신(svc-superset@8443/impersonate/
  verify=CA)·인증200. 거버넌스 라이브 강제 중.
- **컬럼 마스킹 작동 검증 완료(라이브)**: 마스킹 미작동은 rules.json
  버그(컬럼 name 에 정규식 사용 — Trino 는 리터럴만)였고, 리터럴 PII
  컬럼명 열거로 수정. Superset(admin→analysts 임퍼소네이션)에서
  dim_user.email='***-MASKED-***' 확인. **FU-9 전 경로 라이브 완성**
  (인증·내부TLS·임퍼소네이션·접근통제·컬럼마스킹).
- **거버넌스 운영 절차(중요)**: trinodb 차트는 access-control ConfigMap
  변경 시 coordinator 자동 롤아웃 안 함 → 정책(rules.json/groups.txt)
  변경 후 `kubectl rollout restart deployment trino-coordinator
  -n maxdl-query` 필수.
- **A안 완료(config 폭증 방지)**: `config/pii-columns.yaml` = PII 표준
  어휘 SSOT(email/phone/ssn/...). `ingestion-map.yaml` 테이블에 선택적
  `piiRename: {원본컬럼: 표준명}` → `dbt-gen-models.sh` 가 stg_ 에서
  원본을 star 제외하고 `"<원본>" as <표준>` alias 생성. Trino rules.json
  마스크목록은 **`scripts/gen-trino-acl.sh` 가 pii-columns.yaml 에서
  자동 생성(③ 완료)** — 수동 1:1 미러링 제거, `--check` 드리프트 게이트.
  table:.* 라 전 테이블 적용 → **테이블/소스 수 무관 config 길이 고정**.
  검증: piiRename 없을 때 366 .sql 바이트 동일(비파괴), gen-trino-acl
  멱등·스모크 통과. 워크플로: pii-columns.yaml 편집 → gen-trino-acl.sh
  → 커밋 → (반영) coordinator rollout restart.
- **② dbt-trino 인증서 검증 — ✅ 활성(해소)**: profiles `cert` 를
  TRINO_CERT(env, 기본 빈값=레거시·비파괴) 게이트로, Airflow 에
  `/etc/trino-ca/tls.crt`(마운트된 self-signed CA) 주입. `dbt debug`
  All checks passed + "SSL validation disabled" 경고 소멸 = 검증 활성·
  통과(cert SAN=trino.maxdl-query.svc.cluster.local=TRINO_HOST).
- **잔여(정직)**: 폐쇄망 이동 시 이 컷오버 구성 동반(TLS·시크릿 포함)
### 3.0c 설치 문서 (Ubuntu 베어 OS) — ✅ 완료

`docs/INSTALL_UBUNTU.md` — Ubuntu 24.04 베어 머신에서 Docker→CLI도구
→k3d→커스텀이미지→helmfile→검증까지 단계별(트러블슈팅 포함). 온라인
설치 경로(폐쇄망은 AIRGAP_RUNBOOK). 커스텀 이미지 maxdl/airflow:fu3
빌드 절차 포함(현재 빌드본 존재 확인).

### 3.0b P2 폐쇄망 배포 런북 — ✅ 완료

`docs/AIRGAP_RUNBOOK.md` — 0(P1 사전조건)~9(잔여) 단일 순서 절차서로
통합. 온라인 빌드(번들/아티팩트) ↔ 폐쇄망(클러스터·적재·재봉인·helmfile·
거버넌스·검증·운영) 분리, 단계별 검증 게이트·실패 시 행동·정직한 잔여
포함. 흩어진 airgap/secrets/INSTALL/RUNBOOK/FU-9 절차를 한 장으로.

### 3.0d 폐쇄망 단일 설치 절차서 + OS자동화 스크립트 — ✅ 완료

`docs/INSTALL_AIRGAP.md` — **OS 준비~가동을 한 파일**로 열거(A 온라인
빌드 → B 폐쇄망 OS/Docker/k3s/이미지 → C 시크릿/helmfile/검증 → D 정직
잔여). 신규 스크립트 2종으로 OS레벨 갭(폐쇄망 호스트 Docker·k3s 자체
설치 불가) 해소: `scripts/airgap-os-deps.sh`(온라인: Docker .deb closure
+ kubectl/helm/helmfile/kubeseal + k3s air-gap 자산 → os-deps.tar.gz),
`scripts/airgap-host-setup.sh`(폐쇄망: dpkg 오프라인 Docker → CLI →
k3s INSTALL_K3S_SKIP_DOWNLOAD → airgap-load 이미지 적재). bash -n 통과.
정직: 폐쇄망 대상이라 실행검증 불가 — 정석법대로 작성, Ubuntu 버전·
amd64 일치 시 보장(MANIFEST 비교 게이트), 첫 배포 전 동일버전 폐기형
호스트 리허설 권장.

`docs/INSTALL_CHECKLIST.md` — 위 절차의 **현장용 호스트별 체크박스**
(A 온라인 / 운반 / B-1~B-4 폐쇄망). "호스트 B 는 명령만 실행하면 끝?"
→ 자동은 B-2 한 줄뿐, secrets.env 실제값·무결성·검증 게이트는 수동
임을 명시한 절 포함.

### 3.0e 폐쇄망 DB/테이블 추가 가이드 — ✅ 완료

`docs/ADD_DB_TABLE_AIRGAP.md` — 운영 중 소스 추가의 쉬운 순서. 흐름
A(기존 DB 에 테이블만, 시크릿 불요) / 흐름 B(새 소스 DB, secrets.env+
secrets-spec+ingestion-map+SOURCES) 분리. **폐쇄망 완전 자족화**:
`dbt_packages/`(dbt_utils/expectations/dbt_date, 7.9M)를 .gitignore
제외해 레포 vendoring(package-lock.yml 핀과 함께 커밋) +
`airflow-artifact-publish.sh` 가 vendored 감지 시 `dbt deps`(허브) 자동
스킵, `ARTIFACT_REFRESH_DEPS=1` 일 때만 온라인 재설치. → 새 DB/테이블
추가 전 과정이 폐쇄망 한 곳에서 완결(온라인 호스트·이미지 재빌드
불요). 기존 `ADD_NEW_DATABASE.md`(깊은 레퍼런스)의 stale "이미지
재빌드" 2곳 정정 + 상호 포인터로 모순 제거.

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
| ⚠️ 잔여(환경) | FU-6 키결합 블로커 ✅실증해소(폐기형 재봉인·복호화 검증). 풀 E2E 단일실행만 격리스토리지 환경 필요(코드잔여 아님) |
| 📋 남은·보류 | FU-7 노출(사용자 보류, nginx+도메인+SSL 대기) · FU-7 관측/백업 · Gold 실 KPI(도메인 입력) · `_airbyte_sync` 개선(선택) |
