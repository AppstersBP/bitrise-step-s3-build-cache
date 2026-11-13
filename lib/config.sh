#!/usr/bin/env bash
# Reads the step inputs into CFG_* globals, normalises them and validates them.
# shellcheck disable=SC2034 # the CFG_* globals are consumed by the other libraries

README_CONFIG_URL="https://github.com/AppstersBP/bitrise-step-s3-build-cache#configuration"

# cfg_lines TEXT: print the non-blank lines of TEXT trimmed, without CR, de-duplicated in order.
cfg_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk '{ gsub(/^[ \t]+|[ \t]+$/, "") } NF && !seen[$0]++'
}

# cfg_init: set the CFG_* globals from the Bitrise input environment variables.
cfg_init() {
  CFG_MODE="${mode:-}"
  CFG_ENDPOINT="${endpoint:-}"
  CFG_BUCKET="${bucket:-}"
  CFG_PREFIX="${prefix:-}"
  while [ "${CFG_PREFIX}" != "${CFG_PREFIX%/}" ]; do CFG_PREFIX="${CFG_PREFIX%/}"; done
  CFG_REGION="${region:-}"
  [ -n "${CFG_REGION}" ] || CFG_REGION="us-east-1"
  CFG_ACCESS_KEY_ID="${access_key_id:-}"
  CFG_SECRET_ACCESS_KEY="${secret_access_key:-}"
  CFG_GRADLE_KEY_IGNORE_PATTERN="${gradle_key_ignore_pattern-^\\s*(versionCode|versionName)\\b}"
  CFG_FALLBACK_BRANCH="${fallback_branch-main}"
  CFG_COCOAPODS_LOCKFILE="${cocoapods_lockfile-ios/Podfile.lock}"
  CFG_COCOAPODS_DIR="${cocoapods_dir-ios/Pods}"
  CFG_CCACHE_MAX_SIZE="${ccache_max_size-5G}"
  CFG_CONNECT_TIMEOUT="${connect_timeout-10}"
  CFG_SOURCE_DIR="${BITRISE_SOURCE_DIR:-${PWD}}"

  CFG_CACHES=()
  local line
  while IFS= read -r line; do CFG_CACHES+=("${line}"); done < <(cfg_lines "${caches:-}")
  CFG_GRADLE_KEY_FILES=()
  while IFS= read -r line; do CFG_GRADLE_KEY_FILES+=("${line}"); done \
    < <(cfg_lines "${gradle_key_files-android/gradle.properties
android/build.gradle
android/app/build.gradle
pnpm-lock.yaml}")
}

# cfg_validate: 0 valid, 1 configuration error (message printed), 2 pull request build without credentials.
cfg_validate() {
  if [ -n "${BITRISE_PULL_REQUEST:-}" ] && [ -z "${CFG_ACCESS_KEY_ID}" ] && [ -z "${CFG_SECRET_ACCESS_KEY}" ]; then
    log_warn "Skipping the S3 build cache: the secrets S3_CACHE_ACCESS_KEY_ID and S3_CACHE_SECRET_ACCESS_KEY are empty in this pull request build."
    log_warn "Bitrise does not expose secrets to pull request builds unless \"Expose for Pull Requests\" is enabled for them, so these secrets are not available to pull request builds."
    return 2
  fi

  local problems=() cache
  case "${CFG_MODE}" in
    restore | save) ;;
    "") problems+=("mode: is empty (use restore or save)") ;;
    *) problems+=("mode: '${CFG_MODE}' is not restore or save") ;;
  esac
  if [ "${#CFG_CACHES[@]}" -eq 0 ]; then
    problems+=("caches: is empty (use gradle-deps, gradle-build-cache, ccache, cocoapods)")
  else
    for cache in "${CFG_CACHES[@]}"; do
      case "${cache}" in
        gradle-deps | gradle-build-cache | ccache | cocoapods) ;;
        *) problems+=("caches: unknown cache '${cache}' (use gradle-deps, gradle-build-cache, ccache, cocoapods)") ;;
      esac
    done
  fi
  [ -n "${CFG_BUCKET}" ] || problems+=("bucket (app variable S3_CACHE_BUCKET)")
  [ -n "${CFG_PREFIX}" ] || problems+=("prefix (app variable S3_CACHE_PREFIX)")
  [ -n "${CFG_ACCESS_KEY_ID}" ] || problems+=("access_key_id (secret S3_CACHE_ACCESS_KEY_ID)")
  [ -n "${CFG_SECRET_ACCESS_KEY}" ] || problems+=("secret_access_key (secret S3_CACHE_SECRET_ACCESS_KEY)")
  case "${CFG_CONNECT_TIMEOUT}" in
    "" | *[!0-9]* | 0*) problems+=("connect_timeout: '${CFG_CONNECT_TIMEOUT}' is not a positive integer") ;;
  esac
  for cache in ${CFG_CACHES[@]+"${CFG_CACHES[@]}"}; do
    if [ "${cache}" = cocoapods ]; then
      [ -n "${CFG_COCOAPODS_LOCKFILE}" ] || problems+=("cocoapods_lockfile (step input)")
      [ -n "${CFG_COCOAPODS_DIR}" ] || problems+=("cocoapods_dir (step input)")
    fi
  done
  [ -n "${CFG_CCACHE_MAX_SIZE}" ] || problems+=("ccache_max_size: is empty (for example 5G)")

  if [ "${#problems[@]}" -gt 0 ]; then
    local p
    {
      printf '[s3-build-cache] ERROR: Missing S3 build cache settings:\n'
      for p in "${problems[@]}"; do printf '  - %s\n' "${p}"; done
      printf 'See %s\n' "${README_CONFIG_URL}"
    } >&2
    return 1
  fi
  return 0
}
