# maxdl 단일 설치·운영 절차서 (SETUP.md)

이 **한 문서**로 처음부터 끝까지: OS 구성 → 클러스터·이미지 → 전 스택
배포 → 운영 중 테이블/DB 추가·적용. 다른 문서를 참조하지 않아도 되도록
필요한 명령·검증·주의를 전부 인라인했다.

- 흐름: **1단계 OS Level → 2단계 클러스터·이미지 → 3단계 시크릿·배포
  → 4단계 테이블/DB 추가·적용**
- 각 단계에 **온라인(인터넷 O)** / **폐쇄망(인터넷 X)** 경로를 함께
  제시. 3·4단계는 두 경로 공통.
- 표기: `<host>` = 노드 호스트 IP/도메인. `$EDITOR` = 임의 편집기.

---

## 0. 사전 지식 (반드시 먼저 읽기)

### 0.1 호스트 구성

| 구분 | 정의 | 인터넷 |
|---|---|---|
| **온라인 호스트** | 일반 설치 또는 폐쇄망용 번들 빌드 | O |
| **폐쇄망 호스트** | maxdl 실가동(전용/폐기형 권장) | X |

폐쇄망은 호스트가 인터넷이 없어 Docker/k3s 자체를 못 깐다 → **온라인
호스트에서 자산을 만들어 운반**하는 구조(1·2단계 B 경로).

### 0.2 외부 의존 (클러스터 밖 — 없으면 동작 불가)

- **SeaweedFS S3**: 외부 Docker. 레이크하우스 전용 버킷
  `maxdl-warehouse` 만 사용. 엔드포인트 예 `http://<host>:8333`.
- **소스 DB 4종**: `172.168.35.8` — maxplatform(PG 5432)/pfms(MSSQL
  1433)/maxapex(PG 5432)/maxtdoracle(Oracle 1521).

### 0.3 외부 노출 포트 (`environments/default/globals.yaml`)

| 서비스 | NodePort |
|---|---|
| Trino | 30080 |
| Airbyte | 30081 |
| Airflow | 30082 |
| Superset | 30088 |
| Polaris | 30181 |

OpenMetadata 제거됨(거버넌스=Trino ACL, 계보=dbt docs). Trino
https(8443)는 in-cluster 전용.

### 0.4 보안 원칙 (위반 시 사고)

- **평문 시크릿 절대 미커밋**. `deploy/secrets/secrets.env` 는
  `.gitignore`. 봉인본(`*.sealed.yaml`)·`secrets.env.example`만 커밋.
  사용 후 평문/공개키는 `shred`.
- **SeaweedFS 운영 공유 주의**: `maxplatform-*`/`maxapex-*` 버킷·
  `s3.json` **절대 미접근/미변경**(운영 S3 전체 다운 위험). 레이크
  하우스는 `maxdl-warehouse` 전용 버킷만.
- 라이브 클러스터 파괴 작업은 사용자 승인 없이 금지.

### 0.5 버전 정책

차트 호환 확인된 안정 라인의 최신 패치를 **정확히 핀**(베타 배제).
검증 라인: k3s 1.31.x / kubectl 1.31~호환 / helm 3.x / helmfile
0.16x+ / k3d 5.8.x / kubeseal 0.27+. 설치 직전 각 repo 최신 안정
재확인. 빌드 필요한 이미지는 **`maxdl/airflow:fu3` 단 하나**(나머지는
공개 이미지 — 차트가 pull).

---

# 1단계. OS Level 구성

> Ubuntu 표기는 `YY.MM` — "24.03" 은 없음. **24.04 LTS (Noble)** 기준
> (22.04 동일 절차), x86_64, `sudo` 필요.

## 1-A. 온라인 경로 (인터넷 O)

### 1-A-1. OS 패키지

```bash
sudo apt-get update
sudo apt-get install -y curl wget git ca-certificates gnupg lsb-release \
  python3 python3-yaml python3-bcrypt openssl jq
mkdir -p "$HOME/.local/bin"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
```
`python3-yaml`/`python3-bcrypt` = 본 프로젝트 스크립트(seal-from-env,
dbt-gen, gen-trino-*) 의존. 없으면 해당 단계 즉시 실패(fallback 없음).

### 1-A-2. Docker (공식 apt 저장소)

