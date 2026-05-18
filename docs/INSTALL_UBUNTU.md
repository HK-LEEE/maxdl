# maxdl 설치 (Ubuntu — 베어 OS → 가동까지 상세)

베어 Ubuntu 머신에서 **Docker 설치 → CLI 도구 → k3d 클러스터 → 커스텀
이미지 → helmfile 배포 → 검증**까지 그대로 따라가는 온라인 설치 가이드.
폐쇄망(인터넷 없음) 설치는 [`AIRGAP_RUNBOOK.md`](./AIRGAP_RUNBOOK.md),
릴리스/hook 상세는 [`INSTALL.md`](./INSTALL.md), 접속·트러블슈팅은
[`RUNBOOK.md`](./RUNBOOK.md), 상태 SSOT 는 [`FOLLOWUPS.md`](./FOLLOWUPS.md).

> **OS 버전 주의**: Ubuntu 는 `YY.MM` 표기 — "24.03" 은 없고 LTS 는
> **24.04 LTS (Noble)** 입니다. 본 문서는 24.04 LTS x86_64 기준
> (22.04 도 동일 절차). `sudo` 권한 + 인터넷 필요.

---

## 1. OS 준비

```bash
sudo apt-get update
sudo apt-get install -y curl wget git ca-certificates gnupg lsb-release \
  python3 python3-yaml python3-bcrypt openssl jq
mkdir -p "$HOME/.local/bin"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && export PATH="$HOME/.local/bin:$PATH"
```
`python3-yaml`/`python3-bcrypt` = 본 프로젝트 스크립트(seal-from-env,
dbt-gen, gen-trino-*) 의존. 없으면 그 단계에서 즉시 실패.

---

## 2. Docker 설치 (공식 apt 저장소, Ubuntu 24.04)

```bash
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo usermod -aG docker "$USER"      # 그룹 반영: 재로그인 또는 `newgrp docker`
newgrp docker
docker run --rm hello-world          # 검증
```
**검증 게이트**: `docker run hello-world` 성공. 실패 시 그룹 반영
(재로그인) 확인.

---

## 3. CLI 도구 → `~/.local/bin` (kubectl/helm/helmfile/k3d/kubeseal)

> 버전 정책: 차트 호환 확인된 안정 라인의 최신 패치를 **정확히 핀**(베타
> 배제). 본 프로젝트 검증 라인: k3s 1.31.x / kubectl 1.31~호환 / helm 3.x /
> helmfile 0.16x+ / k3d 5.8.x / kubeseal 0.27+ (설치 직전 각 repo 최신
> 안정 재확인). 아래는 설치 메커니즘 — 버전 변수만 맞추면 됨.

```bash
B="$HOME/.local/bin"
# kubectl (안정)
curl -fsSL -o "$B/kubectl" "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$B" USE_SUDO=false bash
# k3d
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | K3D_INSTALL_DIR="$B" USE_SUDO=false bash
# helmfile (릴리스 바이너리 — 버전 핀 예시)
HF=0.169.1; curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HF}/helmfile_${HF}_linux_amd64.tar.gz" \
  | tar -xz -C "$B" helmfile
# kubeseal (sealed-secrets 클라이언트 — 컨트롤러와 메이저 일치)
KS=0.27.1; curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS}/kubeseal-${KS}-linux-amd64.tar.gz" \
  | tar -xz -C "$B" kubeseal
chmod +x "$B"/{kubectl,helmfile,kubeseal}
for t in kubectl helm helmfile k3d kubeseal; do command -v $t && $t version 2>/dev/null | head -1; done
```
**검증 게이트**: 5개 도구 `version` 출력. helmfile 은 helm-diff 미설치 시
`apply` 가 실패하므로 본 가이드는 `sync` 사용(8단계).

---

## 4. 레포 클론 + 외부 의존 확인

```bash
git clone <maxdl repo> ~/project/maxdl && cd ~/project/maxdl
```
외부 의존(없으면 동작 불가 — [INSTALL.md §1.2]):
- **SeaweedFS S3**: 외부 Docker, 전용 버킷 `maxdl-warehouse`. (개발에서
  maxplatform 운영과 공유 시 `s3.json` 절대 미변경 — prod 다운 위험.)
- **소스 DB 4종**: `172.168.35.8`(maxplatform/pfms/maxapex/maxtdoracle).

---

## 5. k3d 클러스터 생성 (포트맵·eviction·선택 영속)

```bash
k3d cluster create maxdl \
  --servers 1 \
  --port "30080:30080@server:0" --port "30081:30081@server:0" \
  --port "30082:30082@server:0" --port "30088:30088@server:0" \
  --port "30181:30181@server:0" \
  --k3s-arg "--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:0"
# (선택) k3d 에서도 PVC 를 호스트 폴더에 영속:
#   --volume "$PWD/.maxdl-pv:/var/lib/rancher/k3s/storage@server:0"
#   → 실 k3s 의 MAXDL_PERSIST 자동화(AIRGAP_RUNBOOK §2-1b)와 등가. 단
#     생성 시점에만 가능.
```
포트(= `environments/default/globals.yaml`): Trino 30080 · Airbyte 30081 ·
Airflow 30082 · Superset 30088 · Polaris 30181. (OpenMetadata 제거됨 —
거버넌스=Trino ACL, 계보=dbt docs.) Trino https(8443)는 in-cluster 전용.
**검증**: `kubectl get nodes` → `Ready`. eviction 완화는 단일노드 디스크
포화 시 과도 축출 방지(인시던트 학습, RUNBOOK).

