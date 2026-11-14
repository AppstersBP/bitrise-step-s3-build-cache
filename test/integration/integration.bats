#!/usr/bin/env bats
# Integration tests: the real step, the real AWS CLI and a real MinIO.
# MinIO is started once per file by e2e/scripts/start-minio.sh and stopped afterwards.

load ../helpers/common

REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup_file() {
  export S3_CACHE_MINIO_STATE="${BATS_FILE_TMPDIR}/minio.state"
  local exports
  exports="$("${REPO_DIR}/e2e/scripts/start-minio.sh")" || return 1
  eval "${exports}"
}

teardown_file() {
  "${REPO_DIR}/e2e/scripts/stop-minio.sh" || true
}

setup() {
  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/s3cache-int.XXXXXX")"
  export TEST_TMP
  export HOME="${TEST_TMP}/home"
  export BITRISE_SOURCE_DIR="${TEST_TMP}/src"
  export STUB_LOG="${TEST_TMP}/stub.log"
  # Never touch the real home directory.
  case "${HOME}" in
    "${BATS_TMPDIR:-/tmp}"/s3cache-int.*/home) ;;
    *) echo "HOME is not a temporary directory: ${HOME}" >&2; return 1 ;;
  esac
  mkdir -p "${HOME}" "${BITRISE_SOURCE_DIR}" "${TEST_TMP}/bin"
  : >"${STUB_LOG}"
  # Only envman is stubbed (it records the step outputs); aws is the real one.
  cp "${REPO_DIR}/test/helpers/stubs/envman" "${TEST_TMP}/bin/envman"
  export PATH="${TEST_TMP}/bin:${PATH}"

  # Direct AWS CLI access for the checks of the tests.
  export AWS_ACCESS_KEY_ID="${S3_CACHE_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${S3_CACHE_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION=us-east-1
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

  # Step inputs. Every test uses its own prefix.
  export mode=restore
  export caches=gradle-deps
  export endpoint="${S3_CACHE_ENDPOINT}"
  export bucket="${S3_CACHE_BUCKET}"
  export prefix="it-${BATS_TEST_NUMBER}-$$-${RANDOM}"
  export access_key_id="${S3_CACHE_ACCESS_KEY_ID}"
  export secret_access_key="${S3_CACHE_SECRET_ACCESS_KEY}"
  export gradle_key_files="android/build.gradle"
  unset BITRISE_PULL_REQUEST BITRISE_GIT_BRANCH

  mkdir -p "${BITRISE_SOURCE_DIR}/android"
  printf 'plugins {}\nversionCode 1\nversionName "1.0"\ndependencies { a }\n' >"${BITRISE_SOURCE_DIR}/android/build.gradle"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "${TEST_TMP}"
  return 0
}

s3() {
  aws --endpoint-url "${S3_CACHE_ENDPOINT}" "$@"
}

run_step() {
  run bash "${REPO_DIR}/step.sh"
}

# Key of the Gradle archive for the current build files, computed like the existing Script steps did.
legacy_gradle_name() {
  local sum
  sum="$(cd "${BITRISE_SOURCE_DIR}" && cat android/build.gradle | grep -v -E '^\s*(versionCode|versionName)\b' | sha256sum | cut -d' ' -f1)"
  printf 'gradle-%s.tar.zst' "${sum}"
}