```bash
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo usermod -aG docker "$USER"      # 그룹 반영: 재로그인 또는 newgrp
newgrp docker
docker run --rm hello-world          # 검증
```
**검증 게이트**: `docker run hello-world` 성공. 실패 시 그룹 반영
(재로그인) 확인.

### 1-A-3. CLI 도구 → `~/.local/bin`

```bash
B="$HOME/.local/bin"
# kubectl (안정 채널)
curl -fsSL -o "$B/kubectl" \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  | HELM_INSTALL_DIR="$B" USE_SUDO=false bash
# k3d
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
  | K3D_INSTALL_DIR="$B" USE_SUDO=false bash
# helmfile (버전 핀 예시)
HF=0.169.1; curl -fsSL \
  "https://github.com/helmfile/helmfile/releases/download/v${HF}/helmfile_${HF}_linux_amd64.tar.gz" \
  | tar -xz -C "$B" helmfile
# kubeseal (컨트롤러와 메이저 일치)
KS=0.27.1; curl -fsSL \
  "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS}/kubeseal-${KS}-linux-amd64.tar.gz" \
  | tar -xz -C "$B" kubeseal
chmod +x "$B"/{kubectl,helmfile,kubeseal}
for t in kubectl helm helmfile k3d kubeseal; do
  command -v $t && $t version 2>/dev/null | head -1; done
```
**검증 게이트**: 5개 도구 `version` 출력. helmfile 은 helm-diff
미설치 시 `apply` 실패 → 본 절차는 `sync` 사용(3단계).

## 1-B. 폐쇄망 경로 (인터넷 X)

폐쇄망 호스트엔 Docker/k3s 가 없으므로 **온라인 호스트에서 자산을
모아 운반** 후 **폐쇄망에서 한 스크립트로 일괄 설치**한다.

### 1-B-1. [온라인 호스트] OS/도구/k3s 자산 수집

전제: 폐쇄망 호스트와 **동일 Ubuntu 버전·amd64**. 온라인 호스트에
Docker apt 저장소 구성(1-A-2 의 keyring/sources 부분까지) 선행.

```bash
git clone <maxdl repo> ~/project/maxdl && cd ~/project/maxdl
scripts/airgap-os-deps.sh
#   → dist/os-deps.tar.gz (+ .sha256, MANIFEST.txt)
#     : Docker .deb closure + kubectl/helm/helmfile/kubeseal
#       + k3s 바이너리·k3s-airgap-images·install.sh
```
**검증 게이트**: `dist/os-deps.tar.gz` + `.sha256` 존재.
`dist/os-deps/MANIFEST.txt` 의 `ubuntu=` 가 폐쇄망 호스트와 일치
(불일치 시 .deb closure 부정합 — 보장 안 됨).

### 1-B-2. 운반 (매체)

`dist/os-deps.tar.gz` + (2-B 에서 만들 `dist/maxdl-airgap-images.tar.gz`)
+ **레포 체크아웃 전체**(스크립트·차트·`secrets.env.example`·vendored
`dbt_packages/` 포함) 를 폐쇄망으로 반입.

### 1-B-3. [폐쇄망 호스트] OS~이미지 일괄 설치

```bash
git clone/copy <repo> ~/project/maxdl && cd ~/project/maxdl
mkdir -p os-deps && tar xzf /media/os-deps.tar.gz -C os-deps
mkdir -p dist && cp /media/maxdl-airgap-images.tar.gz dist/
sha256sum -c os-deps.tar.gz.sha256 dist/maxdl-airgap-images.tar.gz.sha256

sudo bash scripts/airgap-host-setup.sh \
  --os-deps ./os-deps --images dist/maxdl-airgap-images.tar.gz
#   → Docker(.deb 오프라인) · CLI(/usr/local/bin) · k3s(air-gap 설치)
#     · maxdl 워크로드 이미지 번들 k3s containerd 적재
```
**검증 게이트**: `docker run --rm hello-world` OK · `k3s kubectl get
nodes` Ready · `k3s ctr images ls | grep maxdl/airflow` 존재. 멀티
노드면 이미지 적재를 전 노드 1회씩.

> 정직한 한계: 오프라인 .deb/k3s 는 Ubuntu 버전·amd64 일치 시에만
> 보장(MANIFEST 대조 게이트). 첫 배포 전 동일버전 폐기형 호스트
> 리허설 권장.

