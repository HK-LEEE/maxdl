# maxdl 레이크하우스 운영 런북

제조(MES/LIMS/QMS/SPC) OSS 레이크하우스. K8s(k3d) + Helm. 상세 설계·진행현황은
플랜 파일(`~/.claude/plans/mes-lims-qms-fluffy-bubble.md`) 참조.

## 1. 클러스터 / 접속

| 항목 | 값 |
|---|---|
| K8s | k3d 클러스터 `maxdl` (k3s 1.31.5, 단일노드) |
| 도구 | `~/.local/bin`: kubectl·helm·helmfile·k3d·kubeseal |
| 외부 스토리지 | Docker SeaweedFS(공유, `maxplatform` 운영과 동거) — 전용 버킷 `maxdl-warehouse` 만 사용 |
| 소스 DB | 외부 172.168.35.8 (maxplatform/pfms/maxapex/maxtdoracle) |

## 2. 서비스 NodePort (정책: 30000번대)

| 서비스 | URL |
|---|---|
| Trino | http://localhost:30080 |
| Airbyte API/UI | (port-forward) `svc/airbyte-airbyte-server-svc:8001` |
| Airflow API | http://localhost:30082 (v3.2.0) |
| Superset | http://localhost:30088 |
| Polaris REST | http://localhost:30181 |

## 3. 자격증명 (전부 SealedSecret, 평문 미커밋)

- 소스 DB: `src-db-*` (maxdl-ingest)
- SeaweedFS S3(`datastore` 키): `seaweedfs-s3` (catalog/query/ingest)
- Polaris 메타DB: `polaris-persistence` / root: `polaris-bootstrap` (maxdl-catalog)
- Polaris OAuth(Trino): `polaris-oauth` (maxdl-query) — **스파이크용 root, 운영 전 전용 principal 교체**
- Airbyte API 토큰: `airbyte-auth-secrets` 의 instance-admin client → `/api/public/v1/applications/token`

## 4. 부트스트랩 재현

```bash
kubectl apply -f deploy/k8s/namespaces.yaml
kubectl apply -f deploy/k8s/sealed/                 # SealedSecret 전체
# Polaris 카탈로그(권한/drop-purge 포함, idempotent)
bash deploy/k8s/polaris/catalog-bootstrap.sh
# Helm: helm upgrade --install <name> <chart> -n <ns> -f charts/<c>/values.yaml
```

## 5. 핵심 검증 (스모크)

```bash
# Trino→Polaris→SeaweedFS R/W
kubectl exec -n maxdl-query deploy/trino-coordinator -- \
  trino --execute "CREATE SCHEMA iceberg_bronze.smoke; \
  CREATE TABLE iceberg_bronze.smoke.t(a int); INSERT INTO iceberg_bronze.smoke.t VALUES 1; \
  SELECT * FROM iceberg_bronze.smoke.t; DROP TABLE iceberg_bronze.smoke.t; \
  DROP SCHEMA iceberg_bronze.smoke"
# dbt 연결
cd dbt/maxdl_transform && TRINO_HOST=localhost TRINO_PORT=30080 \
  /tmp/dbtvenv/bin/dbt debug --profiles-dir .
```

## 6. 알려진 후속 과제 (운영 전 필수)

1. ~~Oracle 인제스션 블로커~~ **해결(FU-1, A안)**: 커뮤니티
   `airbyte/source-oracle:0.5.8` 를 커스텀 커넥터로 등록 → entitlement 우회,
   connection-check 성공. 재현: `deploy/k8s/airbyte/register-oracle-connector.sh`
   (반드시 in-cluster 호출 — port-forward 시 create_custom 이 HTTP 000).
2. **권한 최소화**: Polaris/Airbyte 가 스파이크용 `root` 사용 → 전용 principal·
   최소권한으로 교체.
3. **Airflow 커스텀 이미지**: Cosmos + dbt-trino + dbt 프로젝트 동봉 이미지 +
   DAG 전달(git-sync/PVC) — 컨테이너 레지스트리 결정 필요.
4. **실 커넥션**: 소스 테이블 스키마 확보 후 `config/ingestion-map.yaml` 의
   `tables` 채우고 Airbyte 커넥션 + dbt 모델 생성(현재 mock 미생성).
5. drop-with-purge/RBAC 는 `catalog-bootstrap.sh` 에 반영됨(재현 보장).

## 7. Superset 배포 시 admin 비번 주입 (FU-5)
```bash
PW=$(kubectl get secret superset-admin -n maxdl-bi -o jsonpath='{.data.admin-password}'|base64 -d)
helm upgrade --install superset superset/superset --version 0.15.5 -n maxdl-bi \
  -f charts/superset/values.yaml --set init.adminUser.password="$PW"
```
SECRET_KEY/webserverSecretKey 는 SealedSecret 에서 자동 주입(values 평문 0).
