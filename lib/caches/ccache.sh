#!/usr/bin/env bash
# ccache: ~/.ccache, kept per branch. Installs ccache when missing and configures
# the build to use it. Cache id: ccache.

CCACHE_ID="ccache"

# _ccache_object BRANCH: print the object key for a sanitised branch.
_ccache_object() {
  storage_object "ccache-$1.tar.zst"
}

# _ccache_platform: Linux or Darwin (uname -s, overridable with S3_CACHE_PLATFORM).
_ccache_platform() {
  printf '%s' "${S3_CACHE_PLATFORM:-$(uname -s)}"
}

# _ccache_install: install ccache with the package manager of the platform.
# Output goes to a temporary log; on failure its last line is logged.
_ccache_install() {
  local platform log rc=0
  local -a priv=()
  platform="$(_ccache_platform)"
  log="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-ccache-install.XXXXXX")" || {
    log_cache "${CCACHE_ID}" "cannot create a temporary file"
    return 1
  }
  case "${platform}" in
    Linux)
      if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        priv=(sudo -n)
      fi
      log_cache "${CCACHE_ID}" "ccache not found, installing it with apt-get"
      { "${priv[@]+"${priv[@]}"}" apt-get update -qq &&
        "${priv[@]+"${priv[@]}"}" apt-get install -y -qq ccache; } >"${log}" 2>&1 || rc=$?
      ;;
    Darwin)
      log_cache "${CCACHE_ID}" "ccache not found, installing it with brew"
      brew install ccache >"${log}" 2>&1 || rc=$?
      ;;
    *)
      echo "unsupported platform ${platform}" >"${log}"
      rc=1
      ;;
  esac
  if [ "${rc}" -ne 0 ]; then
    log_cache "${CCACHE_ID}" "installing ccache failed: $(tail -n 1 "${log}")"
  elif ! command -v ccache >/dev/null 2>&1; then
    log_cache "${CCACHE_ID}" "installing ccache failed: ccache is still not available"
    rc=1
  fi
  rm -f "${log}"
  return "${rc}"
}

# _ccache_configure: export the variables that make builds use ccache.
_ccache_configure() {
  mkdir -p "${HOME}/.ccache" || log_cache "${CCACHE_ID}" "cannot create ${HOME}/.ccache"
  env_export CMAKE_C_COMPILER_LAUNCHER ccache &&
    env_export CMAKE_CXX_COMPILER_LAUNCHER ccache &&
    env_export CCACHE_DIR "${HOME}/.ccache" &&
    env_export CCACHE_BASEDIR "${CFG_SOURCE_DIR}" &&
    env_export CCACHE_COMPILERCHECK content
}

cache_ccache_restore() {
  if ! command -v ccache >/dev/null 2>&1 && ! _ccache_install; then
    out_result "${CCACHE_ID}" skipped
    return 0
  fi
  _ccache_configure || log_cache "${CCACHE_ID}" "could not export the ccache variables"

  cache_restore_chain "${CCACHE_ID}" "ccache-" "${HOME}"

  ccache "--max-size=${CFG_CCACHE_MAX_SIZE}" >&2 ||
    log_cache "${CCACHE_ID}" "ccache --max-size=${CFG_CCACHE_MAX_SIZE} failed"
  ccache --zero-stats >&2 || log_cache "${CCACHE_ID}" "ccache --zero-stats failed"
  return 0
}

cache_ccache_save() {
  local branch object tmp
  if ! command -v ccache >/dev/null 2>&1; then
    log_cache "${CCACHE_ID}" "ccache is not installed, nothing to save"
    out_save "${CCACHE_ID}" skipped
    return 0
  fi
  CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}" ccache --show-stats >&2 ||
    log_cache "${CCACHE_ID}" "ccache --show-stats failed"
  if [ ! -e "${HOME}/.ccache" ]; then
    log_cache "${CCACHE_ID}" "nothing to save: ${HOME}/.ccache does not exist"
    out_save "${CCACHE_ID}" skipped
    return 0
  fi
  branch="$(cache_branch)"
  object="$(_ccache_object "${branch}")"

  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-ccache.XXXXXX")" || {
    log_cache "${CCACHE_ID}" "cannot create a temporary file"
    out_save "${CCACHE_ID}" failed
    return 0
  }
  if ! archive_create "${tmp}" "${HOME}" .ccache; then
    log_cache "${CCACHE_ID}" "could not create the archive"
    out_save "${CCACHE_ID}" failed
  elif storage_put "${tmp}" "${object}"; then
    log_cache "${CCACHE_ID}" "uploaded ${object} ($(cache_archive_size "${tmp}") bytes)"
    out_save "${CCACHE_ID}" uploaded
  else
    log_cache "${CCACHE_ID}" "upload of ${object} failed"
    out_save "${CCACHE_ID}" failed
  fi
  rm -f "${tmp}"
  return 0
}
