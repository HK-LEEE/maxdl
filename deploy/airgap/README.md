# 폐쇄망(air-gap) 이관

스택 전 이미지를 **한 번에 번들로** 묶어 폐쇄망 운영으로 이관한다.
레지스트리 인프라 없이 k3s 노드 containerd 에 직접 적재.

## 분리 원칙 (중요)

| 구분 | 무엇 | 이관 수단 | 환경 의존 |
|---|---|---|---|
| 코드/바이너리 | 컨테이너 이미지 | `airgap-bundle.sh` 번들 | 환경 무관(동일) |
| **환경 설정·자격** | DB host/계정/비번, S3 엔드포인트, Polaris 자격 등 | `deploy/secrets/secrets.env` → `seal-from-env.sh` | **환경별로 전부 다름** |

→ 폐쇄망의 DB 정보가 개발과 다 달라도 **이미지 번들은 그대로**, 차이는
`secrets.env` 한 곳에서만 흡수한다. 이미지에 자격은 베이크되지 않는다.

## 절차

### A. 온라인 빌드 머신 (인터넷 가능)

```bash
# 0) 커스텀 Airflow 이미지 빌드(없으면)
docker build -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .

# 1) 스택 전 이미지 단일 번들 생성 (라이브 클러스터+extra-images.txt 열거)
scripts/airgap-bundle.sh --gzip
#   → dist/maxdl-airgap-images.tar.gz (+ .images.txt, .sha256)
#   helmfile 도 열거 소스로 쓰려면 --helmfile 추가
```

`deploy/airgap/extra-images.txt` = Airbyte 커넥터 등 런타임 동적 pull 이미지
(클러스터 pod 열거로 안 잡힘 → 명시 고정). 커넥터 추가 시 여기 갱신.

### B. 폐쇄망 — 이미지 적재 (모든 노드에서 1회씩)

```bash
# 번들 전송 후, 각 노드에서:
sudo scripts/airgap-load.sh dist/maxdl-airgap-images.tar.gz
#   기본: k3s ctr 즉시 import(재기동 불필요)
#   비 k3s: --ctr "ctr -n k8s.io"
#   k3s 자동 import 방식: --auto-dir (재기동 시 로드)
```

KubernetesExecutor 태스크 pod 는 아무 노드에나 스케줄 → **누락 노드 1개도
ImagePullBackOff**. 전 노드 적재 필수.

### C. 폐쇄망 — 환경 자격 봉인 + 배포

```bash
# 1) 폐쇄망 실제 값으로 SSOT 작성(평문, 미커밋)
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env          # 폐쇄망 DB/S3/자격 입력

# 2) 폐쇄망 클러스터 컨트롤러 키로 전 시크릿 재봉인+적용
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/prod-pub.pem
scripts/seal-from-env.sh --cert /tmp/prod-pub.pem --apply

# 3) helmfile 적용 (이미지는 이미 노드에 존재 → pull 없음)
helmfile apply
```

## 주의

- 번들은 **빌드 머신 아키텍처** 이미지만 포함. 운영 노드 아키텍처와 일치 전제.
- k3s 자체 air-gap(노드 부트스트랩용 `k3s-airgap-images`, k3s 바이너리)은
  k3s 설치 범위로 별도 — 본 번들은 **워크로드 이미지** 대상.
- `airgap-bundle.sh` 는 pull 실패 시 즉시 중단(불완전 번들 금지).
