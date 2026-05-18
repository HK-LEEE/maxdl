# maxdl 설치 방법

본 문서는 `helmfile.yaml`, `deploy/k8s/`, `charts/*/values.yaml`, `deploy/airflow-image/Dockerfile` 에 코드화된 절차를 그대로 반영한다. 접속 정보·자격증명·검증 명령은 [`docs/RUNBOOK.md`](./RUNBOOK.md) 와 일관성을 유지한다.

---

## 1. 사전 요구 사항

### 1.1 도구

RUNBOOK §1 에 따라 다음 CLI 가 `~/.local/bin` 에 설치되어 있어야 한다.

| 도구 | 용도 |
|---|---|
| `kubectl` | K8s 조작 |
| `helm` | 차트 설치 |
| `helmfile` | 전 스택 선언적 배포(SSOT) |
| `k3d` | k3s 기반 로컬 K8s 클러스터(이미지 import 포함) |
| `kubeseal` | 평문 Secret → SealedSecret 봉인 |

추가로 **Docker**(SeaweedFS·소스 DB 가 외부에서 동작, k3d 가 Docker 위에서 동작)가 필요하다.

### 1.2 외부 의존

- **SeaweedFS S3**(공유): 외부 Docker, maxplatform 운영과 동거. maxdl 은 전용 버킷 `maxdl-warehouse` 만 사용한다. **운영 SeaweedFS 의 다른 버킷·`s3.json` 을 절대 침범하지 말 것**(MEMORY: s3.json 편집은 prod S3 다운 위험).
- **소스 DB 접근**: 외부 172.168.35.8 (maxplatform / pfms / maxapex / maxtdoracle). 자격증명은 SealedSecret(`src-db-*`)으로 사전 봉인되어 `deploy/k8s/sealed/` 에 커밋되어 있어야 한다.

### 1.3 디스크

> **주의 — 디스크 포화 인시던트 교훈**: 단일 노드 k3d 에서 디스크가 포화되면 kubelet 이 `DiskPressure` 로 파드를 축출(eviction)하고, 디스크 회복 시 CoreDNS 의 `host.k3d.internal` 항목이 소실되어 클러스터→호스트 SeaweedFS S3/소스 DB 해석이 깨진 사례가 있다(FOLLOWUPS FU-4 인시던트 학습). 충분한 디스크를 확보하고, 복구 시 `kubectl patch cm coredns` 가 필요할 수 있다. 상세는 [RUNBOOK](./RUNBOOK.md) 참조.

---

## 2. 설치 순서

