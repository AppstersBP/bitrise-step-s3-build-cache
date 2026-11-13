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
# Extracts into a temporary directory inside BASE_DIR (same filesystem), then
# moves the top-level entries into BASE_DIR, replacing entries of the same
# name. A failed extraction leaves BASE_DIR unchanged. Creates BASE_DIR.
archive_extract() {
  local in="$1" base="$2"
  mkdir -p "${base}" || {
    log_error "archive_extract: cannot create ${base}"
    return 1
  }
  local tmp
  if ! tmp="$(mktemp -d "${base}/.s3cache-extract.XXXXXX")"; then
    log_error "archive_extract: cannot create a temporary directory in ${base}"
    return 1
  fi
  if ! tar --zstd -xf "${in}" -C "${tmp}"; then
    rm -rf "${tmp}"
    log_error "archive_extract: could not extract ${in}"
    return 1
  fi
  local entry name
  for entry in "${tmp}"/* "${tmp}"/.[!.]* "${tmp}"/..?*; do
    [ -e "${entry}" ] || [ -L "${entry}" ] || continue
    name="${entry##*/}"
    if ! { rm -rf "${base:?}/${name}" && mv "${entry}" "${base}/${name}"; }; then
      rm -rf "${tmp}"
      log_error "archive_extract: could not move ${name} into ${base}"
      return 1
    fi
  done
  rm -rf "${tmp}"
  return 0
}
