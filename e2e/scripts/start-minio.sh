#!/usr/bin/env bash
# Starts a MinIO server for tests and prints nothing but `export` lines on stdout:
#   eval "$(e2e/scripts/start-minio.sh)"
# Prefers Docker; falls back to the MinIO binary. Everything else goes to stderr.
# Stop it with e2e/scripts/stop-minio.sh.
set -euo pipefail

# MinIO no longer publishes images or binaries itself; the community build of the
# same server is used (identical command line and S3 behaviour).
MINIO_RELEASE="RELEASE.2026-08-04T00-00-00Z"
MINIO_IMAGE="pgsty/minio:${MINIO_RELEASE}"
MINIO_BINARY_VERSION="20260804000000.0.0"
MINIO_BINARY_URL="https://github.com/pgsty/minio/releases/download/${MINIO_RELEASE}"

ACCESS_KEY="s3cache-test-user"
SECRET_KEY="s3cache-test-secret"
BUCKET="test"
STATE_FILE="${S3_CACHE_MINIO_STATE:-${TMPDIR:-/tmp}/s3-build-cache-minio.state}"

say() { printf '[start-minio] %s\n' "$*" >&2; }

if [ -f "${STATE_FILE}" ]; then
  say "a MinIO started earlier is recorded in ${STATE_FILE}; run stop-minio.sh first"
  exit 1
fi

free_port() {
  local port
  for _ in $(seq 1 50); do
    port=$((20000 + RANDOM % 20000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      printf '%s' "${port}"
      return 0
    fi
  done
  return 1
}

PORT="$(free_port)" || {
  say "no free port found"
  exit 1
}
ENDPOINT="http://127.0.0.1:${PORT}"

start_docker() {
  local id
  id="$(docker run -d -p "127.0.0.1:${PORT}:9000" \
    -e "MINIO_ROOT_USER=${ACCESS_KEY}" -e "MINIO_ROOT_PASSWORD=${SECRET_KEY}" \
    "${MINIO_IMAGE}" server /data)" || return 1
  printf 'docker %s\n' "${id}" >"${STATE_FILE}"
  say "started container ${id:0:12} on port ${PORT}"
}

start_binary() {
  local os arch dir archive sum
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) say "unsupported operating system $(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) say "unsupported architecture $(uname -m)"; return 1 ;;
  esac
  dir="$(mktemp -d "${TMPDIR:-/tmp}/s3-build-cache-minio.XXXXXX")"
  archive="minio_${MINIO_BINARY_VERSION}_${os}_${arch}.tar.gz"
  say "downloading ${archive}"
  if ! { curl -fsSL -o "${dir}/${archive}" "${MINIO_BINARY_URL}/${archive}" &&
    curl -fsSL -o "${dir}/checksums.txt" "${MINIO_BINARY_URL}/minio_${MINIO_BINARY_VERSION}_checksums.txt"; }; then
    rm -rf "${dir}"
    return 1
  fi
  sum="$(awk -v f="${archive}" '$2 == f { print $1 }' "${dir}/checksums.txt")"
  if [ -z "${sum}" ] || [ "$( (sha256sum "${dir}/${archive}" 2>/dev/null || shasum -a 256 "${dir}/${archive}") | awk '{ print $1 }')" != "${sum}" ]; then
    say "checksum of ${archive} does not match"
    rm -rf "${dir}"
    return 1
  fi
  tar -xzf "${dir}/${archive}" -C "${dir}" minio
  mkdir -p "${dir}/data"
  MINIO_ROOT_USER="${ACCESS_KEY}" MINIO_ROOT_PASSWORD="${SECRET_KEY}" \
    nohup "${dir}/minio" server "${dir}/data" --address "127.0.0.1:${PORT}" --console-address "127.0.0.1:0" \
    >"${dir}/minio.log" 2>&1 &
  printf 'binary %s %s\n' "$!" "${dir}" >"${STATE_FILE}"
  say "started the MinIO binary (pid $!) on port ${PORT}"
}

# S3_CACHE_MINIO_RUNTIME=binary skips Docker (used to test the fallback).
if [ "${S3_CACHE_MINIO_RUNTIME:-}" != binary ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  start_docker || {
    say "Docker could not start MinIO, trying the binary"
    rm -f "${STATE_FILE}"
    start_binary
  }
else
  start_binary
fi

for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "${ENDPOINT}/minio/health/ready" 2>/dev/null && ready=1 && break
  sleep 1
done
if [ -z "${ready:-}" ]; then
  say "MinIO did not become ready within 60 seconds"
  "$(dirname "${BASH_SOURCE[0]}")/stop-minio.sh" >&2 || true
  exit 1
fi

AWS_ACCESS_KEY_ID="${ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url "${ENDPOINT}" s3api create-bucket --bucket "${BUCKET}" >/dev/null || {
  say "could not create the bucket ${BUCKET}"
  "$(dirname "${BASH_SOURCE[0]}")/stop-minio.sh" >&2 || true
  exit 1
}

printf 'export S3_CACHE_ENDPOINT=%q\n' "${ENDPOINT}"
printf 'export S3_CACHE_ACCESS_KEY_ID=%q\n' "${ACCESS_KEY}"
printf 'export S3_CACHE_SECRET_ACCESS_KEY=%q\n' "${SECRET_KEY}"
printf 'export S3_CACHE_BUCKET=%q\n' "${BUCKET}"
