#!/usr/bin/env bash
# Stops the MinIO server that start-minio.sh started. Does nothing if none is recorded.
set -uo pipefail

STATE_FILE="${S3_CACHE_MINIO_STATE:-${TMPDIR:-/tmp}/s3-build-cache-minio.state}"

if [ ! -f "${STATE_FILE}" ]; then
  echo "[stop-minio] no MinIO recorded" >&2
  exit 0
fi

read -r kind first second <"${STATE_FILE}"
case "${kind}" in
  docker)
    # Docker finds its configuration and context through the HOME of the start.
    if ! HOME="${second:-${HOME}}" docker rm -f "${first}" >/dev/null; then
      echo "[stop-minio] could not remove container ${first}; state file kept: ${STATE_FILE}" >&2
      exit 1
    fi
    ;;
  external)
    # Started by someone else (for example docker compose); left running.
    ;;
  binary)
    kill "${first}" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "${first}" 2>/dev/null || break; sleep 1; done
    kill -9 "${first}" 2>/dev/null
    [ -n "${second}" ] && rm -rf "${second}"
    ;;
esac
rm -f "${STATE_FILE}"
echo "[stop-minio] stopped" >&2
exit 0
