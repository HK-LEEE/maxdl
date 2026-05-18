# maxdl 폐쇄망 설치 — 호스트별 실행 체크리스트

현장용 체크리스트. 명령은 스크립트 시그니처와 일치. 절차 설명·근거·
정직한 잔여는 [`INSTALL_AIRGAP.md`](./INSTALL_AIRGAP.md)(단일 SSOT),
접속/검증 상세는 [`RUNBOOK.md`](./RUNBOOK.md).

> 핵심 흐름: **호스트 A** 에서 `airgap-bundle.sh` + `airgap-os-deps.sh`
> 둘 다 → [운반] → **호스트 B** 에서 `airgap-host-setup.sh` 한 번
> (둘을 입력으로 소비) → 시크릿/helmfile **수동**.

---

## 🖥️ 호스트 A — 온라인 빌드 (인터넷 O)

전제: Ubuntu 24.04 · amd64 · **호스트 B 와 동일 버전**.

- [ ] `git clone <repo> ~/project/maxdl && cd ~/project/maxdl`
- [ ] (도구 없으면) Docker apt 저장소 구성 — `INSTALL_AIRGAP.md` 부록, 1회
- [ ] `docker build --network=host -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .`
- [ ] `scripts/dbt-gen-models.sh`  — ingestion-map → dbt 모델(멱등)
- [ ] `scripts/airgap-bundle.sh --gzip`  → `dist/maxdl-airgap-images.tar.gz`
- [ ] `scripts/airgap-os-deps.sh`  → `dist/os-deps.tar.gz`
- [ ] **검증**: `dist/` 에 두 `*.tar.gz` + 각 `.sha256`, `os-deps/MANIFEST.txt`
      의 `ubuntu=` 가 호스트 B 와 일치

## 📦 운반 (매체)

- [ ] `dist/maxdl-airgap-images.tar.gz`
- [ ] `dist/os-deps.tar.gz`
- [ ] 레포 체크아웃 전체(스크립트·차트·`secrets.env.example`)

---

## 🔒 호스트 B — 폐쇄망 (인터넷 X, 전용/폐기형, sudo)

### B-1. 운반물 배치·무결성 (수동)
- [ ] `git clone/copy <repo> ~/project/maxdl && cd ~/project/maxdl`
- [ ] `mkdir -p os-deps && tar xzf /media/os-deps.tar.gz -C os-deps`
- [ ] `mkdir -p dist && cp /media/maxdl-airgap-images.tar.gz dist/`
- [ ] `sha256sum -c os-deps.tar.gz.sha256 dist/maxdl-airgap-images.tar.gz.sha256`

### B-2. OS~이미지 (스크립트 1회 — 자동)
- [ ] `sudo bash scripts/airgap-host-setup.sh --os-deps ./os-deps --images dist/maxdl-airgap-images.tar.gz`
- [ ] **검증**: `docker run --rm hello-world` OK · `k3s kubectl get nodes`
      Ready · `k3s ctr images ls | grep maxdl/airflow` 존재
      (멀티노드면 이미지 적재를 전 노드 1회씩)

### B-3. 시크릿 봉인 (수동 — secrets.env 실제값 편집 필수)
- [ ] `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
- [ ] `export PATH="/usr/local/bin:$PATH"`
- [ ] (영속) `export MAXDL_PERSIST=1 MAXDL_PV_DIR=/srv/maxdl-pv`
- [ ] `helmfile -f helmfile.yaml -l name=sealed-secrets sync`
- [ ] `kubectl -n maxdl-system rollout status deploy/sealed-secrets-controller`
- [ ] `cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env`
- [ ] **`$EDITOR deploy/secrets/secrets.env`** ← 폐쇄망 실제값(사람 판단)
- [ ] `kubeseal --fetch-cert --controller-namespace maxdl-system --controller-name sealed-secrets-controller > /tmp/pub.pem`
- [ ] `scripts/seal-from-env.sh         --cert /tmp/pub.pem --apply`
- [ ] `scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply`
- [ ] `scripts/gen-trino-tls.sh         --cert /tmp/pub.pem --apply`
- [ ] `shred -u /tmp/pub.pem`

### B-4. 전 스택 배포·검증
- [ ] `helmfile -f helmfile.yaml build`
- [ ] `helmfile -f helmfile.yaml sync`
- [ ] **검증(RUNBOOK §5)**: 7 NS pod Ready · Trino→Polaris→SeaweedFS
      R/W · Airbyte 4커넥션 active · 거버넌스(anon 401·svc 200·PII
      마스킹) · Superset `http://<host>:30088`
- [ ] (정책 변경 시) `kubectl rollout restart deployment trino-coordinator -n maxdl-query`

---

## ❓ "호스트 B 는 위 명령어만 실행하면 끝?" — 아니오

자동은 **B-2 한 줄뿐**. 사람 판단/입력이 필요한 비-자동 단계:

- **B-1**: 매체에서 운반물 복사·`sha256sum -c` 무결성 확인.
- **B-3**: `secrets.env` 에 **폐쇄망 실제값**(DB·S3·Trino TLS/내부/svc
  자격)을 사람이 채워야 함. 예시값 그대로면 배포는 되지만 외부 소스
  연결·인증이 실패. → 가장 중요한 수동 게이트.
- **각 검증 게이트**: pod Ready·R/W·거버넌스·Superset 은 사람이 결과를
  확인하고 통과 판정(스크립트가 합/불 자동 판정 안 함).
- **MAXDL_PERSIST/PV_DIR**: 영속 폴더를 쓸지 운영자가 결정해 export.

정직한 한계(INSTALL_AIRGAP §D 동일):
- 오프라인 .deb/k3s 는 **Ubuntu 버전·amd64 일치 시에만 보장** —
  `os-deps/MANIFEST.txt` 의 `ubuntu=` 를 호스트 B 와 반드시 대조.
- 본 스크립트군은 폐쇄망 대상이라 **여기서 실행검증 불가** — 정석법
  대로 작성. 첫 배포 전 동일버전 폐기형 호스트 리허설 권장.
- SeaweedFS 운영 동거 시 `maxdl-warehouse` 전용 버킷만, `s3.json`
  절대 미변경(prod S3 다운 위험).
