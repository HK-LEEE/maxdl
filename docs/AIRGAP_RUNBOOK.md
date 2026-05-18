# maxdl 폐쇄망(air-gap) 배포 런북

폐쇄망에 maxdl 을 처음 배포하는 **단일 순서 절차서**. 인터넷 없는 현장에서
이 문서 하나로 0번부터 끝까지 따라간다. 흩어진 문서를 통합하며, 각 단계에
**검증 게이트**와 **실패 시 행동**을 둔다. 상태 SSOT 는
[`FOLLOWUPS.md`](./FOLLOWUPS.md), 컴포넌트 상세는
[`INSTALL.md`](./INSTALL.md)/[`RUNBOOK.md`](./RUNBOOK.md).

> 핵심 원칙: **인터넷 있는 온라인 빌드 단계**(0~1)와 **폐쇄망 단계**(2~9)를
> 분리한다. 코드/이미지는 번들로, 환경 자격은 `secrets.env` 로 이관하며,
> 거버넌스(인증·TLS·접근통제)는 차트에 코드화돼 배포와 함께 활성된다.

---

## 0. 사전조건 (P1 — 운영자가 환경 사실로 확정. 미확정 시 진행 금지)

| # | 항목 | 확인 방법 |
|---|---|---|
| 0.1 | **폐쇄망 S3/SeaweedFS** 존재·도달 | 클러스터에서 S3 endpoint 인증 요청 200/403, 전용 버킷(예 `maxdl-warehouse`) 생성 가능 |
| 0.2 | **소스 DB 4종 네트워크 경로** | 클러스터 egress → DB host:port 도달 |
| 0.3 | **k3s/k3d air-gap 설치 자산** | k3s 바이너리 + `k3s-airgap-images`(시스템 이미지) — 본 워크로드 번들과 **별개**, k3s 설치 범위 |
| 0.4 | **노드 시계(NTP)** | `s3artifact.py` 가 SigV4 → 시계 ±15분 틀어지면 S3 403. 폐쇄망 NTP 확보 |
| 0.5 | **노드 사이징** | 실측 기준 ~30GiB/노드면 충분(거버넌스 포함). 멀티노드면 전 노드 번들 적재 |
| 0.6 | **폐기형 리허설 호스트** | 클린 `helmfile apply` 전체 E2E 검증용 별도 1대(단일노드는 2nd 클러스터 미기동 — 실측). 운영 전 권장 |

> 0.1/0.2 가 안 되면 그 무엇도 동작하지 않는다(하드 의존). 0.6 미수행 시
> "폐쇄망에서 첫 클린 배포가 곧 첫 검증"이 되는 리스크를 감수하는 것.

---

## 1. 온라인 빌드 호스트 (인터넷 가능)

```bash
# 1-1. 커스텀 Airflow 이미지(pip 패키지층 + s3artifact.py — 슬림)
docker build --network=host -t maxdl/airflow:fu3 -f deploy/airflow-image/Dockerfile .

# 1-2. 스택 전 이미지 단일 번들(36개, ~11GB, sha256 포함)
scripts/airgap-bundle.sh --gzip
#   → dist/maxdl-airgap-images.tar.gz (+ .images.txt, .sha256)
#   로컬 빌드 이미지(maxdl/airflow)는 pull 안 하고 save(수정 반영됨)

# 1-3. dbt 모델/아티팩트(폐쇄망 런타임 자족 — dbt_packages 포함)
scripts/dbt-gen-models.sh                    # ingestion-map → stg_/int_ (멱등)
scripts/airflow-artifact-publish.sh          # dbt+dags+manifest+docs → 번들 tar
#   * 이 단계는 helmfile airflow presync 에도 배선돼 있으나, 폐쇄망 이관용
#     아티팩트는 온라인에서 만들어 함께 운반(SeaweedFS 업로드는 폐쇄망 S3로)
```
**검증 게이트**: `dist/` 에 tar.gz + sha256 존재, `.images.txt` 36행,
`maxdl/airflow:fu3`·`airbyte/source-*`·`trinodb/trino:481` 포함.
**실패 시**: `airgap-bundle.sh --dry-run` 으로 이미지 열거부터 점검.

전송 대상(USB/승인 매체): `dist/` 번들 + 레포 체크아웃(스크립트·차트·
`secrets.env.example`) + k3s air-gap 자산(0.3).

---

## 2. 폐쇄망: 클러스터 + 이미지 적재