---

# 2단계. 클러스터 + 이미지 구성

## 2-A. 온라인 경로

### 2-A-1. k3d 클러스터 생성

```bash
cd ~/project/maxdl
k3d cluster create maxdl \
  --servers 1 \
  --port "30080:30080@server:0" --port "30081:30081@server:0" \
  --port "30082:30082@server:0" --port "30088:30088@server:0" \
  --port "30181:30181@server:0" \
  --k3s-arg "--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:0"
# (선택) PVC 를 호스트 폴더에 영속(생성 시점에만 가능):
#   --volume "$PWD/.maxdl-pv:/var/lib/rancher/k3s/storage@server:0"
```
eviction 완화 = 단일노드 디스크 포화 시 과도 축출 방지(인시던트 학습).
**검증**: `kubectl get nodes` → `Ready`.

### 2-A-2. 커스텀 Airflow 이미지 빌드 + import

```bash
docker build --network=host -t maxdl/airflow:fu3 \
  -f deploy/airflow-image/Dockerfile .
k3d image import maxdl/airflow:fu3 -c maxdl    # pullPolicy:Never
docker image inspect maxdl/airflow:fu3 --format 'OK {{.Id}}'
```
`--network=host` 필수(cosmos/dbt 설치 시 컨테이너 DNS 이슈 회피 —
알려진 해법). 이 이미지는 pip 층 + `s3artifact.py` 슬림이며 dbt/DAG 는
미동봉(아티팩트 패턴) → 새 모델/테이블에 재빌드 불요.
**검증 게이트**: `docker image inspect` 성공 + `k3d image import`
"Successfully imported".

## 2-B. 폐쇄망 경로

### 2-B-1. [온라인 호스트] 이미지 번들 생성

```bash
cd ~/project/maxdl
docker build --network=host -t maxdl/airflow:fu3 \
  -f deploy/airflow-image/Dockerfile .
scripts/dbt-gen-models.sh                 # ingestion-map → dbt 모델(멱등)
scripts/airgap-bundle.sh --gzip
#   → dist/maxdl-airgap-images.tar.gz (워크로드 이미지 36개, ~11GB)
```
이 tar 를 1-B-2 운반물에 포함. 클러스터·이미지 적재는 **1-B-3 의
`airgap-host-setup.sh` 가 이미 수행**(k3s 설치 + 이미지 적재). 폐쇄망
2단계는 별도 작업 없음 — 1-B-3 검증 게이트 통과면 완료.

> 폐쇄망은 k3d 가 아니라 **k3s**(airgap-host-setup 설치). 이후
> 명령은 `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.

---

# 3단계. 시크릿 + 전 스택 배포 (적용) — 공통

온라인은 `kubectl`(k3d kubeconfig 자동), 폐쇄망은 먼저:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:$PATH"
```

### 3-1. sealed-secrets 컨트롤러 (신규 클러스터 키)

```bash
helmfile -f helmfile.yaml -l name=sealed-secrets sync
kubectl -n maxdl-system rollout status deploy/sealed-secrets-controller
```

### 3-2. 평문 SSOT → 클러스터 키로 봉인·적용

```bash
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env
#   DB host/계정/비번, S3 키/endpoint, Trino TLS/내부/svc 비번 등 실제값
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/seal-from-env.sh        --cert /tmp/pub.pem --apply
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
scripts/gen-trino-tls.sh         --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem
```
**검증 게이트**: `scripts/seal-from-env.sh --dry-run` 값 누락 0,
`kubectl get secret -A | grep -E 'src-db|seaweedfs-s3|trino-'` 존재.

### 3-3. 전 스택 배포

```bash
# (선택) 메타DB 호스트 폴더 영속 자동활성
export MAXDL_PERSIST=1
export MAXDL_PV_DIR="$PWD/.maxdl-pv"      # 미설정 시 <repo>/.maxdl-pv

helmfile -f helmfile.yaml build           # 비파괴 정합 점검
helmfile -f helmfile.yaml sync            # 7 릴리스 + hooks
```
hooks 자동: 네임스페이스/SealedSecret·Retain SC(+MAXDL_PERSIST 시 영속
폴더), Polaris bootstrap+RBAC+principal 캡처, Oracle 커스텀 커넥터,
ingestion-map→Airbyte 적용, dbt 아티팩트 발행, Superset admin 재설정.
**검증 게이트**: 7 NS pod Ready(sealed-secrets/polaris-pg/polaris/
trino/airbyte/airflow/superset), Trino→Polaris→SeaweedFS R/W 스모크:
```bash
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "SHOW CATALOGS"
```

