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

@test "failed create leaves no output file" {
  mkdir h
  run archive_create out.tar.zst h does-not-exist
  [ "$status" -ne 0 ]
  [ ! -e out.tar.zst ]
  [ -z "$(ls -A . | grep -F out.tar.zst || true)" ]
}

@test "extract merges into a BASE that already has other files" {
  mkdir -p h/.gradle/caches/modules-2 h2/.gradle
  printf 'org.gradle.jvmargs=-Xmx2g\n' >h2/.gradle/gradle.properties
  archive_create out.tar.zst h .gradle/caches
  archive_extract out.tar.zst h2
  [ -d h2/.gradle/caches/modules-2 ]
  [ "$(cat h2/.gradle/gradle.properties)" = "org.gradle.jvmargs=-Xmx2g" ]
}

@test "two archives with sibling paths under .gradle both end up present" {
  mkdir -p h/.gradle/caches/modules-2 h/.gradle/build-cache
  archive_create deps.tar.zst h .gradle/caches
  archive_create bc.tar.zst h .gradle/build-cache
  archive_extract deps.tar.zst t
  archive_extract bc.tar.zst t
  [ -d t/.gradle/caches/modules-2 ]
  [ -d t/.gradle/build-cache ]
}

@test "damaged archive returns 1 and leaves BASE exactly as before" {
  mkdir -p h4/keep/sub
  printf x >h4/keep/sub/f
  printf garbage >bad.tar.zst
  find h4 | sort >before.txt
  run archive_extract bad.tar.zst h4
  [ "$status" -eq 1 ]
  find h4 | sort >after.txt
  cmp before.txt after.txt
  run archive_extract bad.tar.zst missing-base
  [ "$status" -eq 1 ]
  [ ! -e missing-base ]
}
