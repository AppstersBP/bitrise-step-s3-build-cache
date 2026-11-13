load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=ccache bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  export fallback_branch=main ccache_max_size=8G
  export BITRISE_GIT_BRANCH="feat/x"
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE CCACHE_DIR
  cfg_init
  storage_init 2>/dev/null
  OBJECT="cache/x/ccache-feat_x.tar.zst"
  # A real archive with a ccache entry, served by the aws stub.
  SEED="${TEST_TMP}/seed"
  mkdir -p "${SEED}/.ccache"
  echo entry >"${SEED}/.ccache/entry"
  archive_create "${TEST_TMP}/served.tar.zst" "${SEED}" .ccache 2>/dev/null
  # Not root, no sudo password: installation commands run directly.
  id() { echo 1000; }
  : >"${STUB_LOG}"
}
teardown() { teardown_env; }

# without_ccache: PATH with the stub commands but no ccache; an installation stub places it there.
without_ccache() {
  NOCC="${TEST_TMP}/nocc"
  mkdir -p "${NOCC}"
  local f
  for f in "${BATS_TEST_DIRNAME}"/../helpers/stubs/*; do
    [ "$(basename "${f}")" = ccache ] || ln -s "$(cd "$(dirname "${f}")" && pwd)/$(basename "${f}")" "${NOCC}/$(basename "${f}")"
  done
  local stubs="${BATS_TEST_DIRNAME}/../helpers/stubs" new="" dir
  stubs="$(cd "${stubs}" && pwd)"
  local IFS=:
  for dir in ${PATH}; do
    [ "${dir}" = "${stubs}" ] || new="${new:+${new}:}${dir}"
  done
  export PATH="${NOCC}:${new}"
  export STUB_INSTALL_CCACHE_TO="${NOCC}"
  ! command -v ccache >/dev/null
}

@test "installs ccache with apt-get on Linux when missing" {
  without_ccache
  export S3_CACHE_PLATFORM=Linux
  cache_ccache_restore 2>/dev/null
  assert_called "apt-get update -qq"
  assert_called "apt-get install -y -qq ccache"
  refute_called "brew"
  refute_called "sudo -n apt-get"
}

@test "installation uses sudo when not root and sudo needs no password" {
  without_ccache
  export S3_CACHE_PLATFORM=Linux STUB_SUDO_EXIT=0
  cache_ccache_restore 2>/dev/null
  assert_called "sudo -n apt-get install -y -qq ccache"
  assert_called "sudo -n apt-get update -qq"
}

@test "installation does not use sudo as root" {
  without_ccache
  id() { echo 0; }
  export S3_CACHE_PLATFORM=Linux STUB_SUDO_EXIT=0
  cache_ccache_restore 2>/dev/null
  assert_called "apt-get install -y -qq ccache"
  refute_called "sudo"
}

@test "installs ccache with brew on macOS when missing" {
  without_ccache
  export S3_CACHE_PLATFORM=Darwin
  cache_ccache_restore 2>/dev/null
  assert_called "brew install ccache"
  refute_called "apt-get"
}

@test "nothing is installed when ccache is present" {
  cache_ccache_restore 2>/dev/null
  refute_called "apt-get"
  refute_called "brew"
}

@test "install failure skips ccache and succeeds" {
  without_ccache
  export S3_CACHE_PLATFORM=Linux STUB_APT_GET_EXIT=100 STUB_APT_GET_OUT="E: Unable to locate package ccache"
  run cache_ccache_restore
  [ "$status" -eq 0 ]
  cache_ccache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_CCACHE}" = skipped ]
  grep -qF "Unable to locate package ccache" "${TEST_TMP}/err"
  refute_called "envman add --key CMAKE_C_COMPILER_LAUNCHER"
  refute_called "envman add --key CCACHE_DIR"
  refute_called "s3"
  [ ! -e "${HOME}/.ccache" ]
}

@test "install that does not provide ccache skips it" {
  without_ccache
  export S3_CACHE_PLATFORM=Darwin
  unset STUB_INSTALL_CCACHE_TO
  cache_ccache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_CCACHE}" = skipped ]
  refute_called "envman add --key CCACHE_DIR"
}

@test "exports launcher and ccache variables through envman" {
  cache_ccache_restore 2>/dev/null
  for v in "CMAKE_C_COMPILER_LAUNCHER --value ccache" "CMAKE_CXX_COMPILER_LAUNCHER --value ccache" "CCACHE_COMPILERCHECK --value content"; do
    assert_called "envman add --key $v"
  done
  assert_called "envman add --key CCACHE_DIR --value ${HOME}/.ccache"
  assert_called "envman add --key CCACHE_BASEDIR --value ${BITRISE_SOURCE_DIR}"
  [ "${CCACHE_DIR}" = "${HOME}/.ccache" ]
  [ "${CMAKE_C_COMPILER_LAUNCHER}" = ccache ]
  [ -d "${HOME}/.ccache" ]
}

@test "sets the maximum size and zeroes statistics after restoring" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_ccache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_CCACHE}" = exact ]
  [ -f "${HOME}/.ccache/entry" ]
  assert_called "ccache --max-size=8G"
  assert_called "ccache --zero-stats"
}

@test "maximum size and zeroed statistics also apply when nothing was restored" {
  export STUB_AWS_LIST_OUT=""
  cache_ccache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_CCACHE}" = none ]
  assert_called "ccache --max-size=8G"
  assert_called "ccache --zero-stats"
}

@test "maximum size and zeroed statistics also apply when the listing fails" {
  export STUB_AWS_LIST_EXIT=1
  cache_ccache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_CCACHE}" = none ]
  assert_called "ccache --max-size=8G"
  assert_called "ccache --zero-stats"
}

@test "ccache command failures are logged and not fatal" {
  export STUB_AWS_LIST_OUT="" STUB_CCACHE_EXIT=1
  run cache_ccache_restore
  [ "$status" -eq 0 ]
  cache_ccache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_CCACHE}" = none ]
  grep -qi "max-size" "${TEST_TMP}/err"
}

@test "restore order is branch, fallback branch, newest ccache- object" {
  export STUB_AWS_LIST_OUT=""
  cache_ccache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_CCACHE}" = none ]
  order="$(grep -oE 's3://b/cache/x/ccache-[A-Za-z_]+\.tar\.zst|--prefix cache/x/ccache-' "${STUB_LOG}")"
  expected=$'s3://b/cache/x/ccache-feat_x.tar.zst\ns3://b/cache/x/ccache-main.tar.zst\n--prefix cache/x/ccache-'
  [ "${order}" = "${expected}" ]
}

@test "restore from the fallback branch reports fallback" {
  storage_get() {
    case "$1" in *ccache-main.tar.zst) cp "${TEST_TMP}/served.tar.zst" "$2" ;; *) return 1 ;; esac
  }
  cache_ccache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_CCACHE}" = fallback ]
  [ -f "${HOME}/.ccache/entry" ]
  grep -qF "ccache-main.tar.zst" "${TEST_TMP}/err"
}

@test "restore from the newest object reports fallback" {
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/ccache-other.tar.zst'
  storage_get() {
    case "$1" in *ccache-other.tar.zst) cp "${TEST_TMP}/served.tar.zst" "$2" ;; *) return 1 ;; esac
  }
  cache_ccache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_CCACHE}" = fallback ]
  [ -f "${HOME}/.ccache/entry" ]
  assert_called "ccache --zero-stats"
}

@test "fallback branch equal to the current branch is not requested twice" {
  export fallback_branch="feat/x"
  cfg_init
  export STUB_AWS_LIST_OUT=""
  cache_ccache_restore 2>/dev/null
  [ "$(grep -c 's3://b/cache/x/ccache-feat_x.tar.zst' "${STUB_LOG}")" -eq 1 ]
}

@test "damaged archive is reported and removed" {
  echo "not an archive" >"${TEST_TMP}/bad.tar.zst"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad.tar.zst"
  export STUB_AWS_LIST_OUT=""
  cache_ccache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_CCACHE}" = none ]
  [ ! -e "${HOME}/.ccache/entry" ]
  grep -qi "damaged" "${TEST_TMP}/err"
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 's3-build-cache-ccache*' 2>/dev/null)" ]
  assert_called "ccache --max-size=8G"
}

@test "an unset branch is stored as unknown with a warning" {
  unset BITRISE_GIT_BRANCH
  export STUB_AWS_LIST_OUT=""
  cache_ccache_restore 2>"${TEST_TMP}/err"
  assert_called "ccache-unknown.tar.zst"
  grep -qi "branch" "${TEST_TMP}/err"
}

@test "save prints statistics then uploads under the branch" {
  mkdir -p "${HOME}/.ccache"
  echo e >"${HOME}/.ccache/entry"
  export STUB_CCACHE_OUT="cache hit rate 42 %"
  storage_put() {
    echo "put $2" >>"${STUB_LOG}"
    cp "$1" "${TEST_TMP}/uploaded.tar.zst"
  }
  cache_ccache_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_CCACHE}" = uploaded ]
  assert_called "ccache --show-stats"
  assert_called "put ${OBJECT}"
  [ "$(grep -n 'ccache --show-stats' "${STUB_LOG}" | head -1 | cut -d: -f1)" -lt "$(grep -n "put ${OBJECT}" "${STUB_LOG}" | head -1 | cut -d: -f1)" ]
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "^\.ccache/entry"
  grep -qF "cache hit rate 42 %" "${TEST_TMP}/err"
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
}

@test "save uploads even after an exact restore" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_ccache_restore 2>/dev/null
  : >"${STUB_LOG}"
  cache_ccache_save 2>/dev/null
  [ "${S3_CACHE_SAVE_CCACHE}" = uploaded ]
  assert_called "s3://b/${OBJECT}"
  refute_called "copy-object"
}

@test "save reports failed when the upload fails" {
  mkdir -p "${HOME}/.ccache"
  export STUB_AWS_PUT_EXIT=1
  run cache_ccache_save
  [ "$status" -eq 0 ]
  cache_ccache_save 2>/dev/null
  [ "${S3_CACHE_SAVE_CCACHE}" = failed ]
}

@test "save with missing directory skips" {
  cache_ccache_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_CCACHE}" = skipped ]
  grep -qi "nothing to save" "${TEST_TMP}/err"
  refute_called "aws"
}

@test "save without ccache installed skips" {
  without_ccache
  mkdir -p "${HOME}/.ccache"
  cache_ccache_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_CCACHE}" = skipped ]
  grep -qF "ccache is not installed" "${TEST_TMP}/err"
  refute_called "aws"
}
