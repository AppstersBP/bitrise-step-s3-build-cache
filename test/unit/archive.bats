load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  cd "${TEST_TMP}"
}
teardown() { teardown_env; }

@test "archive round trip keeps relative paths and honours excludes" {
  mkdir -p h/.gradle/caches/modules-2 h/.gradle/caches/build-cache-1 h/.gradle/wrapper
  archive_create out.tar.zst h .gradle/caches .gradle/wrapper -- .gradle/caches/build-cache-1
  archive_extract out.tar.zst h2
  [ -d h2/.gradle/caches/modules-2 ]
  [ ! -e h2/.gradle/caches/build-cache-1 ]
}

@test "extracting a today-style archive works" {
  mkdir -p h/.gradle/wrapper
  tar --zstd -cf a.tar.zst -C h .gradle/wrapper
  archive_extract a.tar.zst h3
  [ -d h3/.gradle/wrapper ]
}

@test "archives are created in the format of existing installations" {
  mkdir -p h/.gradle/wrapper
  archive_create out.tar.zst h .gradle/wrapper
  mkdir plain
  tar --zstd -xf out.tar.zst -C plain
  [ -d plain/.gradle/wrapper ]
}

@test "damaged archive fails and leaves no partial output" {
  printf garbage >bad.tar.zst
  mkdir h4
  run archive_extract bad.tar.zst h4
  [ "$status" -ne 0 ]
  [ -z "$(ls -A h4)" ]
}

@test "failed create leaves no output file" {
  mkdir h
  run archive_create out.tar.zst h does-not-exist
  [ "$status" -ne 0 ]
  [ ! -e out.tar.zst ]
  [ -z "$(ls -A . | grep -F out.tar.zst || true)" ]
}

@test "extract replaces existing top-level entries and keeps others" {
  mkdir -p h/.gradle/wrapper h2/.gradle/old h2/other
  archive_create out.tar.zst h .gradle/wrapper
  archive_extract out.tar.zst h2
  [ -d h2/.gradle/wrapper ]
  [ ! -e h2/.gradle/old ]
  [ -d h2/other ]
  [ -z "$(ls -A h2 | grep -F s3cache || true)" ]
  [ -z "$(ls -A h2 | grep -F .s3cache || true)" ]
}

@test "failed extract keeps existing content" {
  mkdir -p h4/keep
  printf garbage >bad.tar.zst
  run archive_extract bad.tar.zst h4
  [ "$status" -ne 0 ]
  [ -d h4/keep ]
  [ "$(ls -A h4)" = keep ]
}
