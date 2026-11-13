#!/usr/bin/env bash
# tar + zstd archives, in the format used by existing installations:
#   tar --zstd -cf OUT -C BASE PATH...    tar --zstd -xf IN -C BASE
# Works with GNU tar (Linux) and bsdtar (macOS).

# archive_create OUT_FILE BASE_DIR PATH... [-- EXCLUDE...]
# Writes to a temporary file next to OUT_FILE and renames it on success, so a
# failed run never leaves a partial OUT_FILE.
archive_create() {
  local out="$1" base="$2"
  shift 2
  local -a paths=() excludes=()
  local in_excludes=0 arg
  for arg in "$@"; do
    if [ "${in_excludes}" = 1 ]; then
      excludes+=("--exclude=${arg}")
    elif [ "${arg}" = "--" ]; then
      in_excludes=1
    else
      paths+=("${arg}")
    fi
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    log_error "archive_create: no paths given"
    return 1
  fi

  local tmp
  if ! tmp="$(mktemp "${out}.XXXXXX")"; then
    log_error "archive_create: cannot create a temporary file next to ${out}"
    return 1
  fi
  if tar --zstd -cf "${tmp}" ${excludes[@]+"${excludes[@]}"} -C "${base}" "${paths[@]}" &&
    mv -f "${tmp}" "${out}"; then
    return 0
  fi
  rm -f "${tmp}"
  log_error "archive_create: could not create ${out}"
  return 1
}

# archive_extract IN_FILE BASE_DIR
# Verifies the whole archive first (full read and decompression); a damaged
# archive fails before BASE_DIR is touched. Then extracts in place, merging
# into BASE_DIR like `tar --zstd -xf IN -C BASE` (nothing else is removed).
# Creates BASE_DIR. If the extraction itself fails, what was extracted stays.
archive_extract() {
  local in="$1" base="$2"
  if ! tar --zstd -tf "${in}" >/dev/null; then
    log_error "archive_extract: ${in} is damaged or unreadable"
    return 1
  fi
  mkdir -p "${base}" || {
    log_error "archive_extract: cannot create ${base}"
    return 1
  }
  if ! tar --zstd -xf "${in}" -C "${base}"; then
    log_error "archive_extract: extraction of ${in} into ${base} failed"
    return 1
  fi
  return 0
}
