# maxdl 폐쇄망 설치 — 단일 절차서 (OS 준비 → 가동)

폐쇄망(인터넷 없음)에 maxdl 을 설치하는 **하나의 파일**. 온라인 준비 →
운반 → 폐쇄망 호스트 OS·도구·k3s·이미지 → 시크릿 → 배포 → 검증 까지
순서대로. 스크립트로 자동화된 부분은 명시. (컴포넌트/hook 상세=
[`INSTALL.md`](./INSTALL.md), 접속/운영=[`RUNBOOK.md`](./RUNBOOK.md),
상태 SSOT=[`FOLLOWUPS.md`](./FOLLOWUPS.md). 본 문서가 폐쇄망 단일 SSOT.)

> 호스트 2개: **온라인 빌드 호스트**(인터넷 O, Ubuntu 24.04, 폐쇄망과
> 동일 버전·amd64) / **폐쇄망 호스트**(인터넷 X, maxdl 실가동, 전용/
> 폐기형). 정직: 오프라인 .deb closure·k3s air-gap 은 Ubuntu 버전 일치
> 시에만 보장. 본 스크립트는 폐쇄망 대상이라 여기서 실행검증 불가 —
> 정석 방법대로 작성, 대상 호스트에서 검증 게이트로 확인.

---

## A. 온라인 빌드 호스트 (인터넷 O)

```bash
git clone <repo> ~/project/maxdl && cd ~/project/maxdl
# A-1. 도구(없으면). Docker apt 저장소 구성은 §부록 또는 INSTALL_UBUNTU §2~3.
# A-2. 커스텀 이미지 빌드 (빌드 필요한 이미지는 이것 하나)
docker build --network=host -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .
# A-3. dbt 모델 생성(멱등) — ingestion-map → stg_/int_
scripts/dbt-gen-models.sh
# A-4. 워크로드 이미지 단일 번들(36개, ~11GB)
scripts/airgap-bundle.sh --gzip
#   → dist/maxdl-airgap-images.tar.gz (+ .images.txt, .sha256)
# A-5. 폐쇄망 호스트용 OS/도구/k3s 자산 수집
scripts/airgap-os-deps.sh
#   → dist/os-deps.tar.gz (+ .sha256, MANIFEST) : Docker .deb closure +
#     kubectl/helm/helmfile/kubeseal + k3s 바이너리·airgap-images·install.sh
```
**검증 게이트**: `dist/` 에 `maxdl-airgap-images.tar.gz`,
`os-deps.tar.gz`, 각 `.sha256`. `os-deps/MANIFEST.txt` 의 ubuntu 버전이
폐쇄망 호스트와 일치.
**운반물(매체로 폐쇄망 반입)**: ① `dist/maxdl-airgap-images.tar.gz`
② `dist/os-deps.tar.gz` ③ 레포 체크아웃 전체(스크립트·차트·
`secrets.env.example`).

---

## B. 폐쇄망 호스트 — OS 준비 → 이미지 설치 (자동 스크립트)

```bash
# B-1. 운반물 배치
git clone/copy <repo> ~/project/maxdl && cd ~/project/maxdl
mkdir -p os-deps && tar xzf /media/os-deps.tar.gz -C os-deps
mkdir -p dist && cp /media/maxdl-airgap-images.tar.gz dist/
sha256sum -c os-deps.tar.gz.sha256 dist/maxdl-airgap-images.tar.gz.sha256

# B-2. OS·Docker·CLI·k3s·이미지 일괄 (한 스크립트)
sudo bash scripts/airgap-host-setup.sh \
  --os-deps ./os-deps --images dist/maxdl-airgap-images.tar.gz
#   → Docker(.deb 오프라인) · kubectl/helm/helmfile/kubeseal →
#     /usr/local/bin · k3s(air-gap 설치) · maxdl 이미지 k3s containerd 적재
```
**검증 게이트**: `docker run --rm hello-world` OK · `k3s kubectl get nodes`
Ready · `k3s ctr images ls | grep maxdl/airflow` 존재. 멀티노드면
이미지 적재를 **전 노드 1회씩**(KE 태스크 pod 가 아무 노드에나).

