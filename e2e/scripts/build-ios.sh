#!/usr/bin/env bash
# Builds the sample app for the iOS simulator (debug, unsigned) as round ROUND of an
# end-to-end test:
#   build-ios.sh ROUND
# Logs go to $E2E_LOG_DIR (pod-install-round<ROUND>.log, xcodebuild-round<ROUND>.log).
# DerivedData goes to $E2E_DERIVED_DATA_DIR (default below; clean-local.sh removes it). It is
# kept outside the repository, which Bitrise copies for every run of the step from path::./.
set -euo pipefail

round="${1:?usage: build-ios.sh ROUND}"
log_dir="${E2E_LOG_DIR:?E2E_LOG_DIR is not set}"
app="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sample-app" && pwd)"
scheme=sampleapp
derived_data="${E2E_DERIVED_DATA_DIR:-${HOME}/Library/Developer/Xcode/DerivedData/s3-build-cache-e2e}"
mkdir -p "${log_dir}"
npm_log="${log_dir}/npm-ios-round${round}.log"
pod_log="${log_dir}/pod-install-round${round}.log"
xcode_log="${log_dir}/xcodebuild-round${round}.log"

say() { printf '[build-ios] %s\n' "$*" >&2; }

# fail LOG MESSAGE: print the end of LOG and exit.
fail() {
  say "$2; last lines of $1:"
  tail -n 100 "$1" >&2
  exit 1
}

cd "${app}"
say "round ${round}: npm ci"
npm ci --no-audit --no-fund >"${npm_log}" 2>&1 || fail "${npm_log}" "npm ci failed"

cd "${app}/ios"
say "round ${round}: pod install (log: ${pod_log})"
start="$(date +%s)"
pod install >"${pod_log}" 2>&1 || fail "${pod_log}" "pod install failed"
say "round ${round}: pod install took $(($(date +%s) - start)) s"

say "round ${round}: xcodebuild (log: ${xcode_log})"
start="$(date +%s)"
xcodebuild \
  -workspace "${scheme}.xcworkspace" \
  -scheme "${scheme}" \
  -sdk iphonesimulator \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${derived_data}" \
  ARCHS="$(uname -m)" \
  CODE_SIGNING_ALLOWED=NO \
  build >"${xcode_log}" 2>&1 || fail "${xcode_log}" "xcodebuild failed"
say "round ${round}: xcodebuild took $(($(date +%s) - start)) s"
