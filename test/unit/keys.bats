load ../helpers/common

# Reference SHA-256 of stdin (sha256sum on Linux, shasum on macOS).
sha256_ref() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  cd "${TEST_TMP}"
  printf 'a\n    versionCode 1\n    versionName "1.0"\n' >f1
  printf 'a\n    versionCode 2\n    versionName "2.0"\n' >f2
  printf 'b\n    versionCode 3\nc\n' >f3
}
teardown() { teardown_env; }

@test "branch names are sanitised" {
  [ "$(key_branch 'feat/MNMC-10534-mobil-smarttv')" = "feat_MNMC-10534-mobil-smarttv" ]
  # byte-wise: u-umlaut is two bytes, plus the space, gives three underscores
  [ "$(key_branch 'release/1.2 ü')" = "release_1.2___" ]
}

@test "branch sanitising equals the byte-wise formula of existing installations" {
  for b in 'a/b' 'x y' 'ünï' 'feat/ä#1' 'plain-1.0_x'; do
    expected=$(printf %s "$b" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
    [ "$(key_branch "$b")" = "$expected" ]
  done
}

@test "version lines do not change the hash" {
  h1=$(key_hash_files '^\s*(versionCode|versionName)\b' f1)
  h2=$(key_hash_files '^\s*(versionCode|versionName)\b' f2)
  [[ "$h1" =~ ^[0-9a-f]{64}$ ]]
  [ "$h1" = "$h2" ]
  [ "$h1" != "$(key_hash_files 'zzz' f1)" ]
}

@test "hash matches the existing key formula" {
  expected=$(cat f1 f3 | grep -v -E '^\s*(versionCode|versionName)\b' | sha256_ref | cut -d' ' -f1)
  [ "$(key_hash_files '^\s*(versionCode|versionName)\b' f1 f3)" = "$expected" ]
}

@test "files are concatenated in the order given" {
  [ "$(key_hash_files 'zzz' f1 f3)" = "$(cat f1 f3 | sha256_ref | cut -d' ' -f1)" ]
  [ "$(key_hash_files 'zzz' f3 f1)" = "$(cat f3 f1 | sha256_ref | cut -d' ' -f1)" ]
  [ "$(key_hash_files 'zzz' f1 f3)" != "$(key_hash_files 'zzz' f3 f1)" ]
}

@test "missing files are skipped with a warning; no files at all fails" {
  run key_hash_files 'zzz' f1 nope
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"nope"* ]]
  expected=$(cat f1 | grep -v -E 'zzz' | sha256_ref | cut -d' ' -f1)
  [ "$(key_hash_files 'zzz' f1 nope 2>/dev/null)" = "$expected" ]

  run key_hash_files 'zzz' nope1 nope2
  [ "$status" -eq 1 ]
}

@test "works when every line is ignored (grep exits 1)" {
  set -o pipefail
  run key_hash_files '.' f1
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '' | sha256_ref | cut -d' ' -f1)" ]
}

@test "an invalid ignore pattern fails instead of hashing empty input" {
  run key_hash_files '[' f1
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid ignore pattern"* ]]
  [[ ! "$output" =~ [0-9a-f]{64} ]]
}

@test "an unreadable file fails instead of hashing partial input" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  chmod 000 f3
  run key_hash_files 'zzz' f1 f3
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "falls back to shasum -a 256 when sha256sum is unavailable" {
  command -v sha256sum >/dev/null 2>&1 || skip "sha256sum is not installed here (the fallback is the normal path)"
  expected=$(cat f1 | grep -v -E 'zzz' | sha256_ref | cut -d' ' -f1)
  # a PATH with the basic tools and a shasum that only accepts "-a 256", but no sha256sum
  mkdir "${TEST_TMP}/bin"
  for t in cat grep cut tr sed awk mktemp rm; do ln -s "$(command -v "$t")" "${TEST_TMP}/bin/$t"; done
  printf '#!/bin/sh\n[ "$1 $2" = "-a 256" ] || exit 9\nshift 2\nexec %s "$@"\n' "$(command -v sha256sum)" >"${TEST_TMP}/bin/shasum"
  chmod +x "${TEST_TMP}/bin/shasum"
  saved_path="${PATH}"
  PATH="${TEST_TMP}/bin"
  ! command -v sha256sum
  run key_hash_files 'zzz' f1
  PATH="${saved_path}"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "key_hash_file hashes the exact bytes, including a missing final newline" {
  printf 'x\r\n\n# c\nlast' >raw
  [ "$(key_hash_file raw)" = "$(shasum -a 256 raw | cut -d' ' -f1)" ]
}

@test "key_hash_file fails for a missing file" {
  run key_hash_file nothere
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
