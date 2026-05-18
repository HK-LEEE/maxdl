# 시크릿 SSOT → 대상 클러스터 재봉인

SealedSecret 은 봉인 시점 클러스터 컨트롤러 키에 묶인다(다른 클러스터로
복사 불가). 이 디렉토리는 그 제약을 해소한다 — **평문은 `secrets.env` 한
곳**에만 두고, 배포 대상 클러스터의 키로 그때그때 재봉인한다.

## 구성

| 파일 | 커밋 | 설명 |
|---|---|---|
| `secrets-spec.yaml` | ✅ | 토폴로지 선언(Secret/네임스페이스/키/출력경로). 값 없음 |
| `secrets.env.example` | ✅ | 평문 템플릿(placeholder) |
| `secrets.env` | ❌ (gitignore) | 실제 평문 SSOT |
| `../../scripts/seal-from-env.sh` | ✅ | spec+env → 대상 클러스터 봉인/적용 드라이버 |

## 운영 클러스터 배포 절차

```bash
# 1) 평문 SSOT 준비(운영 자격으로 채움 — 절대 커밋 금지)
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env

# 2) 대상(운영) 클러스터 컨트롤러 공개키 확보
kubeseal --fetch-cert \
  --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/prod-pub.pem

# 3) 운영 클러스터 키로 전 SealedSecret 재봉인 + 적용
scripts/seal-from-env.sh --cert /tmp/prod-pub.pem --apply

# (검증만: --dry-run / 특정 항목만: --only superset-secret)
```

봉인 결과(`deploy/k8s/sealed/*.sealed.yaml`)만 암호문이므로 커밋 가능.
`secrets.env` 는 사용 후 안전 보관/파기(`shred`). fallback·mock 없음 —
값 누락 시 즉시 실패.