---

## 6. 커스텀 Airflow 이미지 빌드 + import

필요한 빌드 이미지는 **`maxdl/airflow:fu3` 하나**(pip 패키지층 +
`s3artifact.py` 슬림 — dbt/DAG 미동봉, 아티팩트 패턴). 그 외는 전부 공개
이미지(차트가 pull).

```bash
docker build --network=host -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .
k3d image import maxdl/airflow:fu3 -c maxdl     # 사설 레지스트리 미사용 → pullPolicy:Never
docker image inspect maxdl/airflow:fu3 --format 'OK {{.Id}}'
```
`--network=host` 필수(베이스 이미지 PIP_CONSTRAINT 해제 후 cosmos/dbt
설치 시 컨테이너 DNS 이슈 회피 — 본 프로젝트 알려진 해법). 폐쇄망용
전체 번들은 `scripts/airgap-bundle.sh`(AIRGAP_RUNBOOK §1).
**검증 게이트**: `docker image inspect maxdl/airflow:fu3` 성공 +
`k3d image import` "Successfully imported".

---

## 7. 시크릿 (secrets.env → 클러스터 키로 봉인)

```bash
# 7-1. sealed-secrets 컨트롤러
helmfile -f helmfile.yaml -l name=sealed-secrets sync
kubectl -n maxdl-system rollout status deploy/sealed-secrets-controller

# 7-2. 평문 SSOT 작성(미커밋 — .gitignore) → 클러스터 공개키로 봉인·적용
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env     # DB host/계정/비번, S3 키/endpoint,
                                       # Trino TLS/내부/svc 비번 등 실제값
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/seal-from-env.sh        --cert /tmp/pub.pem --apply
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
scripts/gen-trino-tls.sh         --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem
```
**검증 게이트**: `scripts/seal-from-env.sh --dry-run` 값 누락 0,
`kubectl get secret -A | grep -E 'src-db|seaweedfs-s3|trino-'` 존재.
정직: 평문 `secrets.env` 절대 미커밋, 사용 후 안전 보관/`shred`.

---

## 8. 전 스택 배포 (`helmfile sync`)

```bash
# (선택) 메타DB 호스트 폴더 영속 자동활성 — 실 k3s 또는 5단계 --volume k3d
export MAXDL_PERSIST=1
export MAXDL_PV_DIR="$PWD/.maxdl-pv"      # 미설정 시 <repo>/.maxdl-pv

helmfile -f helmfile.yaml build           # 비파괴 정합 점검
helmfile -f helmfile.yaml sync            # 7 릴리스 + hooks (helm-diff 불필요)
```
hooks 자동: 네임스페이스/SealedSecret·Retain SC, Polaris bootstrap+RBAC+
principal 캡처, Oracle 커스텀 커넥터, ingestion-map→Airbyte 적용, dbt
아티팩트 발행, Superset admin 재설정.
**검증 게이트**: 7 NS pod Ready(sealed-secrets/polaris-pg/polaris/trino/
airbyte/airflow/superset), Trino→Polaris→SeaweedFS R/W 스모크(RUNBOOK §5).

---

## 9. 거버넌스·접속·운영 (요약 — 상세는 링크)

- **거버넌스(FU-9)**: Trino 인증(password-file)+내부 self-signed TLS+
  file-based ACL+임퍼소네이션+PII 컬럼마스킹. 차트에 코드화돼 배포와
  함께 활성. 검증·운영 절차 = AIRGAP_RUNBOOK §6/§8, FOLLOWUPS §3.0.
- **접속**: Superset `http://<host>:30088`(admin / `superset-admin`
  SealedSecret). 자격 조회는 RUNBOOK §3(값 출력 금지 규약).
- **계보/카탈로그**: dbt docs(`target/static_index.html` / `dbt docs serve`).
- **정책 변경**: `config/pii-columns.yaml`→`gen-trino-acl.sh`, ingestion-map
  →`dbt-gen-models.sh`+applier. 반영 시 `kubectl rollout restart deployment
  trino-coordinator -n maxdl-query`(차트 자동롤아웃 안 함).

---

## 10. 트러블슈팅 (이 프로젝트에서 실제 겪은 것)

| 증상 | 원인·조치 |
|---|---|
| 이미지 빌드 DNS 실패 | `docker build --network=host`(필수) |
| `helmfile apply` "unknown command diff" | helm-diff 미설치 → `helmfile sync` 사용 |
| Trino coordinator CrashLoop(인증 켠 뒤) | password-authenticator/secretMount/shared-secret 설정 — 차트 values 에 이미 반영(FU-9). 정책 변경 후엔 coordinator rollout restart |
| dbt SSL `WRONG_VERSION_NUMBER` | https/8443 + CA(trino-tls-ca) 필요 — 차트에 반영. TRINO_CERT=마운트 CA |
| 컬럼 마스킹 미적용 | rules.json 컬럼 `name` 은 **리터럴**(정규식 X). `config/pii-columns.yaml`+`gen-trino-acl.sh` |
| PVC 가 클러스터 삭제 시 소실 | 영속 자동화(8단계 MAXDL_PERSIST) 또는 k3d `--volume`(5단계) |
| 디스크 포화→eviction→CoreDNS host 소실 | `kubectl patch cm coredns`(RUNBOOK), eviction 완화(5단계) |

상세 상태·잔여·리스크는 항상 [`FOLLOWUPS.md`](./FOLLOWUPS.md) 가 SSOT.
