#!/usr/bin/env bash
# Removes everything the caches restore and every build output of the sample app, so that
# the second round of an end-to-end test starts like a fresh build machine:
#   ~/.gradle (except the machine's own Gradle configuration, see below), ~/.ccache,
#   the sample app's node_modules, Pods, Android build directories and iOS DerivedData
#   (E2E_DERIVED_DATA_DIR, as in build-ios.sh).
#
# The caches live in the real home directory of the build machine. On a developer machine
# this would delete the developer's ~/.gradle, so the script refuses to run unless
# CI=true (set by Bitrise, GitHub Actions and e2e/docker) or
# S3_CACHE_E2E_ALLOW_LOCAL_WIPE=true.
#
#   clean-local.sh          check, then delete
#   clean-local.sh --check  check only (the end-to-end workflows call this first)
set -euo pipefail

say() { printf '[clean-local] %s\n' "$*" >&2; }

if [ "${CI:-}" != true ] && [ "${S3_CACHE_E2E_ALLOW_LOCAL_WIPE:-}" != true ]; then
  say "refusing to run: the end-to-end tests delete ${HOME:-~}/.gradle and ${HOME:-~}/.ccache."
  say "Run them on a CI machine or in e2e/docker (see the README, Testing), or set"
  say "S3_CACHE_E2E_ALLOW_LOCAL_WIPE=true if this home directory may be wiped."
  exit 1
fi
if [ -z "${HOME:-}" ] || [ "${HOME}" = / ]; then
  say "refusing to run: HOME is '${HOME:-}'"
  exit 1
fi
if [ "${1:-}" = --check ]; then
  say "this machine may be wiped (CI=${CI:-}, S3_CACHE_E2E_ALLOW_LOCAL_WIPE=${S3_CACHE_E2E_ALLOW_LOCAL_WIPE:-})"
  exit 0
fi

app="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sample-app" && pwd)"

# Stop the Gradle daemons of the first round; they keep files of ~/.gradle open and in memory.
if [ -x "${app}/android/gradlew" ] && [ -d "${HOME}/.gradle/wrapper/dists" ]; then
  (cd "${app}/android" && ./gradlew --stop >/dev/null 2>&1) || say "could not stop the Gradle daemons"
fi
# --stop returns before the daemons have exited, and they still write to ~/.gradle meanwhile.
for _ in $(seq 1 30); do
  pgrep -f 'GradleDaemon|KotlinCompileDaemon' >/dev/null 2>&1 || break
  sleep 1
done
pgrep -f 'GradleDaemon|KotlinCompileDaemon' >/dev/null 2>&1 &&
  say "Gradle or Kotlin daemons are still running after 30 s; removing their files anyway"

# ~/.gradle: build machines (Bitrise among them) ship their own gradle.properties and init
# scripts there, which a fresh machine has too. Keep those, and remove the build cache
# setting so that the restore step has to enable it again.
if [ -d "${HOME}/.gradle" ]; then
  find "${HOME}/.gradle" -mindepth 1 -maxdepth 1 \
    ! -name gradle.properties ! -name init.d ! -name init.gradle -exec rm -rf {} + 2>/dev/null || {
    sleep 5
    find "${HOME}/.gradle" -mindepth 1 -maxdepth 1 \
      ! -name gradle.properties ! -name init.d ! -name init.gradle -exec rm -rf {} +
  }
  props="${HOME}/.gradle/gradle.properties"
  if [ -f "${props}" ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/clean-local.XXXXXX")"
    grep -v '^[[:space:]]*org\.gradle\.caching[[:space:]]*=' "${props}" >"${tmp}" || true
    cat "${tmp}" >"${props}"
    rm -f "${tmp}"
  fi
fi

rm -rf "${HOME}/.ccache"

rm -rf \
  "${app}/node_modules" \
  "${app}/android/.gradle" \
  "${app}/android/.kotlin" \
  "${app}/android/build" \
  "${app}/android/app/build" \
  "${app}/android/app/.cxx" \
  "${app}/ios/Pods" \
  "${app}/ios/build" \
  "${E2E_DERIVED_DATA_DIR:-${HOME}/Library/Developer/Xcode/DerivedData/s3-build-cache-e2e}"

say "removed the caches and build outputs"
