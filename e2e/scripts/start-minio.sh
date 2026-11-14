#!/usr/bin/env bash
# Starts a MinIO server for tests and prints nothing but `export` lines on stdout:
#   eval "$(e2e/scripts/start-minio.sh)"
# Prefers Docker; falls back to the MinIO binary. Everything else goes to stderr.
# With S3_CACHE_MINIO_ENDPOINT set (for example http://minio:9000), it starts nothing and uses
# the MinIO already running there, which must use the credentials below
# (e2e/docker/docker-compose.yml starts one).
# Stop it with e2e/scripts/stop-minio.sh.
set -euo pipefail

# MinIO no longer publishes images or binaries itself; the community build of the
# same server is used (identical command line and S3 behaviour).
MINIO_RELEASE="RELEASE.2026-08-04T00-00-00Z"
MINIO_IMAGE="pgsty/minio:${MINIO_RELEASE}@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372"
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

if [ -n "${S3_CACHE_MINIO_ENDPOINT:-}" ]; then
  ENDPOINT="${S3_CACHE_MINIO_ENDPOINT%/}"
else
  PORT="$(free_port)" || {
    say "no free port found"
    exit 1
  }
  ENDPOINT="http://127.0.0.1:${PORT}"
fi

start_docker() {
  local id
  id="$(docker run -d -p "127.0.0.1:${PORT}:9000" \
    -e "MINIO_ROOT_USER=${ACCESS_KEY}" -e "MINIO_ROOT_PASSWORD=${SECRET_KEY}" \
    "${MINIO_IMAGE}" server /data)" || return 1
  printf 'docker %s %s\n' "${id}" "${HOME}" >"${STATE_FILE}"
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
  case "${os}-${arch}" in
    linux-amd64) sum=3c1d229209db049618cb9c6d4132fa2882b15cdded337511486e811c187eec08 ;;
    linux-arm64) sum=6c2c056a065635d943980cdcb3180247cf1a7a578b81a5271f0807569ca120e9 ;;
    darwin-amd64) sum=1ad740f70ef16463e99825b7887ae330fee7de879dd357616d781ff819cbaaad ;;
    darwin-arm64) sum=a1965c422ec9ca80068bcd2c2c115655748283916256cebd75c171cc629ade6e ;;
  esac
  say "downloading ${archive}"
  if ! curl -fsSL -o "${dir}/${archive}" "${MINIO_BINARY_URL}/${archive}"; then
    rm -rf "${dir}"
    return 1
  fi
  if [ "$( (sha256sum "${dir}/${archive}" 2>/dev/null || shasum -a 256 "${dir}/${archive}") | awk '{ print $1 }')" != "${sum}" ]; then
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

# S3_CACHE_MINIO_ENDPOINT uses a running MinIO; S3_CACHE_MINIO_RUNTIME=binary skips Docker
# (used to test the fallback); S3_CACHE_MINIO_RUNTIME=docker uses Docker only, with no fallback
# (used by check-docker.sh).
if [ -n "${S3_CACHE_MINIO_ENDPOINT:-}" ]; then
  printf 'external %s\n' "${ENDPOINT}" >"${STATE_FILE}"
  say "using the MinIO at ${ENDPOINT}"
elif [ "${S3_CACHE_MINIO_RUNTIME:-}" = docker ]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    say "Docker is not available"
    exit 1
  fi
  start_docker || {
    rm -f "${STATE_FILE}"
    exit 1
  }
elif [ "${S3_CACHE_MINIO_RUNTIME:-}" != binary ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  start_docker || {
    say "Docker could not start MinIO, trying the binary"
    rm -f "${STATE_FILE}"
    start_binary
  }
else
  start_binary
fi

for _ in $(seq 1 60); do
  curl -fsS --max-time 2 -o /dev/null "${ENDPOINT}/minio/health/ready" 2>/dev/null && ready=1 && break
  sleep 1
done
if [ -z "${ready:-}" ]; then
  say "MinIO did not become ready within 60 seconds"
  "$(dirname "${BASH_SOURCE[0]}")/stop-minio.sh" >&2 || true
  exit 1
fi

s3api() {
  AWS_ACCESS_KEY_ID="${ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url "${ENDPOINT}" s3api "$@"
}
# A MinIO that was already running may have the bucket from an earlier run.
s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1 || s3api create-bucket --bucket "${BUCKET}" >/dev/null || {
  say "could not create the bucket ${BUCKET}"
  "$(dirname "${BASH_SOURCE[0]}")/stop-minio.sh" >&2 || true
  exit 1
}

printf 'export S3_CACHE_ENDPOINT=%q\n' "${ENDPOINT}"
printf 'export S3_CACHE_ACCESS_KEY_ID=%q\n' "${ACCESS_KEY}"
printf 'export S3_CACHE_SECRET_ACCESS_KEY=%q\n' "${SECRET_KEY}"
printf 'export S3_CACHE_BUCKET=%q\n' "${BUCKET}"