```bash
# 2-1. k3s 클러스터 기동 (0.3 자산으로 — k3s 설치 절차는 환경 의존)

# 2-1b. **영속 스토리지 자동(실 k3s)** — 메타DB PVC 를 지정 폴더에 영속.
#   (레이크하우스 본체는 외부 SeaweedFS 라 별개로 이미 영속.)
#   불가피한 수동 = 폴더 선택 하나. 나머지(local-path 경로 재지정 +
#   maxdl-retain default 승격)는 helmfile 1단계 hook 이 자동 수행.
#
#   export MAXDL_PERSIST=1                       # 영속 자동활성(opt-in)
#   export MAXDL_PV_DIR=/srv/maxdl-pv            # 영속 폴더(미설정 시
#                                                #  <repo>/.maxdl-pv 기본)
#   # 이후 5단계 `helmfile apply` 시 sealed-secrets presync 가
#   # scripts/setup-k3s-persistence.sh 자동 실행:
#   #   폴더 생성 → local-path-config 경로 재지정 → provisioner 재기동
#   #   → maxdl-retain(Retain) default 승격(내장 local-path default 해제)
#   # → 번들 차트 values 무수정으로 전 PVC 가 그 폴더에 영속.
#   # MAXDL_PERSIST 미설정이면 SC 만 적용(비-default·무해) — 영속 미활성.
#
#   주의: 폴더가 레포 내부면 .gitignore 됨(.maxdl-pv) — DB데이터·비밀
#   커밋 금지. 전용 디스크 아님 → 격리/쿼터 없음, 그 폴더 디스크 용량
#   충분 확보. Retain=PVC 삭제해도 폴더 잔존(고의·수동정리). local-path
#   =노드 종속(단일노드 가정; 멀티노드는 Longhorn/NFS-CSI 로 SC 교체).

# 2-2. 번들 전송 후 **모든 노드에서 1회씩**:
sudo scripts/airgap-load.sh dist/maxdl-airgap-images.tar.gz
#   기본 k3s ctr import(재기동 불요). 비 k3s: --ctr "ctr -n k8s.io"
```
**검증 게이트**: 각 노드 `k3s ctr images ls | grep maxdl/airflow` 존재.
SC: `kubectl get sc` 에서 `maxdl-retain (default)` + `local-path`(비default).
PVC 바인딩 후 호스트 `$MAXDL_PV_DIR/`(기본 <repo>/.maxdl-pv) 에 `pvc-*` 폴더 생성 확인.
**실패 시**: KubernetesExecutor 태스크 pod 는 아무 노드에나 스케줄 →
**누락 노드 1개도 ImagePullBackOff**. 전 노드 적재 재확인.

---

## 3. Sealed Secrets 컨트롤러

helmfile 첫 릴리스가 처리하나, 시크릿 재봉인(4단계)이 컨트롤러 키를
필요로 하므로 먼저 올린다.
```bash
helmfile -f helmfile.yaml -l name=sealed-secrets sync
```
**검증**: `kubectl -n maxdl-system get deploy sealed-secrets-controller` Ready.

---

## 4. 환경 자격 (secrets.env → 폐쇄망 클러스터 키로 재봉인)

> FU-6 핵심: 커밋된 SealedSecret 은 *이전* 클러스터 키 결합 → 폐쇄망
> 클러스터 키로 **재봉인**해야 한다.

```bash
cp deploy/secrets/secrets.env.example deploy/secrets/secrets.env
$EDITOR deploy/secrets/secrets.env      # 폐쇄망 실제값: DB host/계정/비번,
                                        # S3 endpoint/키, Trino TLS/내부/svc 비번 등
kubeseal --fetch-cert --controller-namespace maxdl-system \
  --controller-name sealed-secrets-controller > /tmp/prod-pub.pem
scripts/seal-from-env.sh --cert /tmp/prod-pub.pem --apply
scripts/gen-trino-password-db.sh --apply --cert /tmp/prod-pub.pem   # bcrypt password-db
scripts/gen-trino-tls.sh        --apply --cert /tmp/prod-pub.pem   # self-signed TLS
```
**검증 게이트**: `seal-from-env.sh --dry-run` 값 누락 0,
`kubectl get secret -A | grep -E 'src-db|seaweedfs-s3|trino-'` 존재.
**실패 시**: 누락 키 → secrets.env 채움. 평문 `secrets.env` 는 절대 미커밋
(.gitignore), 사용 후 안전 보관/`shred`.

> `polaris-airbyte`(svc-airbyte 자격)는 4단계서 만들지 않는다 — 5단계
> catalog-bootstrap 가 *fresh Polaris 에서 principal 신규 생성(201)* 시
> 캡처·시크릿화한다(클린 폐쇄망 = 항상 fresh → 자동 재현).

---

## 5. 전 스택 배포 (`helmfile apply` — 7 릴리스 + hooks)

```bash
helmfile -f helmfile.yaml build      # 비파괴 정합 점검(릴리스/values)
helmfile -f helmfile.yaml apply      # needs 의존순서 + hooks 자동
```
hooks 가 자동 수행: 네임스페이스/SealedSecret apply, Polaris bootstrap +
**카탈로그·RBAC·principal 자격 캡처**, Oracle 커스텀 커넥터 등록,
**ingestion-map → Airbyte 소스/목적지/커넥션 적용**(`airbyte-apply-
ingestion-map.sh`), Superset admin 재설정, dbt 아티팩트 발행·password-db
생성. (OpenMetadata 없음 — FU-9 에서 제거, 거버넌스=Trino ACL + dbt docs.)

**검증 게이트**(RUNBOOK §5 재사용):
- 전 NS pod Ready(7 릴리스: sealed-secrets/polaris-pg/polaris/trino/
  airbyte/airflow/superset)
