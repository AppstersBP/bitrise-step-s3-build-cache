load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=ccache bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  export fallback_branch=main
  export BITRISE_GIT_BRANCH="feat/x"
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  cfg_init
  storage_init 2>/dev/null
  SEED="${TEST_TMP}/seed"
  mkdir -p "${SEED}/data"
  echo entry >"${SEED}/data/entry"
  archive_create "${TEST_TMP}/served.tar.zst" "${SEED}" data 2>/dev/null
  DEST="${TEST_TMP}/dest"
  mkdir -p "${DEST}"
  : >"${STUB_LOG}"
}
teardown() { teardown_env; }

# Record every key the chain tries to download; the keys in FETCH_OK succeed.
stub_storage_get() {
  FETCHED="${TEST_TMP}/fetched"
  : >"${FETCHED}"
  storage_get() {
    echo "$1" >>"${FETCHED}"
    case " ${FETCH_OK:-} " in
      *" $1 "*) cp "${TEST_TMP}/served.tar.zst" "$2" ;;
      *) return 1 ;;
    esac
  }
}

@test "cache_branch sanitises the current branch" {
  [ "$(cache_branch 2>/dev/null)" = "feat_x" ]
}

@test "cache_branch falls back to unknown with a warning" {
  unset BITRISE_GIT_BRANCH
  [ "$(cache_branch 2>/dev/null)" = "unknown" ]
  cache_branch 2>"${TEST_TMP}/err" >/dev/null
  grep -qF "unknown" "${TEST_TMP}/err"
}

@test "cache_archive_size prints the size in bytes" {
  printf 'abcde' >"${TEST_TMP}/five"
  [ "$(cache_archive_size "${TEST_TMP}/five")" = 5 ]
}

@test "cache_fetch returns 0 and extracts a good archive" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_fetch t cache/x/a.tar.zst "${DEST}" 2>"${TEST_TMP}/err"
  [ -f "${DEST}/data/entry" ]
  grep -qF "restored cache/x/a.tar.zst" "${TEST_TMP}/err"
}

@test "cache_fetch returns 1 for a damaged archive" {
  echo "not an archive" >"${TEST_TMP}/bad"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad"
  run cache_fetch t cache/x/a.tar.zst "${DEST}"
  [ "$status" -eq 1 ]
}

@test "cache_fetch returns 2 when the download fails" {
  run cache_fetch t cache/x/a.tar.zst "${DEST}"
  [ "$status" -eq 2 ]
}

@test "cache_fetch removes its temporary file" {
  export TMPDIR="${TEST_TMP}/tmp"
  mkdir -p "${TMPDIR}"
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_fetch t cache/x/a.tar.zst "${DEST}" 2>/dev/null
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "cache_fetch leaves nothing in TMPDIR after a damaged archive" {
  export TMPDIR="${TEST_TMP}/tmp"
  mkdir -p "${TMPDIR}"
  echo "not an archive" >"${TEST_TMP}/bad"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad"
  run cache_fetch t cache/x/a.tar.zst "${DEST}"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "chain: current branch object gives exact" {
  stub_storage_get
  FETCH_OK="cache/x/p-feat_x.tar.zst"
  local out
  out="$(cache_restore_chain t p- "${DEST}" 2>/dev/null)"
  [ -z "${out}" ]
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = exact ]
  [ -f "${DEST}/data/entry" ]
  refute_called list-objects
}

@test "chain: fallback branch object gives fallback" {
  stub_storage_get
  FETCH_OK="cache/x/p-main.tar.zst"
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = fallback ]
  [ "$(cat "${FETCHED}")" = $'cache/x/p-feat_x.tar.zst\ncache/x/p-main.tar.zst' ]
}

@test "chain: fallback branch equal to the current branch is tried once" {
  export BITRISE_GIT_BRANCH=main
  stub_storage_get
  export STUB_AWS_LIST_OUT=""
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "$(cat "${FETCHED}")" = "cache/x/p-main.tar.zst" ]
  [ "${S3_CACHE_RESULT_T}" = none ]
}

@test "chain: newest object is used after both branches miss" {
  stub_storage_get
  FETCH_OK="cache/x/p-old.tar.zst"
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/p-old.tar.zst'
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = fallback ]
  assert_called "--prefix cache/x/p-"
}

@test "chain: newest key equal to an already-tried key is not downloaded again" {
  stub_storage_get
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/p-main.tar.zst'
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = none ]
  [ "$(grep -c 'p-main' "${FETCHED}")" -eq 1 ]
  [ "$(grep -c 'p-feat_x' "${FETCHED}")" -eq 1 ]
}

@test "chain: damaged current archive continues to the fallback branch" {
  stub_storage_get
  FETCH_OK="cache/x/p-feat_x.tar.zst cache/x/p-main.tar.zst"
  # The current branch archive downloads but is damaged; the fallback one is good.
  storage_get() {
    echo "$1" >>"${FETCHED}"
    case "$1" in
      cache/x/p-feat_x.tar.zst) echo "not an archive" >"$2" ;;
      cache/x/p-main.tar.zst) cp "${TEST_TMP}/served.tar.zst" "$2" ;;
      *) return 1 ;;
    esac
  }
  cache_restore_chain t p- "${DEST}" 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_T}" = fallback ]
  grep -qi "damaged" "${TEST_TMP}/err"
  [ -f "${DEST}/data/entry" ]
}

@test "chain: nothing stored gives none" {
  stub_storage_get
  export STUB_AWS_LIST_OUT=""
  run cache_restore_chain t p- "${DEST}"
  [ "$status" -eq 0 ]
  cache_restore_chain t p- "${DEST}" 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_T}" = none ]
  grep -qF "no cache found" "${TEST_TMP}/err"
}

@test "chain: a failing listing gives none" {
  stub_storage_get
  export STUB_AWS_LIST_EXIT=1
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = none ]
}

@test "chain: a newest archive that cannot be restored gives none" {
  stub_storage_get
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/p-old.tar.zst'
  cache_restore_chain t p- "${DEST}" 2>/dev/null
  [ "${S3_CACHE_RESULT_T}" = none ]
}
