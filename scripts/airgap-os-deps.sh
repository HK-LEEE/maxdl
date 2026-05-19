#!/usr/bin/env bash
# =============================================================================
# airgap-os-deps.sh — [온라인] 폐쇄망 호스트용 OS/도구/k3s 자산 수집
# -----------------------------------------------------------------------------
# 폐쇄망 호스트는 인터넷이 없어 Docker/CLI/k3s 자체를 설치 못 한다.
# 본 스크립트는 **인터넷 되는 동일 Ubuntu 버전**에서 그 일체를 dist/os-deps/
# 로 모아 운반물 1세트를 만든다. 폐쇄망에선 airgap-host-setup.sh 가 소비.
#
# 수집물(dist/os-deps/):
#   deb/   Docker(+containerd,buildx) + python3-yaml/bcrypt/jq/openssl/
#          ca-certificates + 미설치 의존 전부 (.deb closure)
#   bin/   kubectl helm helmfile kubeseal (정적 바이너리)
#   k3s/   k3s 바이너리 + k3s-airgap-images-amd64.tar + install.sh
#   MANIFEST.txt, sha256
#
# .deb 수집은 **깨끗한 ${UBUNTU_IMG} 컨테이너 안**에서 수행한다. 빌드
#   호스트에 docker-ce/python3-yaml 등이 이미 깔려 있어도 apt 가
#   "받을 것 없음" 으로 누락시키는 함정을 제거 — 호스트 상태와 무관한
#   완전 closure 보장(폐쇄망 깨끗한 호스트에서 그대로 설치 가능).
# 전제: 폐쇄망 호스트와 **동일 Ubuntu 버전·아키텍처(amd64)** (UBUNTU_IMG
#   가 그 버전과 일치해야 함). 빌드 호스트엔 docker 만 있으면 됨(컨테이너
#   안에서 Docker apt 저장소를 자체 구성 — 호스트 apt 설정 불요).
# 원칙: fallback 없음 — 다운로드 실패 시 즉시 중단(불완전 운반물 금지).
# 정직: closure 는 Ubuntu 버전(UBUNTU_IMG=대상) 일치 시에만 보장.
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/dist/os-deps}"
K3S_VER="${K3S_VER:-v1.31.5+k3s1}"        # 프로젝트 검증 k3s 라인(핀)
HELMFILE_VER="${HELMFILE_VER:-0.169.1}"
KUBESEAL_VER="${KUBESEAL_VER:-0.27.1}"
UBUNTU_IMG="${UBUNTU_IMG:-ubuntu:24.04}"  # 폐쇄망 대상 Ubuntu 와 일치시킬 것
ARCH=amd64
command -v docker >/dev/null || { echo "ERROR: docker 필요(컨테이너 .deb 수집)" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl 필요" >&2; exit 1; }
mkdir -p "$OUT"/{deb,bin,k3s}

echo "= [1/3] Docker+의존 .deb closure 수집 (깨끗한 $UBUNTU_IMG 컨테이너)"
# 핵심: 빌드 호스트 상태 무관 완전 closure. 깨끗한 컨테이너에 Docker apt
# 저장소를 자체 구성 → --download-only 가 docker-ce/python3-yaml 등 +
# 미설치 의존 전부를 받는다(호스트에 이미 깔려 누락되던 함정 제거).
# 컨테이너 root 가 받은 .deb 를 호스트 uid 소유로 되돌려 sudo 불요.
docker run --rm --network=host -v "$OUT/deb:/debs" \
  -e HUID="$(id -u)" -e HGID="$(id -g)" "$UBUNTU_IMG" bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null
  install -m0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  CN="$(. /etc/os-release; echo $VERSION_CODENAME)"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $CN stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  # --reinstall: 부트스트랩(ca-certificates/curl/gnupg)으로 컨테이너에
  # 이미 깔린 ca-certificates/openssl 등도 .deb 강제 재다운로드 →
  # 부트스트랩 오염과 무관한 완전 closure(누락 0).
  apt-get install -y --download-only --reinstall -o Dir::Cache::archives=/debs \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    python3 python3-yaml python3-bcrypt jq openssl ca-certificates
  rm -rf /debs/partial /debs/lock        # apt 부산물 정리(.deb 만 남김)
  chown -R "$HUID:$HGID" /debs
' || { echo "ERROR: 컨테이너 .deb closure 수집 실패" >&2; exit 1; }
find "$OUT/deb" -name '*.deb' | wc -l | sed 's/^/  .deb 수집: /'

echo "= [2/3] CLI 도구 바이너리"
curl -fsSL -o "$OUT/bin/kubectl" \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  | HELM_INSTALL_DIR="$OUT/bin" USE_SUDO=false bash
curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VER}/helmfile_${HELMFILE_VER}_linux_${ARCH}.tar.gz" \
  | tar -xz -C "$OUT/bin" helmfile
curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VER}/kubeseal-${KUBESEAL_VER}-linux-${ARCH}.tar.gz" \
  | tar -xz -C "$OUT/bin" kubeseal
chmod +x "$OUT"/bin/*

echo "= [3/3] k3s air-gap 자산 (${K3S_VER})"
KV="${K3S_VER/+/%2B}"   # URL 인코딩
curl -fsSL -o "$OUT/k3s/k3s" \
  "https://github.com/k3s-io/k3s/releases/download/${KV}/k3s"
curl -fsSL -o "$OUT/k3s/k3s-airgap-images-${ARCH}.tar" \
  "https://github.com/k3s-io/k3s/releases/download/${KV}/k3s-airgap-images-${ARCH}.tar"
curl -fsSL -o "$OUT/k3s/install.sh" https://get.k3s.io
chmod +x "$OUT/k3s/k3s" "$OUT/k3s/install.sh"

{ echo "k3s=$K3S_VER helmfile=$HELMFILE_VER kubeseal=$KUBESEAL_VER arch=$ARCH"
  echo "ubuntu=$(. /etc/os-release; echo $VERSION_ID $VERSION_CODENAME)"
  echo "생성: $(date -u +%FT%TZ)"; } > "$OUT/MANIFEST.txt"
( cd "$(dirname "$OUT")" && tar czf os-deps.tar.gz -C "$OUT" . \
  && sha256sum os-deps.tar.gz > os-deps.tar.gz.sha256 )
echo "완료 → $(dirname "$OUT")/os-deps.tar.gz (+ .sha256, MANIFEST)"
echo "운반: 이 tar + dist/maxdl-airgap-images.tar.gz + 레포 → 폐쇄망"
echo "정직: 폐쇄망 호스트가 다른 Ubuntu 버전이면 .deb closure 불일치 가능"
