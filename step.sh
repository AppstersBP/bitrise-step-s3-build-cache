#!/usr/bin/env bash
# Entry point of the S3 Build Cache step.
set -uo pipefail

S3_CACHE_STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for s3_cache_lib in "${S3_CACHE_STEP_DIR}"/lib/*.sh "${S3_CACHE_STEP_DIR}"/lib/caches/*.sh; do
  # shellcheck source=/dev/null
  [ -f "${s3_cache_lib}" ] && source "${s3_cache_lib}"
done
unset s3_cache_lib

if [ "${S3_CACHE_NO_MAIN:-}" != "1" ]; then
  main "$@"
fi
