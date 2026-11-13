#!/usr/bin/env bash
# Gradle dependency cache: ~/.gradle/caches and ~/.gradle/wrapper, keyed by the
# hash of the Gradle build files. Cache id: gradle-deps.

GRADLE_DEPS_ID="gradle-deps"

# _gradle_deps_object: print the object key for the current build files.
# Returns 1 if none of the key files exists.
_gradle_deps_object() {
  local files=() file hash
  for file in ${CFG_GRADLE_KEY_FILES[@]+"${CFG_GRADLE_KEY_FILES[@]}"}; do
    case "${file}" in
      /*) files+=("${file}") ;;
      *) files+=("${CFG_SOURCE_DIR}/${file}") ;;
    esac
  done
  hash="$(key_hash_files "${CFG_GRADLE_KEY_IGNORE_PATTERN}" ${files[@]+"${files[@]}"})" || return 1
  storage_object "gradle-${hash}.tar.zst"
}

# _gradle_deps_size FILE: size in bytes.
_gradle_deps_size() {
  wc -c <"$1" | tr -d ' '
}

# _gradle_deps_fetch KEY: download KEY and extract it into $HOME. Logs the reason on failure.
_gradle_deps_fetch() {
  local key="$1" tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-gradle.XXXXXX")" || {
    log_cache "${GRADLE_DEPS_ID}" "cannot create a temporary file"
    return 1
  }
  if ! storage_get "${key}" "${tmp}"; then
    rm -f "${tmp}"
    return 2
  fi
  if archive_extract "${tmp}" "${HOME}"; then
    log_cache "${GRADLE_DEPS_ID}" "restored ${key} ($(_gradle_deps_size "${tmp}") bytes)"
  else
    log_cache "${GRADLE_DEPS_ID}" "archive ${key} is damaged or could not be extracted"
    rc=1
  fi
  rm -f "${tmp}"
  return "${rc}"
}

cache_gradle_deps_restore() {
  local object latest rc
  if ! object="$(_gradle_deps_object)"; then
    log_cache "${GRADLE_DEPS_ID}" "no Gradle key file found, restore skipped"
    out_result "${GRADLE_DEPS_ID}" skipped
    return 0
  fi

  _gradle_deps_fetch "${object}" && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    state_set GRADLE_DEPS_EXACT_KEY "${object}"
    out_result "${GRADLE_DEPS_ID}" exact
    return 0
  fi
  if [ "${rc}" -eq 1 ]; then
    out_result "${GRADLE_DEPS_ID}" none
    return 0
  fi

  if ! latest="$(storage_latest "gradle-")"; then
    log_cache "${GRADLE_DEPS_ID}" "could not list stored archives, nothing restored"
    out_result "${GRADLE_DEPS_ID}" none
    return 0
  fi
  if [ -z "${latest}" ]; then
    log_cache "${GRADLE_DEPS_ID}" "no cache found (looked for ${object})"
    out_result "${GRADLE_DEPS_ID}" none
    return 0
  fi
  if _gradle_deps_fetch "${latest}"; then
    out_result "${GRADLE_DEPS_ID}" fallback
  else
    log_cache "${GRADLE_DEPS_ID}" "fallback ${latest} could not be restored"
    out_result "${GRADLE_DEPS_ID}" none
  fi
  return 0
}

cache_gradle_deps_save() {
  local object tmp paths=() dir
  if ! object="$(_gradle_deps_object)"; then
    log_cache "${GRADLE_DEPS_ID}" "no Gradle key file found, save skipped"
    out_save "${GRADLE_DEPS_ID}" skipped
    return 0
  fi
  for dir in .gradle/caches .gradle/wrapper; do
    [ -e "${HOME}/${dir}" ] && paths+=("${dir}")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    log_cache "${GRADLE_DEPS_ID}" "nothing to save: ${HOME}/.gradle/caches and ${HOME}/.gradle/wrapper do not exist"
    out_save "${GRADLE_DEPS_ID}" skipped
    return 0
  fi

  if [ "$(state_get GRADLE_DEPS_EXACT_KEY)" = "${object}" ]; then
    if storage_touch "${object}"; then
      log_cache "${GRADLE_DEPS_ID}" "cache ${object} is current, date renewed"
      out_save "${GRADLE_DEPS_ID}" refreshed
    else
      log_cache "${GRADLE_DEPS_ID}" "could not renew the date of ${object}"
      out_save "${GRADLE_DEPS_ID}" failed
    fi
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-gradle.XXXXXX")" || {
    log_cache "${GRADLE_DEPS_ID}" "cannot create a temporary file"
    out_save "${GRADLE_DEPS_ID}" failed
    return 0
  }
  if ! archive_create "${tmp}" "${HOME}" "${paths[@]}" -- .gradle/caches/build-cache-1; then
    log_cache "${GRADLE_DEPS_ID}" "could not create the archive"
    out_save "${GRADLE_DEPS_ID}" failed
  elif storage_put "${tmp}" "${object}"; then
    log_cache "${GRADLE_DEPS_ID}" "uploaded ${object} ($(_gradle_deps_size "${tmp}") bytes)"
    out_save "${GRADLE_DEPS_ID}" uploaded
  else
    log_cache "${GRADLE_DEPS_ID}" "upload of ${object} failed"
    out_save "${GRADLE_DEPS_ID}" failed
  fi
  rm -f "${tmp}"
  return 0
}
