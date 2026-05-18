#!/usr/bin/env python3
"""
s3artifact.py — 의존성 없는 S3(SigV4) 단일 객체 PUT/GET (stdlib 전용)

SeaweedFS S3(path-style, 커스텀 엔드포인트)에 아티팩트 1개를 올리고/내린다.
publish 스크립트(빌드측)와 Airflow initContainer(런타임)가 공유 → boto3/aws
CLI 불필요(폐쇄망·기존 Airflow 이미지 재사용).

환경변수(전부 필수 — fallback 없음):
  ARTIFACT_S3_ENDPOINT   예) http://host.k3d.internal:8333  (빌드측은 :8333)
  ARTIFACT_S3_REGION     예) kr-dw-pt-001
  ARTIFACT_S3_BUCKET     예) maxdl-warehouse
  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   (seaweedfs-s3 자격)

사용:
  python3 s3artifact.py put <key> <localfile>
  python3 s3artifact.py get <key> <localfile>   ('-' 면 stdout)
"""
import os, sys, hashlib, hmac, datetime, urllib.request, urllib.error

def _env(k):
    v = os.environ.get(k)
    if not v:
        sys.exit(f"ERROR: 환경변수 {k} 필요(미설정) — fallback 없음")
    return v

def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def _sigv4_headers(method, host, uri, region, payload: bytes, ak, sk):
    """AWS SigV4(service=s3) 서명 헤더 생성 — path-style 고정."""
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(payload).hexdigest()
    canon_headers = (f"host:{host}\n"
                     f"x-amz-content-sha256:{payload_hash}\n"
                     f"x-amz-date:{amz_date}\n")
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canon_req = (f"{method}\n{uri}\n\n{canon_headers}\n"
                 f"{signed_headers}\n{payload_hash}")
    scope = f"{datestamp}/{region}/s3/aws4_request"
    to_sign = ("AWS4-HMAC-SHA256\n" + amz_date + "\n" + scope + "\n"
               + hashlib.sha256(canon_req.encode()).hexdigest())
    k_date = _sign(("AWS4" + sk).encode(), datestamp)
    k_region = _sign(k_date, region)
    k_service = _sign(k_region, "s3")
    k_signing = _sign(k_service, "aws4_request")
    sig = hmac.new(k_signing, to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={sig}")
    return {"Authorization": auth, "x-amz-date": amz_date,
            "x-amz-content-sha256": payload_hash}

def _do(method, key, payload: bytes):
    ep = _env("ARTIFACT_S3_ENDPOINT").rstrip("/")
    region = _env("ARTIFACT_S3_REGION")
    bucket = _env("ARTIFACT_S3_BUCKET")
    ak = _env("AWS_ACCESS_KEY_ID")
    sk = _env("AWS_SECRET_ACCESS_KEY")
    host = ep.split("://", 1)[1]
    uri = f"/{bucket}/{key.lstrip('/')}"               # path-style
    headers = _sigv4_headers(method, host, uri, region, payload, ak, sk)
    req = urllib.request.Request(ep + uri, data=(payload if method == "PUT" else None),
                                 method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR: S3 {method} {uri} HTTP {e.code}: {e.read()[:300]!r}")

def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("put", "get"):
        sys.exit(__doc__)
    op, key, path = sys.argv[1:4]
    if op == "put":
        with open(path, "rb") as f:
            data = f.read()
        _do("PUT", key, data)
        print(f"PUT s3://{os.environ.get('ARTIFACT_S3_BUCKET')}/{key} "
              f"({len(data)} bytes)")
    else:
        body = _do("GET", key, b"")
        if path == "-":
            sys.stdout.buffer.write(body)
        else:
            with open(path, "wb") as f:
                f.write(body)
            print(f"GET s3://{os.environ.get('ARTIFACT_S3_BUCKET')}/{key} "
                  f"→ {path} ({len(body)} bytes)")

if __name__ == "__main__":
    main()
