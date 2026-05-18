#!/usr/bin/env bash
# =============================================================================
# airgap-host-setup.sh — [폐쇄망 호스트] OS 준비 → 이미지 설치까지
# -----------------------------------------------------------------------------
# 인터넷 없는 Ubuntu 호스트에서, 운반된 자산만으로:
#   ① Docker(.deb 오프라인) ② CLI 도구 ③ k3s(air-gap 설치)
#   ④ maxdl 워크로드 이미지 번들 적재(k3s containerd)
# 까지 자동. 이후(시크릿/helmfile)는 INSTALL_AIRGAP 다음 단계 수동.
#
# 입력(운반물):
#   --os-deps DIR     airgap-os-deps.sh 산출(os-deps.tar.gz 풀거나 디렉토리)
#   --images TAR      scripts/airgap-bundle.sh 산출(maxdl-airgap-images.tar[.gz])
#
# 사용(폐쇄망 호스트, sudo 필요):
#   tar xzf os-deps.tar.gz -C ./os-deps
#   sudo bash scripts/airgap-host-setup.sh --os-deps ./os-deps \
#        --images dist/maxdl-airgap-images.tar.gz
#
# 원칙: fallback 없음. 멱등 지향(이미 설치면 건너뜀). 대상 = 전용/폐기형
#   호스트(시스템 변경: apt/dpkg/systemd/k3s 설치). 정직: 본 스크립트는
#   여기서 실행·검증 불가(폐쇄망 대상) — 정석 방법대로 작성, 대상서 검증.
# =============================================================================
set -euo pipefail
OSD=""; IMG=""; BIN="${BIN_DIR:-/usr/local/bin}"
while [[ $# -gt 0 ]]; do case "$1" in
  --os-deps) OSD="$2"; shift 2;; --images) IMG="$2"; shift 2;;
  --bin-dir) BIN="$2"; shift 2;; -h|--help) sed -n '2,26p' "$0"; exit 0;;
  *) echo "ERROR: 알 수 없는 옵션 $1" >&2; exit 2;; esac; done
[[ -d "$OSD" ]] || { echo "ERROR: --os-deps 디렉토리 필요(존재 X): '$OSD'" >&2; exit 1; }
[[ -f "$IMG" ]] || { echo "ERROR: --images 번들 필요(존재 X): '$IMG'" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: sudo/root 로 실행" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH=amd64

echo "= [1/4] Docker (.deb 오프라인 설치)"
if command -v docker >/dev/null 2>&1; then
  echo "  docker 존재 — 건너뜀"
else
  dpkg -i "$OSD"/deb/*.deb || apt-get -y -f install --no-download || \
    { echo "ERROR: docker .deb 설치 실패(의존성/Ubuntu 버전 불일치 의심)" >&2; exit 1; }
  systemctl enable --now docker
  [[ -n "${SUDO_USER:-}" ]] && usermod -aG docker "$SUDO_USER" || true
  docker run --rm hello-world >/dev/null && echo "  docker OK"
fi

echo "= [2/4] CLI 도구 → $BIN"
install -m0755 -d "$BIN"
for t in kubectl helm helmfile kubeseal; do
  [[ -f "$OSD/bin/$t" ]] && install -m0755 "$OSD/bin/$t" "$BIN/$t" && echo "  $t"
done

echo "= [3/4] k3s air-gap 설치 (${BIN%/*}/k3s, airgap images)"
if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
  echo "  k3s 활성 — 건너뜀"
else
  install -m0755 "$OSD/k3s/k3s" /usr/local/bin/k3s
  mkdir -p /var/lib/rancher/k3s/agent/images
  cp "$OSD"/k3s/k3s-airgap-images-${ARCH}.tar /var/lib/rancher/k3s/agent/images/
  INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_BIN_DIR=/usr/local/bin \
    sh "$OSD/k3s/install.sh"
  # kubeconfig 접근(비root 사용자용 — 운영자 환경에 맞게 조정)
  mkdir -p "${SUDO_HOME:-/root}/.kube" 2>/dev/null || true
  until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do sleep 5; done
  k3s kubectl get nodes | tail -1
fi

echo "= [4/4] maxdl 워크로드 이미지 번들 적재(k3s containerd)"
bash "$REPO/scripts/airgap-load.sh" "$IMG" --ctr "k3s ctr"

cat <<'NEXT'
= OS/Docker/도구/k3s/이미지 준비 완료.
  다음(수동, INSTALL_AIRGAP 다음 단계):
   1) export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   2) (영속) export MAXDL_PERSIST=1 MAXDL_PV_DIR=/원하는/폴더
   3) helmfile -l name=sealed-secrets sync
   4) secrets.env 작성 → seal-from-env.sh --cert <키> --apply (+ gen-trino-*)
   5) helmfile sync   → 검증(RUNBOOK §5)
NEXT
