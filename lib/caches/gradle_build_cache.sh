#!/usr/bin/env bash
# Gradle build cache: ~/.gradle/caches/build-cache-1, kept per branch. Cache id:
# gradle-build-cache.

GRADLE_BUILD_CACHE_ID="gradle-build-cache"

# _gradle_build_cache_branch: print the sanitised current branch ("unknown" if unset).
_gradle_build_cache_branch() {
  local branch="${BITRISE_GIT_BRANCH:-}"
  if [ -z "${branch}" ]; then
    log_warn "BITRISE_GIT_BRANCH is empty, using the branch name \"unknown\""
    branch="unknown"
  fi
  key_branch "${branch}"
}

# _gradle_build_cache_object BRANCH: print the object key for a sanitised branch.
_gradle_build_cache_object() {
  storage_object "buildcache-gradle-$1.tar.zst"
}

# _gradle_build_cache_size FILE: size in bytes.
_gradle_build_cache_size() {
  wc -c <"$1" | tr -d ' '
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

# _gradle_build_cache_fetch KEY: download KEY and extract it into $HOME.
# Returns 0 restored, 1 downloaded but not extracted, 2 not downloaded.
_gradle_build_cache_fetch() {
  local key="$1" tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-gradle-bc.XXXXXX")" || {
    log_cache "${GRADLE_BUILD_CACHE_ID}" "cannot create a temporary file"
    return 1
  }
  if ! storage_get "${key}" "${tmp}"; then
    rm -f "${tmp}"
    return 2
  fi
  if archive_extract "${tmp}" "${HOME}"; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "restored ${key} ($(_gradle_build_cache_size "${tmp}") bytes)"
  else
    log_cache "${GRADLE_BUILD_CACHE_ID}" "archive ${key} is damaged or could not be extracted"
    rc=1
  fi
  rm -f "${tmp}"
  return "${rc}"
}

cache_gradle_build_cache_restore() {
  local branch fallback object candidates=() key latest result

  _gradle_build_cache_enable || log_cache "${GRADLE_BUILD_CACHE_ID}" "could not update gradle.properties"

  branch="$(_gradle_build_cache_branch)"
  object="$(_gradle_build_cache_object "${branch}")"
  candidates+=("exact:${object}")
  if [ -n "${CFG_FALLBACK_BRANCH:-}" ]; then
    fallback="$(key_branch "${CFG_FALLBACK_BRANCH}")"
    if [ "${fallback}" != "${branch}" ]; then
      candidates+=("fallback:$(_gradle_build_cache_object "${fallback}")")
    fi
  fi

  for key in "${candidates[@]}"; do
    result="${key%%:*}"
    key="${key#*:}"
    if _gradle_build_cache_fetch "${key}"; then
      out_result "${GRADLE_BUILD_CACHE_ID}" "${result}"
      return 0
    fi
  done

  if ! latest="$(storage_latest "buildcache-gradle-")"; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "could not list stored archives, nothing restored"
    out_result "${GRADLE_BUILD_CACHE_ID}" none
    return 0
  fi
  if [ -z "${latest}" ]; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "no cache found (looked for ${object})"
    out_result "${GRADLE_BUILD_CACHE_ID}" none
    return 0
  fi
  if _gradle_build_cache_fetch "${latest}"; then
    out_result "${GRADLE_BUILD_CACHE_ID}" fallback
  else
    log_cache "${GRADLE_BUILD_CACHE_ID}" "fallback ${latest} could not be restored"
    out_result "${GRADLE_BUILD_CACHE_ID}" none
  fi
  return 0
}

cache_gradle_build_cache_save() {
  local branch object tmp
  if [ ! -e "${HOME}/.gradle/caches/build-cache-1" ]; then
    log_cache "${GRADLE_BUILD_CACHE_ID}" "nothing to save: ${HOME}/.gradle/caches/build-cache-1 does not exist"
    out_save "${GRADLE_BUILD_CACHE_ID}" skipped
    return 0
  fi
  branch="$(_gradle_build_cache_branch)"
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
    log_cache "${GRADLE_BUILD_CACHE_ID}" "uploaded ${object} ($(_gradle_build_cache_size "${tmp}") bytes)"
    out_save "${GRADLE_BUILD_CACHE_ID}" uploaded
  else
    log_cache "${GRADLE_BUILD_CACHE_ID}" "upload of ${object} failed"
    out_save "${GRADLE_BUILD_CACHE_ID}" failed
  fi
  rm -f "${tmp}"
  return 0
}