### 3-4. 거버넌스·접속 (배포와 함께 활성)

- **거버넌스(FU-9)**: Trino 인증(password-file) + 내부 self-signed
  TLS + file-based ACL + 임퍼소네이션 + PII 컬럼마스킹. 차트에 코드화.
- **접속**: Superset `http://<host>:30088`. admin 비번 =
  `superset-admin` SealedSecret(값 출력 금지 — 필요 시 운영자만 조회).
- **계보/카탈로그**: dbt docs(아티팩트 `target/static_index.html`
  또는 `dbt docs serve`). 추가 인프라 0.

---

# 4단계. 테이블/DB 추가 → 적용 (운영 중) — 공통

SSOT 는 `config/ingestion-map.yaml`. **두 경우 중 어느 쪽인지 먼저
판단**한다.

- **흐름 A — 이미 연결된 DB 에 테이블만 추가**: 쉬움, 시크릿 불요.
- **흐름 B — 새 소스 DB 통째 추가**: 시크릿 등 SSOT 4곳 추가.

> 폐쇄망 자족: `dbt_packages/` 가 레포에 vendoring(커밋) 되어
> `dbt parse`/`dbt run` 이 `dbt deps`(허브 접근) 없이 동작. 아티팩트
> 재발행도 폐쇄망 무접속. 새 DB/테이블에 이미지 재빌드 불요.

### 4.1 적재 모드 규칙 (필수)

`ingestion-map.yaml` 헤더 규칙과 동일:

| 모드 | 동작 | 조건 |
|---|---|---|
| `merge` | incremental + append_dedup (변경분만, PK dedup) | PK 존재 **AND** 시간 커서 컬럼이 **NOT NULL** |
| `replica` | full_refresh + overwrite (매번 전체 교체) | 그 외 전부 |

커서가 nullable 이면 Airbyte 증분이 거부 → 전체 실패. 불확실하면
`replica`(안전). CDC 미사용(컬럼 커서). `sources.<>.replicationMethod`
필드는 **어느 스크립트도 안 읽음**(airbyte-apply 가 커넥터별 Standard
하드코딩) — 값 변경해도 동작 무변경, 이 필드만으로 CDC 안 켜짐
(CDC 는 코드/소스 설정 변경 별도 트랙).

### 4.2 흐름 A — 기존 DB 에 테이블 추가

**A-1. `config/ingestion-map.yaml` 의 `sources.<DB>.tables:` 에 추가**
```yaml
# 예) maxplatform 에 새 테이블
      - { name: "public.work_orders", mode: merge, cursorField: "updated_at", primaryKey: ["id"] }
      - { name: "public.audit_dump",  mode: replica }   # 커서 nullable/PK 없음
```
대문자 테이블명(MSSQL/Oracle)은 **원본 그대로**(소문자화 금지).

**A-2. `config/source-schema.json` 에 컬럼/PK 인벤토리 추가**
replica 도 PK 보유. 비면 `dbt-gen-models.sh` 가 **즉시 실패**(의도된
안전장치 — fallback 없음). 형식 예:
```json
"maxplatform": {
  "public.work_orders": {"columns": ["id","updated_at","qty"],
    "primaryKey": ["id"], "cursor": "updated_at", "mode": "merge"},
  "public.audit_dump": {"columns": ["ts","msg"],
    "primaryKey": ["ts"], "cursor": null, "mode": "replica"}
}
```

**A-3. 생성·검증·적용** (3단계 KUBECONFIG/PATH 유지)
```bash
scripts/dbt-gen-models.sh --check          # 편집 정합성(드리프트 0) 확인
helmfile -f helmfile.yaml sync             # dbt-gen→아티팩트 재발행→
                                           #   Airbyte 커넥션 수렴(훅, 무접속)
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor   # 새 아티팩트 refetch
```