순서·의존성·hooks 는 `helmfile.yaml` 의 `needs` / `hooks` 정의를 그대로 따른다. 단일 명령 경로는 [§3](#3-단일-명령-경로-helmfile-apply) 를 사용한다.

### 0단계: k3d 클러스터 생성

- 30000번대 NodePort 가 호스트로 매핑되도록 포트 매핑(정책: 30000번대 — Trino 30080, Airbyte 30081, Airflow 30082, Superset 30088, Polaris 30181).
- 단일 노드 환경에서 디스크 포화 시 과도한 eviction 을 피하도록 kubelet eviction 완화 옵션을 적용한다.

> 정확한 k3d 생성 명령(포트 매핑·eviction 완화 플래그)은 환경 의존적이므로 [RUNBOOK](./RUNBOOK.md) 의 클러스터 생성 절차를 신뢰원천으로 사용한다. 클러스터는 `maxdl`(k3s 단일노드).

### 1단계: 네임스페이스 + Sealed Secrets 컨트롤러 + SealedSecret 적용

`helmfile.yaml` 의 첫 릴리스 `sealed-secrets`(`maxdl-system`, 차트 2.18.5)가 다음을 수행한다.

- **presync hook**: `kubectl apply -f deploy/k8s/namespaces.yaml` (7개 네임스페이스 생성)
- 컨트롤러 배포(`fullnameOverride=sealed-secrets-controller`)
- **postsync hook**: 컨트롤러 rollout 대기 후 `kubectl apply -f deploy/k8s/sealed/` (전체 SealedSecret 적용)

`deploy/k8s/sealed/` 에는 `src-db-*`, `seaweedfs-s3.*`, `polaris-*`, `superset-*`, `airflow-*`, `airbyte-api`, `trino-svc-dbt`, `trino-password-db` 등이 포함된다.

### 2단계: Polaris 메타스토어(PostgreSQL)

릴리스 `polaris-pg`(`maxdl-catalog`, bitnami/postgresql 18.6.6). `needs: [maxdl-system/sealed-secrets]`. 자격은 SealedSecret `polaris-persistence` 바인딩(`auth.existingSecret`), 영속 4Gi.

### 3단계: Polaris (+ realm bootstrap + 카탈로그/RBAC)

릴리스 `polaris`(`maxdl-catalog`, Polaris 1.4.1). `needs: [maxdl-catalog/polaris-pg]`. `values: charts/polaris/values.yaml`.

- **presync hook**: polaris-postgresql StatefulSet rollout 대기 → `kubectl apply -f deploy/k8s/polaris/bootstrap-job.yaml` → `job/polaris-bootstrap` 완료 대기. (relational-jdbc 백엔드는 서버 기동 전 realm `POLARIS` + root principal 을 DB 에 1회 주입해야 한다. `apache/polaris-admin-tool:1.4.1` 사용.)
- 서버 배포
- **postsync hook**: polaris deploy rollout 대기 → `bash deploy/k8s/polaris/catalog-bootstrap.sh` (bronze/silver/gold 3개 카탈로그를 SeaweedFS 전용 버킷에 생성 + drop-with-purge + FU-2 최소권한 RBAC 배선; idempotent)

### 4단계: Trino

릴리스 `trino`(`maxdl-query`, 차트 1.42.2, 이미지 태그 481). `needs: [maxdl-catalog/polaris]`. `values: charts/trino/values.yaml`. Iceberg REST → Polaris, native S3 → SeaweedFS. 3개 Iceberg 카탈로그에 `case-insensitive-name-matching=true` 적용.

### 5단계: Airbyte + Oracle 커스텀 커넥터

릴리스 `airbyte`(`maxdl-ingest`, airbyte-v2 2.1.0). `needs: [maxdl-system/sealed-secrets]`. `values: charts/airbyte/values.yaml`.

- **postsync hook**: airbyte-server rollout 대기 → `bash deploy/k8s/airbyte/register-oracle-connector.sh`
- 커뮤니티 `airbyte/source-oracle:0.5.8` 을 커스텀 소스 정의로 등록(enterprise entitlement 우회, FU-1). **반드시 in-cluster 호출** — port-forward 경유 큰 POST 는 HTTP 000(스크립트가 in-cluster curl Pod 사용).

### 6단계: Airflow (커스텀 이미지)

릴리스 `airflow`(`maxdl-orchestrate`, 차트 1.21.0). `needs: [maxdl-system/sealed-secrets]`. `values: charts/airflow/values.yaml`(`images.airflow=maxdl/airflow:fu3`, `pullPolicy: Never`).

**커스텀 이미지 사전 빌드 필요**(`deploy/airflow-image/Dockerfile`):

```bash
# 1) 커스텀 Airflow 이미지 빌드 (Cosmos + dbt-trino + providers-airbyte + dbt 프로젝트/DAG 동봉)
#    레포 루트에서 빌드 컨텍스트가 dbt/ 와 dags/ 를 포함해야 한다.
docker build --network=host -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .
# 2) k3d 노드에 이미지 import (사설 레지스트리 미사용 → pullPolicy Never)
k3d image import maxdl/airflow:fu3 -c maxdl
```

> `--network=host` 빌드 주의: Dockerfile 이 `PIP_CONSTRAINT=` 로 제약 해제 후 `astronomer-cosmos[kubernetes]==1.14.1` / `dbt-trino==1.10.1` / `dbt-core==1.11.10` / `apache-airflow-providers-airbyte` 를 설치하고, 빌드 시 `dbt deps` + `dbt parse` 로 `manifest.json` 을 베이크한다. 베이스는 `apache/airflow:3.2.1-python3.12`.

### 7단계: Superset

릴리스 `superset`(`maxdl-bi`, 차트 0.15.5, 이미지 태그 6.1.0). `needs: [maxdl-system/sealed-secrets, maxdl-query/trino]`. `values: charts/superset/values.yaml`.

- 차트 init 통과용 임시 placeholder 비번을 `setString` 으로 주입(비밀 아님)
- **postsync hook**: superset rollout 대기 → SealedSecret `superset-admin` 에서 실제 강력 비번을 읽어 `superset fab reset-password` 로 즉시 재설정
- `SECRET_KEY` 는 SealedSecret `superset-secret` → env(`SUPERSET_SECRET_KEY`) 주입(values 평문 0, FU-5). bootstrapScript 가 `psycopg2-binary` + `trino[sqlalchemy]` 설치.

### 8단계: 거버넌스 (별도 컴포넌트 없음 — OpenMetadata 제거됨)

- OpenMetadata 는 FU-9 에서 **제거**(빈 데드웨이트, 접근 거버넌스는 Trino
  file-based 로 대체). 별도 8단계 릴리스 없음. helmfile 릴리스 7개로 종료.
- **접근통제·컬럼마스킹**: Trino 내장 file-based access control
  (`charts/trino/values.yaml` `accessControl`, 정책=git JSON). 인증=Trino
  PASSWORD(svc-dbt/svc-superset + 그룹). 컷오버 시 활성(FOLLOWUPS FU-9).
- **계보·카탈로그**: dbt docs — `scripts/airflow-artifact-publish.sh` 가
  `dbt docs generate --static` 로 단일 HTML 생성(아티팩트 `target/
  static_index.html`), `dbt docs serve` 로도 열람. 추가 인프라 0.

---

## 3. 단일 명령 경로 (`helmfile apply`)

위 1~8단계는 `helmfile.yaml` 에 코드화되어 있으므로, 커스텀 Airflow 이미지를 사전에 빌드·import 한 뒤 단일 명령으로 재구축할 수 있다.

```bash
# 비파괴 검증(상태 렌더 / 릴리스 목록) — 먼저 실행 권장
helmfile build      # 렌더된 릴리스 상태 확인
helmfile list       # 릴리스/네임스페이스/버전 목록

# 전 스택 배포 (needs 의존순서 + hooks 자동 실행)
helmfile apply
```

`helmfile apply` 는 `needs` 로 의존순서를 강제하고, hooks 로 명령형 단계(네임스페이스/SealedSecret apply, Polaris bootstrap·카탈로그·RBAC, Oracle 커넥터 등록, Superset admin 재설정)를 기존 idempotent 스크립트·매니페스트 호출로 실행한다(중복 작성 금지·SSOT 유지).

> **완전 클린 클러스터 재구축 검증은 폐기형(disposable) 클러스터에서 수행할 것을 권장한다.** 라이브 스택 파괴 방지를 위한 FU-6 의 잔여 AC 다(FOLLOWUPS FU-6). 라이브 환경에서 무분별한 `helmfile apply` 재실행은 피한다.

---

## 4. 설치 검증 스모크

RUNBOOK §5 의 검증 절차를 그대로 재사용한다.

```bash
# 1) Trino → Polaris → SeaweedFS 읽기/쓰기
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "CREATE SCHEMA iceberg_bronze.smoke; \
  CREATE TABLE iceberg_bronze.smoke.t(a int); INSERT INTO iceberg_bronze.smoke.t VALUES 1; \
  SELECT * FROM iceberg_bronze.smoke.t; DROP TABLE iceberg_bronze.smoke.t; \
  DROP SCHEMA iceberg_bronze.smoke"

# 2) dbt 연결 확인
cd dbt/maxdl_transform && TRINO_HOST=localhost TRINO_PORT=30080 \
  /tmp/dbtvenv/bin/dbt debug --profiles-dir .

# 3) 엔드포인트 200 확인 (RUNBOOK §2 의 NodePort 표 기준)
#    Trino 30080 / Airbyte 30081 / Airflow 30082 / Superset 30088 / Polaris 30181
```

스모크가 모두 통과하면 Bronze 적재·dbt 변환을 위한 플랫폼이 준비된 것이다.

---

## 5. 접속 정보 / 자격증명

접속 URL·NodePort 표와 자격증명(전부 SealedSecret) 목록은 [RUNBOOK §1~§3](./RUNBOOK.md) 를 신뢰원천으로 사용한다. 비밀값은 본 문서에 기재하지 않으며, 다음 형태로 SealedSecret 에서만 조회한다.

```bash
# 예: Superset admin 비번 조회(값은 출력하지 말 것)
kubectl get secret superset-admin -n maxdl-bi -o jsonpath='{.data.admin-password}' | base64 -d
```
