#!/usr/bin/env bash
# Builds the sample app for Android (debug APK) as round ROUND of an end-to-end test:
#   build-android.sh ROUND
# The Gradle output goes to $E2E_LOG_DIR/gradle-round<ROUND>.log. The Gradle build cache is
# not requested on the command line: the restore step enables it in ~/.gradle/gradle.properties.
set -euo pipefail

round="${1:?usage: build-android.sh ROUND}"
log_dir="${E2E_LOG_DIR:?E2E_LOG_DIR is not set}"
app="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sample-app" && pwd)"
mkdir -p "${log_dir}"
npm_log="${log_dir}/npm-android-round${round}.log"
gradle_log="${log_dir}/gradle-round${round}.log"

say() { printf '[build-android] %s\n' "$*" >&2; }

# fail LOG MESSAGE: print the end of LOG and exit.
fail() {
  say "$2; last lines of $1:"
  tail -n 100 "$1" >&2
  exit 1
}

cd "${app}"
say "round ${round}: npm ci"
npm ci --no-audit --no-fund >"${npm_log}" 2>&1 || fail "${npm_log}" "npm ci failed"

cd "${app}/android"
say "round ${round}: ./gradlew assembleDebug (log: ${gradle_log})"
start="$(date +%s)"
./gradlew assembleDebug --console=plain >"${gradle_log}" 2>&1 || fail "${gradle_log}" "the Gradle build failed"
seconds=$(($(date +%s) - start))

grep -E 'actionable tasks?:' "${gradle_log}" >&2 || true
say "round ${round}: Gradle build took ${seconds} s"
