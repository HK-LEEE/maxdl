# Trino 사용자 / 그룹 관리 (운영 runbook)

휴먼 사용자 추가·제거·비번 회전·그룹 변경의 **순서 있는 절차**.
FU-9 거버넌스(파일 기반 password 인증 + file ACL + 그룹) 라이브 기준.

> **권위(SSOT)**: 인증 정보 = `deploy/secrets/secrets.env`(평문, gitignore)
> → SealedSecret `trino-password-db`. 그룹 매핑 = `charts/trino/values.yaml`
> 의 `groups.txt`. ACL 규칙은 그룹 단위라 **사용자 추가 시 ACL 룰
> 변경 불요** — 그룹에 추가만 하면 됨.

---

## 0. 현재 구조 (Cheat-sheet)

| 항목 | 위치 |
|---|---|
| 사람·서비스 사용자 비번(평문) | `deploy/secrets/secrets.env` (`TRINO_USER_<NAME>_PASSWORD` / `SVC_*_PASSWORD`) |
| 봉인된 password.db (bcrypt) | SealedSecret `trino-password-db` (NS: `maxdl-query`) |
| 비번 봉인 스크립트 | `scripts/gen-trino-password-db.sh` |
| 그룹 매핑 | `charts/trino/values.yaml` 의 `coordinator.additionalConfigFiles.groups.txt` |
| ACL 규칙 | 같은 파일의 `accessControl.rules.json` (그룹·user 단위) |
| Trino password 재로드 주기 | `file.refresh-period` 기본 5s + k8s Secret 마운트 갱신 ~60s |

기존 사용자 분류(2026-05 기준):
- 서비스: `svc-dbt`(파이프라인 전권), `svc-superset`(임퍼소네이션 신뢰 principal), `svc-airbyte`(Polaris 클라이언트)
- 그룹: `analysts` — Silver/Gold read-only + PII 마스킹
- 인간 사용자: **없음**(`groups.txt: analysts: admin` 만 — 자리만 비워둠)

---

## 1. 신규 사용자 추가 (예: `alice` → `analysts` 그룹)

이름 규약: **소문자**(스크립트가 env 키를 소문자로 변환).

```bash
# (1) secrets.env 에 비번 추가 (평문, 미커밋)
echo "TRINO_USER_ALICE_PASSWORD='강한비번-개인지정'" >> deploy/secrets/secrets.env

# (2) SealedSecret 재봉인·적용 — 평문 디스크 미기록(파이프)
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem

# (3) 그룹 매핑 — charts/trino/values.yaml 의 groups.txt 수정
#     "analysts: admin"  →  "analysts: admin,alice"
#     (admin 은 자리표시자 — 운영 admin 유저 있으면 그대로, 없으면 alice 만)
$EDITOR charts/trino/values.yaml

# (4) Trino 차트 sync (groups.txt 변경 반영)
helmfile -f helmfile.yaml -l name=trino sync

# (5) 검증 — alice 로 svc-superset 임퍼소네이션 없이 직접 로그인 가능?
#     Trino UI/JDBC 도 동일 자격
kubectl -n maxdl-query exec deploy/trino-coordinator -- \
  env TRINO_PASSWORD='강한비번-개인지정' \
  trino --server https://localhost:8443 --user alice --password --insecure \
  --execute "SHOW SCHEMAS FROM iceberg_silver"
# → information_schema/maxapex/maxplatform/... 정상 표시 = 인증·ACL OK
# (Silver 의 PII 컬럼은 마스킹돼 표시됨 — 정상)
```

**소요 시간**: 약 5분. password 파일 자동 재로드 + ConfigMap 갱신 합쳐 ~1분 내 발효. 즉시성 필요하면 `kubectl -n maxdl-query rollout restart deploy/trino-coordinator`.

---

## 2. 사용자 제거 (예: `alice` 퇴사)

```bash
# (1) secrets.env 에서 해당 줄 삭제
sed -i '/^TRINO_USER_ALICE_PASSWORD=/d' deploy/secrets/secrets.env

# (2) SealedSecret 재봉인·적용 (alice 없는 password.db)
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem

# (3) groups.txt 에서 alice 제거
$EDITOR charts/trino/values.yaml

# (4) sync
helmfile -f helmfile.yaml -l name=trino sync

# (5) 검증 — alice 로그인이 401 로 거부되는지
kubectl -n maxdl-query exec deploy/trino-coordinator -- \
  env TRINO_PASSWORD='이전비번' \
  trino --server https://localhost:8443 --user alice --password --insecure \
  --execute "SHOW CATALOGS" 2>&1 | grep -iE 'Authentication failed|401|denied'
# → 인증 실패 메시지 = 정상 차단
```