**A-4. 검증** (동기화 1회 후 — DAG 트리거 또는 Airbyte)
```bash
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "SELECT count(*) FROM iceberg_bronze.maxplatform.work_orders"
```
- [ ] Bronze 행수 > 0
- [ ] `dbt run --select staging intermediate` 통과
- [ ] (PII 컬럼이면) 4.4 확인

### 4.3 흐름 B — 새 소스 DB 추가

새 이름을 `mynewdb`(PostgreSQL 예시)로 가정. 기존 4소스와 동일 패턴.

**B-1. 시크릿 SSOT 3곳에 블록 추가**

(a) `deploy/secrets/secrets.env.example`(커밋 템플릿) +
`deploy/secrets/secrets.env`(실제값, 미커밋) — 기존 `SRC_MAXPLATFORM_*`
패턴 복제:
```bash
SRC_MYNEWDB_HOST='172.168.35.8'
SRC_MYNEWDB_PORT='5432'
SRC_MYNEWDB_DATABASE='mynewdb'
SRC_MYNEWDB_USERNAME='<계정>'
SRC_MYNEWDB_PASSWORD='<비밀번호>'
SRC_MYNEWDB_TYPE='postgres'          # postgres | mssql | oracle
# Oracle 이면 추가: SRC_MYNEWDB_SERVICENAME='xe'
```
(b) `deploy/secrets/secrets-spec.yaml` 에 항목 추가(기존
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

**B-2. `config/ingestion-map.yaml` `sources:` 아래 소스 블록**
```yaml
  mynewdb:
    connector: source-postgres        # source-postgres|source-mssql|source-oracle
    secret: src-db-mynewdb            # = secrets-spec 의 name
    replicationMethod: standard       # 기록용(스크립트 미참조)
    bronzeNamespace: mynewdb          # Bronze 스키마(=소스명 권장)
    tables:
      - { name: "public.orders", mode: merge, cursorField: "updated_at", primaryKey: ["id"] }
      - { name: "public.audit_raw", mode: replica }
```
+ A-2 와 동일하게 각 테이블을 `config/source-schema.json` 에 인벤토리.

**B-3. `dags/maxdl_factory.py` 의 SOURCES 에 등록**
```python
SOURCES = ("maxplatform", "pfms", "maxapex", "maxtdoracle", "mynewdb")
```
이 파일은 아티팩트로 배포 → 이미지 재빌드 불요. `maxdl_dags.py` 가
`SOURCES` 순회로 `ingest_mynewdb` DAG 자동 등록.

**B-4. 봉인 + 생성 + 적용** (KUBECONFIG/PATH 유지)
```bash
# (1) 신규 시크릿만 클러스터 키로 봉인·적용 (helmfile sync 전 필수)
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/seal-from-env.sh --cert /tmp/pub.pem --only src-db-mynewdb --apply
#   --only 값 = secrets-spec 의 name (= src-db-<소스논리명>)
shred -u /tmp/pub.pem
# (2) 모델 생성 정합성 + 전 스택 수렴
scripts/dbt-gen-models.sh --check
helmfile -f helmfile.yaml sync
kubectl -n maxdl-orchestrate rollout restart \
  deploy/airflow-scheduler deploy/airflow-dag-processor
```
> 스크립트 개별 실행도 동일(훅과 같음): `dbt-gen-models.sh` →
> `airflow-artifact-publish.sh` → `airbyte-apply-ingestion-map.sh --api
> http://localhost:30081 --set-airflow-vars` → `rollout restart`.
> Oracle 신규면 `register-oracle-connector.sh` 가 airbyte 훅 경로에
> 포함(idempotent).

**B-5. 검증**
- [ ] `kubectl get secret src-db-mynewdb -n maxdl-ingest` 존재
- [ ] Airbyte 소스 `src-mynewdb` connection-check succeeded
- [ ] `SELECT count(*) FROM iceberg_bronze.mynewdb.orders` > 0
- [ ] `ingest_mynewdb` DAG 노출 · `airbyte_conn_mynewdb` Variable 설정

### 4.4 PII 컬럼이 있으면 (거버넌스)

표준 어휘만 Silver/Gold 노출. 소스 원본명이 다르면 해당 테이블에:
```yaml
      - { name: "public.users", mode: merge, cursorField: "updated_at",
          primaryKey: ["id"], piiRename: { user_email: email, hp: phone } }
```
표준 어휘 자체가 늘면 `config/pii-columns.yaml` 갱신 후
`scripts/gen-trino-acl.sh` → `--check`. 적용 후 반드시:
```bash
kubectl rollout restart deployment trino-coordinator -n maxdl-query
```
(ACL ConfigMap 변경은 coordinator 자동 롤 안 됨 — 수동 재기동 필수.)

### 4.5 자동/수동 경계 (오해 방지)

| 단계 | 수동/자동 |
|---|---|
| SSOT 편집(ingestion-map/source-schema/(신규DB) secrets·SOURCES) | **수동** |
| 신규 DB 시크릿 봉인(`seal-from-env.sh`) | **수동**(sync 전 필수) |
| dbt 모델 생성·아티팩트 재발행·Airbyte 수렴·sealed apply | 자동(helmfile sync 훅) |
| Airflow 아티팩트 refetch | **수동 트리거**(`rollout restart`) |
| Bronze 적재 동기화 | **수동 트리거**(DAG/Airbyte) |

함정: `source-schema.json` 비면 `dbt-gen-models.sh` 즉시 실패 / 신규
DB sealed yaml 없으면 sealed 훅 적용 대상 없음 → 봉인 선행.

---

## 5. 트러블슈팅 (실제 겪은 것)

| 증상 | 원인·조치 |
|---|---|
| 이미지 빌드 DNS 실패 | `docker build --network=host`(필수) |
| `helmfile apply` "unknown command diff" | helm-diff 미설치 → `helmfile sync` |
| Trino coordinator CrashLoop(인증 켠 뒤) | password-authenticator/secretMount/shared-secret — 차트 values 에 반영(FU-9). 정책 변경 후 coordinator rollout restart |
| dbt SSL `WRONG_VERSION_NUMBER` | https/8443 + CA(trino-tls-ca) — 차트 반영. `TRINO_CERT`=마운트 CA |
| 컬럼 마스킹 미적용 | rules.json 컬럼 `name` 은 **리터럴**(정규식 X). `pii-columns.yaml`+`gen-trino-acl.sh`, 이후 coordinator rollout restart |
| `dbt-gen-models.sh` 즉시 종료 | `source-schema.json` 누락/항목 없음(fallback 없음 — 의도) |
| merge 인데 동기화 전체 실패 | 커서 nullable → 해당 테이블 `replica` 재분류 |
| Trino 대문자 테이블 미조회 | stream.name 소문자화함 → 원본 유지(카탈로그 case-insensitive 옵션은 차트 반영) |
| PVC 가 클러스터 삭제 시 소실 | 영속 자동화(3-3 MAXDL_PERSIST) 또는 k3d `--volume`(2-A-1) |
| 디스크 포화→eviction→CoreDNS host 소실 | `kubectl patch cm coredns`, eviction 완화(2-A-1) |
| 폐쇄망 .deb/k3s 설치 실패 | Ubuntu 버전·amd64 불일치 — `os-deps/MANIFEST.txt` 대조 |

---

## 6. 정직한 잔여·주의

- **폐쇄망 검증 한계**: 오프라인 OS/k3s 설치는 대상 호스트(Ubuntu
  버전·amd64 일치)에서만 보장. 첫 배포 전 동일버전 폐기형 호스트
  리허설 권장.
- **SeaweedFS 공유**: 운영 동거면 corruption 위험 — 전용 버킷만,
  `s3.json` 미변경. 풀 데이터 E2E 는 격리 스토리지 환경 권장.
- **CDC**: 컬럼 커서만 사용. CDC 전환은 코드(`src_config`)/소스 설정
  변경 별도 트랙 — `replicationMethod` 필드로 안 켜짐.
- **외부 노출**: NodePort(30000번대) + Trino 내부 self-signed TLS.
  정식 Ingress/도메인/인증서는 보류 항목(별도 요청 시 진행).
- **백업 2곳**: 외부 SeaweedFS(레이크하우스 본체) + `$MAXDL_PV_DIR`
  (메타DB PVC). 메타는 부트스트랩 재구축도 가능하나 백업 시 RPO↓.
- 상태·잔여·리스크의 최종 진실원천은 `FOLLOWUPS.md`(본 문서는 설치·
  운영 절차에 한정).