- Trino→Polaris→SeaweedFS R/W 스모크
- Airbyte 4커넥션 active, dbt 아티팩트 fetch(initContainer) 정상
**실패 시**: 해당 릴리스 hook 로그 확인. helm-diff 미설치면 `apply` 대신
`sync` 사용.

---

## 6. 거버넌스 (FU-9 — 차트에 코드화, 배포와 함께 활성)

폐쇄망에선 거버넌스가 **별도 컷오버가 아니라 5단계와 함께 켜진 상태**로
온다(charts/trino values 에 인증·내부TLS·file-based ACL 코드화됨,
`charts/airflow` TRINO_METHOD=ldap/8443/https). dbt/Superset 도 그 구성으로
배포됨. 이미 라이브에서 컷오버 검증 완료(리허설이 실 버그 6건 사전 적발·
수정).

**검증 게이트**:
- Trino https/8443: anon 401, svc-dbt/svc-superset 200
- dbt: `dbt debug` All checks passed (https svc-dbt + CA 신뢰)
- Superset(admin 로그인)→`SELECT current_user`=`admin`(임퍼소네이션),
  Gold PII 컬럼=`***-MASKED-***`, bronze 접근=거부
**실패 시**: §8 운영 절차(정책/coordinator) 점검. 최후 수단 롤백:
`helm rollback trino` / `airflow` 직전 리비전(무인증 복구).

---

## 7. 소비/검증 (사용자 진입점)

- **Superset** `http://<node>:30088` — Gold 대시보드(거버넌스 적용된 쿼리)
- **dbt docs** — 계보/카탈로그(`target/static_index.html` 또는
  `dbt docs serve`). OpenMetadata 대체, 추가 인프라 0
- 외부 노출(Ingress/TLS/도메인)은 **FU-7 — 사용자 보류**. 폐쇄망 내부는
  NodePort 30000번대 + Trino 내부 self-signed TLS 로 운영(정식 인증서는
  추후 FU-7 에서 교체).

---

## 8. 운영 절차 (배포 후 상시)

| 변경 | 절차 |
|---|---|
| 새 테이블/모드 | `ingestion-map.yaml` 편집 → `dbt-gen-models.sh` → `airbyte-apply-ingestion-map.sh` → 아티팩트 재발행 → Airflow 롤아웃 |
| **PII 정책** | `config/pii-columns.yaml` 편집 → `gen-trino-acl.sh` → 커밋 → **`kubectl rollout restart deployment trino-coordinator -n maxdl-query`**(차트 자동 롤아웃 안 함) |
| 접근/그룹 | `charts/trino/values.yaml` rules.json/groups.txt → `helmfile sync trino` → coordinator rollout restart |
| 시크릿 회전 | `secrets.env` → `seal-from-env.sh --cert <키> --apply` → 해당 deploy rollout restart(env 주입 시크릿은 pod 재기동 필요) |
| 신규 소스 자격 | `src-db-*` secrets-spec/secrets.env → seal-from-env |

드리프트 게이트(커밋 전/CI 권장): `dbt-gen-models.sh --check`,
`gen-trino-acl.sh --check`, `seal-from-env.sh --dry-run`.

---

## 9. 정직한 잔여·리스크 (운영자 인지 필수)

- **완전 클린 `helmfile apply` 단일 E2E 는 폐기형 호스트(0.6)에서만 미실증**
  — 단계별·구성요소별로는 검증됨. 폐쇄망 첫 배포 전 리허설 강력 권장
  (FOLLOWUPS FU-6 잔여).
- **dbt-trino 인증서 검증 — 활성됨**(②). profiles `cert`=TRINO_CERT
  (Airflow=`/etc/trino-ca/tls.crt`) → self-signed CA 검증 ON·통과. 빈
  기본값은 레거시(검증 off, 비-cutover 경로 비파괴).
- **정책 변경 시 coordinator 수동 rollout restart** — 차트가 access-control
  ConfigMap 변경으로 자동 롤아웃 안 함(§8).
- **백업 대상 2곳**: ① 외부 SeaweedFS `maxdl-warehouse`(레이크하우스
  본체 — 책임경계: 공유 시스템) ② `$MAXDL_PV_DIR`(메타DB PVC 영속
  디렉토리, 2-1b). 메타는 부트스트랩 재구축도 가능하나 백업 시 RPO↓.
- **영속(2-1b) 정석**: maxdl-retain(Retain) default + local-path-config → `$MAXDL_PV_DIR`(MAXDL_PERSIST=1 시 hook 자동). PVC 가 그 폴더에 영속 → 클러스터 재생성
  해도 보존(local-path-config 재지정 시 재마운트). 단일노드 가정.
- **SeaweedFS 공유 주의** — 운영 시스템과 동거면 `maxdl-warehouse` 전용
  버킷만, `s3.json` 절대 미변경(MEMORY: prod S3 다운 위험).
- **FU-7(외부 Ingress/도메인/정식 인증서) 보류** — 폐쇄망 내부 운영은
  현 구성으로 가능, 외부 노출 요건 발생 시 별도.
