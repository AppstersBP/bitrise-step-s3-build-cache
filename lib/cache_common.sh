#!/usr/bin/env bash
# Helpers shared by the cache modules in lib/caches.

# cache_branch: print the sanitised current branch ("unknown" if unset).
cache_branch() {
  local branch="${BITRISE_GIT_BRANCH:-}"
  if [ -z "${branch}" ]; then
    log_warn "BITRISE_GIT_BRANCH is empty, using the branch name \"unknown\""
    branch="unknown"
  fi
  key_branch "${branch}"
}

# cache_archive_size FILE: print the size in bytes.
cache_archive_size() {
  wc -c <"$1" | tr -d ' '
}

# cache_fetch CACHE_ID KEY BASE_DIR: download KEY and extract it into BASE_DIR.
# Returns 0 restored, 1 downloaded but not extracted, 2 not downloaded.
cache_fetch() {
  local id="$1" key="$2" base="$3" tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-fetch.XXXXXX")" || {
    log_cache "${id}" "cannot create a temporary file"
    return 1
  }
  if ! storage_get "${key}" "${tmp}"; then
    rm -f "${tmp}"
    return 2
  fi
  if archive_extract "${tmp}" "${base}"; then
    log_cache "${id}" "restored ${key} ($(cache_archive_size "${tmp}") bytes)"
  else
    log_cache "${id}" "archive ${key} is damaged or could not be extracted"
    rc=1
  fi
  rm -f "${tmp}"
  return "${rc}"
}

# cache_restore_chain CACHE_ID NAME_PREFIX BASE_DIR: restore a per-branch cache
# stored as <NAME_PREFIX><branch>.tar.zst. Tries the current branch (result
# exact), the fallback branch if it differs (fallback), then the newest object
# under NAME_PREFIX (fallback), without downloading a key twice. Sets the result
# with out_result; always returns 0.
cache_restore_chain() {
  local id="$1" prefix="$2" base="$3"
  local branch fallback object entry key result latest
  local candidates=() tried=()

  branch="$(cache_branch)"
  object="$(storage_object "${prefix}${branch}.tar.zst")"
  candidates+=("exact:${object}")
  if [ -n "${CFG_FALLBACK_BRANCH:-}" ]; then
    fallback="$(key_branch "${CFG_FALLBACK_BRANCH}")"
    if [ "${fallback}" != "${branch}" ]; then
      candidates+=("fallback:$(storage_object "${prefix}${fallback}.tar.zst")")
    fi
  fi

  for entry in "${candidates[@]}"; do
    result="${entry%%:*}"
    key="${entry#*:}"
    tried+=("${key}")
    if cache_fetch "${id}" "${key}" "${base}"; then
      out_result "${id}" "${result}"
      return 0
    fi
  done

  if ! latest="$(storage_latest "${prefix}")"; then
    log_cache "${id}" "could not list stored archives, nothing restored"
    out_result "${id}" none
    return 0
  fi
  if [ -z "${latest}" ]; then
    log_cache "${id}" "no cache found (looked for ${object})"
    out_result "${id}" none
    return 0
  fi
  for key in "${tried[@]}"; do
    if [ "${key}" = "${latest}" ]; then
      log_cache "${id}" "no cache found (newest archive ${latest} was already tried)"
      out_result "${id}" none
      return 0
    fi
  done
  if cache_fetch "${id}" "${latest}" "${base}"; then
    out_result "${id}" fallback
  else
    log_cache "${id}" "fallback ${latest} could not be restored"
    out_result "${id}" none
  fi
  return 0
}