**즉시성**: 사용자 차단은 보안상 즉각 발효되어야 함. 차트 sync 후 ConfigMap 마운트 갱신 ~60s. 그 전에 강제하려면 sync 후 `rollout restart deploy/trino-coordinator`.

---

## 3. 비밀번호 회전 (정기, 예: 90일)

비번만 갱신 — 사용자 추가/제거와 동일하나 groups.txt 손댈 일 없음.

```bash
# secrets.env 의 TRINO_USER_ALICE_PASSWORD='새비번' 으로 갱신
$EDITOR deploy/secrets/secrets.env

# 재봉인 + 적용
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/pub.pem
scripts/gen-trino-password-db.sh --cert /tmp/pub.pem --apply
shred -u /tmp/pub.pem

# 검증: 새 비번 로그인 OK / 이전 비번 401
```

회전 정책은 조직 보안 정책에 따라 (예: 90일 cron 으로 운영자에게 알림).

---

## 4. 그룹 매핑 변경 (예: `alice` 를 admin 권한으로 승격)

ACL 룰 자체는 그룹 단위로 정의돼 있으므로 **그룹 매핑만 바꾸면 됨**.

```bash
# groups.txt 수정 — alice 를 admin 그룹에도 추가(또는 analysts 에서 빼고 admin 만)
# 예: "analysts: bob,charlie"  + "admin: alice"
#     단, admin 그룹은 charts/trino/values.yaml 의 ACL rules.json 에 정의돼야 함
#     (현재 ACL 은 analysts/svc-* 만 정의 — admin 그룹 추가 시 룰도 함께 정의)
$EDITOR charts/trino/values.yaml

helmfile -f helmfile.yaml -l name=trino sync
# 검증: alice 로 admin 영역(Bronze 등) 접근 확인
```

> 새 그룹(admin 등)을 도입할 때만 ACL rules.json 의 catalog/schema/table
> 절에도 해당 그룹 룰을 추가해야 함(예: `{ "group":"admin", "catalog":".*", "allow":"all" }`).

---

## 5. 검증 명령 (반복 사용)

```bash
# 인증·ACL 통과 확인
kubectl -n maxdl-query exec deploy/trino-coordinator -- \
  env TRINO_PASSWORD='<비번>' \
  trino --server https://localhost:8443 --user <user> --password --insecure \
  --execute "SHOW SCHEMAS FROM iceberg_silver"

# 권한 거부 확인 (예: analysts 가 Bronze 접근 → 거부)
kubectl -n maxdl-query exec deploy/trino-coordinator -- \
  env TRINO_PASSWORD='<비번>' \
  trino --server https://localhost:8443 --user <user> --password --insecure \
  --execute "SHOW SCHEMAS FROM iceberg_bronze" 2>&1 | grep -iE 'Access Denied|Forbidden'

# 익명 거부(거버넌스 동작) 확인
kubectl -n maxdl-query exec deploy/trino-coordinator -- \
  trino --execute "SHOW CATALOGS" 2>&1 | grep -i 'Access Denied'
```

---

## 6. 정직한 한계 / 주의

- **평문 비번은 `secrets.env` 에만** — gitignore 됨. shred 또는 안전 보관.
  봉인 단계에서 평문은 디스크 미기록(스크립트가 메모리→kubeseal 파이프).
- **중앙 디렉토리/SSO 없음** — 소수 유저(≤수십명) 수용 결정(계획서 §7
  트레이드오프). 다중 환경·대량 유저 전환은 LDAP/SSO 가 별도 트랙.
- **그룹 매핑 즉시성**: ConfigMap 갱신 ~60s + Trino refresh 5s.
  보안상 즉각이 필요한 차단(퇴사자)은 `rollout restart deploy/trino-coordinator`
  로 강제.
- **사용자 이름은 소문자**. `gen-trino-password-db.sh` 가 env 키
  `TRINO_USER_ALICE_PASSWORD` 를 `alice` 로 변환. groups.txt·ACL 도
  소문자 사용.
- **운영 admin 자리표시자**: 현재 `groups.txt: analysts: admin` 의 `admin`
  은 password.db 에 실재하지 않을 수 있음(svc-dbt/superset 외 사람 유저
  0). 첫 실 admin 추가 시 그대로 활용 또는 별도 사용자명 사용.
- **감사 추적**: 사용자 추가/제거 commit 메시지에 표준 패턴 사용
  (예: `chore(users): add alice → analysts` / `chore(users): remove alice`).
- **위험 시나리오**: secrets.env 백업본을 다른 머신에 두지 말 것.
  평문 비번은 그 머신만 있도록.
