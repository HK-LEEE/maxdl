# maxdl 성능 — 분석과 Trino 튜닝 적용 절차

이 문서 하나로: ① 어디가 느린지(병목) ② 멀티노드가 답인지 ③ 1차
조치(Trino 메모리/스레드) **구체값과 적용·검증·롤백 절차**.

> 적용 산출물: `charts/trino/values.yaml_bak` (튜닝본, **비활성
> 사이드카** — helmfile 은 `charts/trino/values.yaml` 만 참조하므로
> 파일 존재만으로는 아무것도 안 바뀜). 운영자가 원할 때 §3 절차로
> 활성 파일과 교체해 적용한다.

---

## 1. 병목 분석 (멀티노드가 답인가?)

처리 시간 4구간과 멀티노드(노드 추가) 효과:

| 구간 | 묶이는 곳 | 멀티노드 |
|---|---|---|
| 추출 Airbyte→Bronze | 소스 DB·네트워크·단일 커서 순차 | ❌ 거의 무효 |
| 객체 I/O Iceberg↔SeaweedFS | **외부 공유 SeaweedFS 단일 배포**, prod 동거 경합 | ❌ 오히려 경합↑ |
| 변환/쿼리 Trino | 스캔·조인 CPU/split 병렬 (I/O 천장 내) | ✅ **여기만 효과** |
| 메타/소파일 | snapshot/manifest, 작은 Parquet 누적 | ❌ compaction 문제 |

**결론**: 멀티노드는 "큰 Trino 쿼리/무거운 dbt 변환이 CPU·스캔 병렬
바운드이고 SeaweedFS 대역이 천장이 아닐 때만" 효과. 그런데 현재
1차 원인은 노드 수가 아니라 **한 노드의 Trino 자원 기아 + 설정
버그(heap>limit OOM)**. 우선순위:

```
1순위(즉효)  Trino 단일 워커 수직 증설 + 메모리/스레드 튜닝  ← 본 문서
2순위(구조)  maxdl 전용 객체 스토리지 분리(공유 SeaweedFS 천장·부패 위험)
             → 외부 운영 S3 사용 결정. **엔드포인트 SSOT 일원화 완료**:
               endpoint/region/bucket/키 모두 secrets.env→seaweedfs-s3
               시크릿 단일출처(Trino/Polaris/Airbyte/catalog-bootstrap
               하드코딩 제거). 운영 전환=secrets.env 5값 교체+재봉인
               +helmfile sync, 코드 변경 0.
3순위(지속)  Iceberg compaction(rewrite_data_files·snapshot expire)
4순위(선택)  그 다음에 멀티노드(Trino 워커 수평 확장)
```
멀티노드를 1·2순위보다 먼저 하면 공유 SeaweedFS 경합만 키워
maxdl·maxplatform 양쪽이 함께 느려질 수 있다.

---

## 2. 근본 원인과 튜닝값 (실측 기반)

- 노드: **24 vCPU / ~90 GiB** 단일(k3d). 동거: Airbyte(10pod)/
  Airflow/Polaris-PG/Superset + 호스트 Docker SeaweedFS(운영 공유).
- 핀 차트 `trino/trino 1.42.2` 기본 `jvm.maxHeapSize=8G`.
- 기존 값: coordinator mem **limit 4Gi**, worker **6Gi**, cpu req
  각 **500m**.
- → **heap 8G > limit 4/6Gi = 부하 시 OOMKill**(= dbt 중 Trino OOM·
  `--threads` 강제 축소의 직접 원인). 24코어·90GiB 를 거의 안 씀.

### 변경 요약 (`values.yaml` → `values.yaml_bak`)

| 항목 | 기존 | 튜닝본 | 이유 |
|---|---|---|---|
| coordinator req/lim | 500m·2Gi / —·4Gi | cpu2·10Gi / cpu4·12Gi | 플래너 자원 |
| coordinator heap | (기본 8G, **>limit**) | **9G** (=12Gi·75%) | OOM 버그 수정 |
| coordinator query.maxMemPerNode / headroom | 1GB / 미설정 | 4GB / 3GB | 명시 |
| worker req/lim | 500m·2Gi / —·6Gi | cpu6·20Gi / cpu16·24Gi | 실행 엔진 |
| worker heap | (기본 8G, **>limit**) | **18G** (=24Gi·75%) | OOM 수정+여유 |
| worker query.maxMemPerNode / headroom | 1GB / 미설정 | 9GB / 5GB | ≈0.5*heap |
| query.max-memory | (기본) | 18GB | 분산 누계 한도 |
| task.concurrency | (기본=코어) | 16 | 스캔/조인 병렬 |
| task.max-worker-threads | (기본) | 32 | ≈2×유효코어 |
| task.scale-writers / max-writer-count | (기본) | true / 2 | 쓰기 스케일(소파일 억제 위해 2 보수) |