---

## C. 폐쇄망 호스트 — 시크릿 → 배포 → 검증

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:$PATH"

# C-1. (선택) 메타DB 호스트 폴더 영속 자동활성
export MAXDL_PERSIST=1
export MAXDL_PV_DIR=/srv/maxdl-pv      # 미설정 시 <repo>/.maxdl-pv (.gitignore)

# C-2. sealed-secrets 컨트롤러(신규 클러스터 키)
helmfile -f helmfile.yaml -l name=sealed-secrets sync
kubectl -n maxdl-system rollout status deploy/sealed-secrets-controller

# C-3. 평문 SSOT → 폐쇄망 클러스터 키로 봉인·적용
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env     # 폐쇄망 실제값(DB·S3·Trino TLS/내부/svc)
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/seal-from-env.sh         --cert /tmp/pub.pem --apply
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
scripts/gen-trino-tls.sh         --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem

# C-4. 전 스택 (7 릴리스 + hooks)
helmfile -f helmfile.yaml build
helmfile -f helmfile.yaml sync         # helm-diff 불필요(sync)
```
hooks 자동: 네임스페이스/SealedSecret·Retain SC(+MAXDL_PERSIST 시 영속
폴더), Polaris bootstrap+RBAC+principal 캡처, Oracle 커스텀 커넥터,
ingestion-map→Airbyte, dbt 아티팩트 발행, Superset admin.
**검증 게이트(RUNBOOK §5)**: 7 NS pod Ready · Trino→Polaris→SeaweedFS
R/W · Airbyte 4커넥션 active · 거버넌스(anon 401·svc 200·임퍼소네이션·
PII 마스킹) · Superset `http://<host>:30088`.
**실패 시**: 해당 릴리스 hook 로그. 정책 변경 후엔 `kubectl rollout
restart deployment trino-coordinator -n maxdl-query`.

---

## D. 정직한 잔여·주의 (운영자 인지 필수)

- **오프라인 .deb/k3s 는 Ubuntu 버전·amd64 일치 시에만 보장** —
  `os-deps/MANIFEST.txt` ubuntu 값과 폐쇄망 호스트 비교 필수.
- **본 스크립트군은 폐쇄망 대상이라 여기서 실행검증 불가** — 정석
  (apt download closure / k3s air-gap 공식법)대로 작성. 첫 배포 전
  **폐기형 동일-버전 호스트 리허설 권장**(FOLLOWUPS FU-6: 키 재봉인은
  실증 해소됨, 풀 E2E 는 격리 스토리지 환경 필요).
- **SeaweedFS 공유 주의**: 운영 동거면 `maxdl-warehouse` 전용 버킷만,
  `s3.json` 절대 미변경(prod S3 다운 위험).
- **백업 2곳**: 외부 SeaweedFS(레이크하우스 본체) + `$MAXDL_PV_DIR`
  (메타DB PVC). 메타는 부트스트랩 재구축도 가능하나 백업 시 RPO↓.
- dbt-trino 인증서 검증 활성(self-signed CA, SAN=Trino svc). 멀티노드면
  `maxdl-retain` SC 를 Longhorn/NFS-CSI 로 교체(워크로드 무변경).
- 외부 노출(Ingress/도메인/정식 인증서)=FU-7 보류. 폐쇄망 내부는
  NodePort 30000번대 + Trino 내부 self-signed TLS 로 운영.

---

## 부록: 온라인 호스트 Docker apt 저장소(.deb 수집 전 1회)

```bash
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
```
(베어 Ubuntu 온라인 설치 일반 절차는 [`INSTALL_UBUNTU.md`](./INSTALL_UBUNTU.md).)
