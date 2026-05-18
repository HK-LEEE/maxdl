#!/usr/bin/env bash
# =============================================================================
# airgap-os-deps.sh — [온라인] 폐쇄망 호스트용 OS/도구/k3s 자산 수집
# -----------------------------------------------------------------------------
# 폐쇄망 호스트는 인터넷이 없어 Docker/CLI/k3s 자체를 설치 못 한다.
# 본 스크립트는 **인터넷 되는 동일 Ubuntu 버전**에서 그 일체를 dist/os-deps/
# 로 모아 운반물 1세트를 만든다. 폐쇄망에선 airgap-host-setup.sh 가 소비.
#
# 수집물(dist/os-deps/):
#   deb/   Docker(+containerd,buildx) + python3-yaml/bcrypt/jq/openssl 의존
#          closure (.deb) — apt download
#   bin/   kubectl helm helmfile kubeseal (정적 바이너리)
#   k3s/   k3s 바이너리 + k3s-airgap-images-amd64.tar + install.sh
#   MANIFEST.txt, sha256
#
# 전제: 폐쇄망 호스트와 **동일 Ubuntu 버전·아키텍처(amd64)**. Docker apt
#   저장소가 온라인 호스트에 구성돼 있어야 함(INSTALL_AIRGAP §2 와 동일).
# 원칙: fallback 없음 — 다운로드 실패 시 즉시 중단(불완전 운반물 금지).
# 정직: 오프라인 의존성 closure 는 Ubuntu 버전 일치 시에만 보장.
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/dist/os-deps}"
K3S_VER="${K3S_VER:-v1.31.5+k3s1}"        # 프로젝트 검증 k3s 라인(핀)
HELMFILE_VER="${HELMFILE_VER:-0.169.1}"
KUBESEAL_VER="${KUBESEAL_VER:-0.27.1}"
ARCH=amd64
command -v apt-get >/dev/null || { echo "ERROR: Ubuntu(apt) 온라인 호스트 필요" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl 필요" >&2; exit 1; }
mkdir -p "$OUT"/{deb,bin,k3s}

echo "= [1/3] Docker + 스크립트 의존 .deb closure 다운로드"
sudo apt-get update -qq
# --download-only 는 패키지+미설치 의존성을 archives 로 받음(closure)
sudo apt-get install -y --download-only \
  -o Dir::Cache::archives="$OUT/deb" \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
  python3 python3-yaml python3-bcrypt jq openssl ca-certificates
sudo chown -R "$USER":"$USER" "$OUT/deb"
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
