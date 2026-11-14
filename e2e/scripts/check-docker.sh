#!/usr/bin/env bash
# Probes which ways of running MinIO work on this machine, using start-minio.sh (which holds the
# pinned image and binary checksums): Docker, then the MinIO binary. For each, it starts MinIO,
# writes one object, reads it back, and prints `docker: ok` or `docker: unavailable` (reason on
# the next line), then the same for `binary`. Exits 0 if at least one method works.
# Everything lives in a temporary directory that is removed at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s3-build-cache-check.XXXXXX")"
export TMPDIR="${WORK}"
export S3_CACHE_MINIO_STATE="${WORK}/minio.state"
trap '"${SCRIPT_DIR}/stop-minio.sh" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT

probe() {
  local runtime="$1" log="${WORK}/${1}.log" exports
  if ! exports="$(S3_CACHE_MINIO_RUNTIME="${runtime}" "${SCRIPT_DIR}/start-minio.sh" 2>"${log}")"; then
    echo "${runtime}: unavailable"
    tail -n 1 "${log}"
    return 1
  fi
  (
    eval "${exports}"
    export AWS_ACCESS_KEY_ID="${S3_CACHE_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${S3_CACHE_SECRET_ACCESS_KEY}" AWS_DEFAULT_REGION=us-east-1
    printf 'probe-%s' "${runtime}" >"${WORK}/in.txt"
    aws --endpoint-url "${S3_CACHE_ENDPOINT}" s3 cp --only-show-errors "${WORK}/in.txt" "s3://${S3_CACHE_BUCKET}/probe.txt" &&
      aws --endpoint-url "${S3_CACHE_ENDPOINT}" s3 cp --only-show-errors "s3://${S3_CACHE_BUCKET}/probe.txt" "${WORK}/out.txt" &&
      cmp -s "${WORK}/in.txt" "${WORK}/out.txt"
  ) >"${log}" 2>&1
  local rc=$?
  "${SCRIPT_DIR}/stop-minio.sh" >/dev/null 2>&1
  if [ "${rc}" -ne 0 ]; then
    echo "${runtime}: unavailable"
    echo "MinIO started but writing and reading an object failed: $(tail -n 1 "${log}")"
    return 1
  fi
  echo "${runtime}: ok"
}

ok=0
probe docker && ok=1
probe binary && ok=1
if [ "${ok}" -eq 0 ]; then
  echo "neither Docker nor the MinIO binary can run MinIO here" >&2
  exit 1
fi
