#!/usr/bin/env bash
# Gradle build cache: ~/.gradle/caches/build-cache-1, kept per branch. Cache id:
# gradle-build-cache.

GRADLE_BUILD_CACHE_ID="gradle-build-cache"

# _gradle_build_cache_object BRANCH: print the object key for a sanitised branch.
_gradle_build_cache_object() {
  storage_object "buildcache-gradle-$1.tar.zst"
}

# _gradle_build_cache_enable: make sure ~/.gradle/gradle.properties contains the
# line org.gradle.caching=true exactly once, keeping all other lines.
_gradle_build_cache_enable() {
  local dir="${HOME}/.gradle" props="${HOME}/.gradle/gradle.properties" tmp
  mkdir -p "${dir}" || {
    log_cache "${GRADLE_BUILD_CACHE_ID}" "cannot create ${dir}, build cache not enabled"
    return 1
  }
  if [ ! -f "${props}" ]; then
    printf 'org.gradle.caching=true\n' >"${props}" || return 1
  elif grep -q '^org\.gradle\.caching=' "${props}"; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-gradle-bc.XXXXXX")" || return 1
    # Replace the first occurrence, drop any further ones.
    awk '/^org\.gradle\.caching=/ { if (!done) print "org.gradle.caching=true"; done = 1; next } { print }' \
      "${props}" >"${tmp}" && cat "${tmp}" >"${props}"
    local rc=$?
    rm -f "${tmp}"
    [ "${rc}" -eq 0 ] || return 1
  else
    # Start on a new line if the last line has no line break.
    [ -s "${props}" ] && [ -n "$(tail -c 1 "${props}")" ] && printf '\n' >>"${props}"
    printf 'org.gradle.caching=true\n' >>"${props}" || return 1
  fi
  log_cache "${GRADLE_BUILD_CACHE_ID}" "build cache enabled in ${props}"
}

cache_gradle_build_cache_restore() {
  _gradle_build_cache_enable || log_cache "${GRADLE_BUILD_CACHE_ID}" "could not update gradle.properties"

  cache_restore_chain "${GRADLE_BUILD_CACHE_ID}" "buildcache-gradle-" "${HOME}"
  return 0
}

cache_gradle_build_cache_save() {
  local branch object tmp
  if [ ! -e "${HOME}/.gradle/caches/build-cache-1" ]; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "nothing to save: ${HOME}/.gradle/caches/build-cache-1 does not exist"
    out_save "${GRADLE_BUILD_CACHE_ID}" skipped
    return 0
  fi
  branch="$(cache_branch)"
  object="$(_gradle_build_cache_object "${branch}")"

  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-gradle-bc.XXXXXX")" || {
    log_cache "${GRADLE_BUILD_CACHE_ID}" "cannot create a temporary file"
    out_save "${GRADLE_BUILD_CACHE_ID}" failed
    return 0
  }
  if ! archive_create "${tmp}" "${HOME}" .gradle/caches/build-cache-1; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "could not create the archive"
    out_save "${GRADLE_BUILD_CACHE_ID}" failed
  elif storage_put "${tmp}" "${object}"; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "uploaded ${object} ($(cache_archive_size "${tmp}") bytes)"
    out_save "${GRADLE_BUILD_CACHE_ID}" uploaded
  else
    log_cache "${GRADLE_BUILD_CACHE_ID}" "upload of ${object} failed"
    out_save "${GRADLE_BUILD_CACHE_ID}" failed
  fi
  rm -f "${tmp}"
  return 0
}
