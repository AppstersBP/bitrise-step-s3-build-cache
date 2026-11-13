#!/usr/bin/env bash
# Logging helpers. All output goes to stderr so that stdout can carry values.

log_info() { printf '[s3-build-cache] %s\n' "$*" >&2; }
log_warn() { printf '[s3-build-cache] WARNING: %s\n' "$*" >&2; }
log_error() { printf '[s3-build-cache] ERROR: %s\n' "$*" >&2; }

# log_cache CACHE_ID MSG...
log_cache() {
  local id="$1"
  shift
  printf '[s3-build-cache:%s] %s\n' "${id}" "$*" >&2
}