Trino 봉투 = worker 24Gi + coordinator 12Gi ≈ **36Gi / CPU req 8** →
~54Gi·16vCPU 를 동거 워크로드에 잔여(과거 eviction 인시던트 고려).

### dbt 동시성 (별개 파일 — 본 PR 범위 아님)

`dbt/maxdl_transform/profiles.yml` 의 `threads: 4`(OOM 회피로 낮춤).
worker 증설 적용·안정 확인 후 **6→8** 로 단계 상향 권장. dbt thread
1개 = 동시 Trino 쿼리 1개라 한 번에 올리지 말 것. (이건 dbt 아티팩트
경로라 trino sync 와 무관 — `airflow-artifact-publish`+Airflow
rollout 흐름. 본 문서 §3 와 분리.)

---

## 3. 적용 절차 (운영자가 원할 때 수동)

> 전제: 라이브 클러스터 변경 + **진행 중 쿼리/dbt run 중단**(Trino
> graceful drain 미설정). **활동 적은 시간대**에 수행.

### 3-1. 사전 — 노드 여유 점검 (롤링 중 일시적 자원 2배)

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # 폐쇄망. k3d 면 생략
kubectl describe node | grep -A6 'Allocated resources'
kubectl -n maxdl-query top pod
```
worker 24Gi 가 롤링 중 old+new 공존 시 ~48Gi 순간 필요. 여유 부족
이면 §3-2 에서 worker 를 `strategy: Recreate` 로(짧은 중단 감수)
하거나 동거 부하 낮은 시간 선택.

### 3-2. 활성 파일 교체 (백업 → 적용)

```bash
cd ~/project/maxdl
cp charts/trino/values.yaml charts/trino/values.yaml.orig   # 원본 백업(롤백용)
cp charts/trino/values.yaml_bak charts/trino/values.yaml     # 튜닝본 활성화
git diff --stat charts/trino/values.yaml                      # 변경 확인(선택)
```

### 3-3. 적용 (trino 릴리스만 helm upgrade)

```bash
helmfile -f helmfile.yaml -l name=trino sync
kubectl -n maxdl-query rollout status deploy/trino-coordinator
kubectl -n maxdl-query rollout status deploy/trino-worker
# ConfigMap 변경이 자동 롤 안 되는 전례(accessControl) 대비 — 명시 롤:
kubectl -n maxdl-query rollout restart deploy/trino-coordinator deploy/trino-worker
```

### 3-4. 검증

```bash
# 새 heap 실제 적용?
kubectl -n maxdl-query exec deploy/trino-worker -- \
  bash -c 'ps aux | grep -o "Xmx[0-9A-Za-z]*"'        # → Xmx18g 류
kubectl -n maxdl-query get pod -o custom-columns=\
'POD:.metadata.name,CPU-REQ:.spec.containers[0].resources.requests.cpu,MEM-LIM:.spec.containers[0].resources.limits.memory'
kubectl -n maxdl-query get events --field-selector reason=OOMKilling   # 비어야 정상
# 부하 하 측정(추정 금지): 대표 dbt Silver 실행 중
kubectl -n maxdl-query top pod
# 무거운 쿼리에 EXPLAIN ANALYZE — 대기/스캔 지배면 SeaweedFS I/O 천장
#   신호(= 메모리·코어 더 줘도 무효 → 2순위/멀티노드 논의로 회귀)
```

### 3-5. 롤백 (문제 시 즉시)

```bash
cp charts/trino/values.yaml.orig charts/trino/values.yaml
helmfile -f helmfile.yaml -l name=trino sync
kubectl -n maxdl-query rollout restart deploy/trino-coordinator deploy/trino-worker
# 또는 helm 직접: helm -n maxdl-query rollback trino
```

---

## 4. 정직한 한계

- 튜닝값은 **검증된 시작점**이지 "X% 빨라짐" 보장이 아님 — §3-4
  부하 측정 후 1~2회 반복 조정 전제.
- worker writer 수↑ 는 동시쓰기 ↑ 지만 **작은 Parquet 폭증**(3순위
  compaction 악화) → `max-writer-count=2` 보수, 속도는 compaction 으로.
- 메모리·코어를 늘려도 **입력이 공유 SeaweedFS I/O 에 묶이면 거기서
  막힘**(§3-4 EXPLAIN ANALYZE 로 판별). 본 튜닝은 자원 기아·OOM 해소
  지 객체스토어 천장 이동이 아님 — 그건 2순위(전용 스토리지 분리).
- 단일 노드 동거(Airbyte/Airflow/…): 봉투를 36Gi/8vCPU 로 제한한
  이유. 더 키우려면 동거 부하 시간대 겹침을 먼저 측정.
- `values.yaml_bak` 은 helmfile 미참조 = 머지해도 **무적용**. 적용은
  §3-2 교체 + §3-3 sync 를 운영자가 명시 수행해야만 일어남.
