#!/usr/bin/env bash
# CocoaPods: the Pods directory, keyed by the hash of the lock file. Restores
# only the exact key, since a Pods directory built from another lock file is
# not safe to use. Cache id: cocoapods.

COCOAPODS_ID="cocoapods"

# _cocoapods_abs PATH: PATH as given if absolute, else relative to the source dir.
_cocoapods_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "${CFG_SOURCE_DIR}" "$1" ;;
  esac
}

# _cocoapods_object: print the object key for the current lock file.
# Returns 1 if the lock file does not exist.
_cocoapods_object() {
  local lock hash
  lock="$(_cocoapods_abs "${CFG_COCOAPODS_LOCKFILE}")"
  hash="$(key_hash_file "${lock}")" || return 1
  storage_object "pods-${hash}.tar.zst"
}

# _cocoapods_paths: set _COCOAPODS_BASE (directory the archive is relative to)
# and _COCOAPODS_PATH (the Pods directory relative to it).
_cocoapods_paths() {
  local dir
  dir="$(_cocoapods_abs "${CFG_COCOAPODS_DIR}")"
  dir="${dir%/}"
  case "${dir}" in
    "${CFG_SOURCE_DIR%/}"/*)
      _COCOAPODS_BASE="${CFG_SOURCE_DIR%/}"
      _COCOAPODS_PATH="${dir#"${CFG_SOURCE_DIR%/}"/}"
      ;;
    *)
      _COCOAPODS_BASE="$(dirname "${dir}")"
      _COCOAPODS_PATH="$(basename "${dir}")"
      ;;
  esac
}

cache_cocoapods_restore() {
  local object
  if ! object="$(_cocoapods_object)"; then
    log_cache "${COCOAPODS_ID}" "warning: lock file ${CFG_COCOAPODS_LOCKFILE} not found, restore skipped"
    out_result "${COCOAPODS_ID}" skipped
    return 0
  fi
  _cocoapods_paths

  if cache_fetch "${COCOAPODS_ID}" "${object}" "${_COCOAPODS_BASE}"; then
    state_set COCOAPODS_EXACT_KEY "${object}"
    out_result "${COCOAPODS_ID}" exact
  else
    log_cache "${COCOAPODS_ID}" "no cache restored (looked for ${object})"
    out_result "${COCOAPODS_ID}" none
  fi
  return 0
}

cache_cocoapods_save() {
  local object tmp
  if ! object="$(_cocoapods_object)"; then
    log_cache "${COCOAPODS_ID}" "lock file ${CFG_COCOAPODS_LOCKFILE} not found, save skipped"
    out_save "${COCOAPODS_ID}" skipped
    return 0
  fi
  _cocoapods_paths
  if [ ! -e "${_COCOAPODS_BASE}/${_COCOAPODS_PATH}" ]; then
    log_cache "${COCOAPODS_ID}" "nothing to save: ${_COCOAPODS_BASE}/${_COCOAPODS_PATH} does not exist"
    out_save "${COCOAPODS_ID}" skipped
    return 0
  fi

  if [ "$(state_get COCOAPODS_EXACT_KEY)" = "${object}" ]; then
    if storage_touch "${object}"; then
      log_cache "${COCOAPODS_ID}" "cache ${object} is current, date renewed"
      out_save "${COCOAPODS_ID}" refreshed
    else
      log_cache "${COCOAPODS_ID}" "could not renew the date of ${object}"
      out_save "${COCOAPODS_ID}" failed
    fi
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-cocoapods.XXXXXX")" || {
    log_cache "${COCOAPODS_ID}" "cannot create a temporary file"
    out_save "${COCOAPODS_ID}" failed
    return 0
  }
  if ! archive_create "${tmp}" "${_COCOAPODS_BASE}" "${_COCOAPODS_PATH}"; then
    log_cache "${COCOAPODS_ID}" "could not create the archive"
    out_save "${COCOAPODS_ID}" failed
  elif storage_put "${tmp}" "${object}"; then
    log_cache "${COCOAPODS_ID}" "uploaded ${object} ($(cache_archive_size "${tmp}") bytes)"
    out_save "${COCOAPODS_ID}" uploaded
  else
    log_cache "${COCOAPODS_ID}" "upload of ${object} failed"
    out_save "${COCOAPODS_ID}" failed
  fi
  rm -f "${tmp}"
  return 0
}