dir_checksum() {
  (cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
}

@test "round trip with a 200 MB archive uses multipart and restores identical files" {
  mkdir -p "${HOME}/.gradle/caches/modules-2" "${HOME}/.gradle/wrapper/dists"
  head -c $((200 * 1024 * 1024)) /dev/urandom >"${HOME}/.gradle/caches/modules-2/big.bin"
  echo "wrapper" >"${HOME}/.gradle/wrapper/dists/file.txt"
  before="$(dir_checksum "${HOME}/.gradle")"

  mode=save run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_SAVE_GRADLE_DEPS --value uploaded"

  key="$(s3 s3api list-objects-v2 --bucket "${bucket}" --prefix "${prefix}/" --query 'Contents[0].Key' --output text)"
  [[ "${key}" == "${prefix}/gradle-"*.tar.zst ]]
  etag="$(s3 s3api head-object --bucket "${bucket}" --key "${key}" --query ETag --output text)"
  echo "ETag: ${etag}" >&2
  [[ "${etag}" =~ -[0-9]+ ]]

  rm -rf "${HOME}/.gradle"
  : >"${STUB_LOG}"
  mode=restore run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value exact"
  [ "$(dir_checksum "${HOME}/.gradle")" = "${before}" ]
}

@test "fallback listing on empty and non-empty prefixes" {
  run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value none"
  # A miss is expected and must not show the AWS CLI's 404 error.
  [[ "${output}" != *"fatal error"* ]]
  [[ "${output}" == *"no cache found"* ]]

  # An archive of another build under the same prefix is used as a fallback.
  mkdir -p "${TEST_TMP}/other/.gradle/caches"
  echo "old" >"${TEST_TMP}/other/.gradle/caches/old.txt"
  tar --zstd -cf "${TEST_TMP}/other.tar.zst" -C "${TEST_TMP}/other" .gradle/caches
  s3 s3 cp --only-show-errors "${TEST_TMP}/other.tar.zst" "s3://${bucket}/${prefix}/gradle-0000.tar.zst"

  : >"${STUB_LOG}"
  run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value fallback"
  [ "$(cat "${HOME}/.gradle/caches/old.txt")" = old ]
}

@test "two prefixes in one bucket do not see each other" {
  mkdir -p "${HOME}/.gradle/caches"
  echo "a" >"${HOME}/.gradle/caches/a.txt"
  prefix_a="${prefix}-a"
  prefix_b="${prefix}-b"

  prefix="${prefix_a}" mode=save run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_SAVE_GRADLE_DEPS --value uploaded"

  rm -rf "${HOME}/.gradle"
  : >"${STUB_LOG}"
  prefix="${prefix_b}" run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value none"
  [ ! -e "${HOME}/.gradle/caches/a.txt" ]

  : >"${STUB_LOG}"
  prefix="${prefix_a}" run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value exact"
  [ "$(cat "${HOME}/.gradle/caches/a.txt")" = a ]
}

@test "copy-object onto itself renews LastModified and keeps the content" {
  head -c 100000 /dev/urandom >"${TEST_TMP}/obj.bin"
  key="${prefix}/touch-test.bin"
  s3 s3 cp --only-show-errors "${TEST_TMP}/obj.bin" "s3://${bucket}/${key}"
  t1="$(s3 s3api head-object --bucket "${bucket}" --key "${key}" --query LastModified --output text)"
  sleep 2

  run bash -c 'S3_CACHE_NO_MAIN=1 source "$1/step.sh"; cfg_init; storage_init 2>/dev/null; storage_touch "$2"' _ "${REPO_DIR}" "${key}"
  [ "${status}" -eq 0 ]

  t2="$(s3 s3api head-object --bucket "${bucket}" --key "${key}" --query LastModified --output text)"
  echo "LastModified before: ${t1} after: ${t2}" >&2
  [[ "${t2}" > "${t1}" ]]
  s3 s3 cp --only-show-errors "s3://${bucket}/${key}" "${TEST_TMP}/obj.after"
  cmp "${TEST_TMP}/obj.bin" "${TEST_TMP}/obj.after"
}

@test "unreachable endpoint fails fast" {
  endpoint="http://10.255.255.1:9000"
  start=${SECONDS}
  run_step
  elapsed=$((SECONDS - start))
  echo "elapsed: ${elapsed} s" >&2
  [ "${status}" -eq 0 ]
  [ "${elapsed}" -le 15 ]
  [[ "${output}" == *"S3 storage is unreachable at http://10.255.255.1:9000"* ]]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value skipped"
}

@test "today's Gradle archive layout restores" {
  mkdir -p "${HOME}/.gradle/caches/modules-2" "${HOME}/.gradle/wrapper/dists"
  echo "dep" >"${HOME}/.gradle/caches/modules-2/dep.txt"
  echo "wrapper" >"${HOME}/.gradle/wrapper/dists/w.txt"
  tar --zstd -cf "${TEST_TMP}/gradle.tar.zst" -C "${HOME}" .gradle/caches .gradle/wrapper
  s3 s3 cp --only-show-errors "${TEST_TMP}/gradle.tar.zst" "s3://${bucket}/${prefix}/$(legacy_gradle_name)"
  rm -rf "${HOME}/.gradle"

  run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_GRADLE_DEPS --value exact"
  [ "$(cat "${HOME}/.gradle/caches/modules-2/dep.txt")" = dep ]
  [ "$(cat "${HOME}/.gradle/wrapper/dists/w.txt")" = wrapper ]
}

@test "today's CocoaPods archive layout restores" {
  mkdir -p "${BITRISE_SOURCE_DIR}/ios/Pods/Target"
  printf 'PODS:\n  - A (1.0)\n' >"${BITRISE_SOURCE_DIR}/ios/Podfile.lock"
  echo "pod" >"${BITRISE_SOURCE_DIR}/ios/Pods/Target/a.txt"
  sum="$(sha256sum "${BITRISE_SOURCE_DIR}/ios/Podfile.lock" | cut -d' ' -f1)"
  tar --zstd -cf "${TEST_TMP}/pods.tar.zst" -C "${BITRISE_SOURCE_DIR}" ios/Pods
  s3 s3 cp --only-show-errors "${TEST_TMP}/pods.tar.zst" "s3://${bucket}/${prefix}/pods-${sum}.tar.zst"
  rm -rf "${BITRISE_SOURCE_DIR}/ios/Pods"

  caches=cocoapods run_step
  [ "${status}" -eq 0 ]
  assert_called "--key S3_CACHE_RESULT_COCOAPODS --value exact"
  [ "$(cat "${BITRISE_SOURCE_DIR}/ios/Pods/Target/a.txt")" = pod ]
}
