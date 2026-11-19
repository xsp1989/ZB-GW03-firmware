#!/usr/bin/env bash
#
# Build one PlatformIO environment.
#
#   usage: build-env.sh <environment> [log file]
#
# Two failure modes are handled without pinning any version:
#
#   * transient download errors from GitHub/PyPI are retried after a delay
#   * a PlatformIO Core that the platform itself rejects. The ESP32 platform
#     provisions its own Core in <core_dir>/penv and installs
#     "pioarduino>=<engine>" there, so pip/uv resolves the spec to the newest
#     post release (6.2.0.post1). PlatformIO ranks a post release *below* the
#     plain release it is derived from, so a platform requiring ">=6.2.0"
#     refuses to load it ("IncompatiblePlatform").
#
#     PlatformIO spells that same version in two ways, and both have to be
#     understood:
#       pio --version            -> "PlatformIO Core, version 6.2.0.post1"
#       the error message        -> "... PlatformIO Core v6.2.0-post.1 ..."
#     Only the dash form was recognised before, so the repair never ran for the
#     form pip/uv actually installs.
#
#     The version the platform requires is read from the installed platform
#     manifest before the build and from the error message as a fallback, so
#     nothing has to be pinned or updated here when Tasmota moves to a newer
#     platform and Core.

set -uo pipefail

ENV="${1:?usage: build-env.sh <environment> [log file]}"
LOG="${2:-${RUNNER_TEMP:-/tmp}/pio-${ENV}.log}"
CORE_DIR="${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}"
PLATFORM_MANIFEST="${CORE_DIR}/platforms/espressif32/platform.json"

# ---------------------------------------------------------------------------
# versions
# ---------------------------------------------------------------------------

version_ge() {
  [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

version_gt() {
  [ "$1" != "$2" ] && version_ge "$1" "$2"
}

# "PlatformIO Core, version 6.2.0.post1" -> "6.2.0.post1"
core_version() {
  printf '%s\n' "$1" \
    | sed -nE 's/^.*[Vv]ersion v?([0-9]+(\.[0-9]+)*([._-]?[A-Za-z][0-9A-Za-z._-]*)?).*$/\1/p' \
    | tail -n1
}

# "6.2.0.post1" / "6.2.0-post.1" / "6.2.0rc1" -> "6.2.0"
version_release() {
  local release="${1%%[!0-9.]*}"
  printf '%s\n' "${release%.}"
}

# True (0) when a Core version cannot satisfy the required release.
#
# A post/dev/pre release sorts below the plain release it is derived from, e.g.
# 6.2.0-post.1 < 6.2.0, which is exactly what PlatformIO's semantic-version
# check does. So "6.2.0.post1" fails ">=6.2.0" while "6.2.1.post1" passes it.
core_is_rejected() {
  local ver="${1#v}" release suffix

  [ -n "${ver}" ] || return 0
  release="$(version_release "${ver}")"
  [ -n "${release}" ] || return 0

  suffix="${ver#"${release}"}"
  suffix="${suffix#[._-]}"

  if [ -n "${suffix}" ]; then
    version_gt "${release}" "$2" && return 1
    return 0
  fi
  version_ge "${release}" "$2" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Core repair
# ---------------------------------------------------------------------------

needs_repair() {
  local out ver
  out="$("$1" --version 2>&1)" || return 1
  ver="$(core_version "${out}")"
  core_is_rejected "${ver}" "$2"
}

# installs the required Core release into the environment that owns <pio>
repair_env() {
  local bin dir dist
  bin="$1"
  dir="$(cd "$(dirname "${bin}")" && pwd)" || return 1
  [ -x "${dir}/python" ] || return 1

  dist="$("${dir}/python" - <<'PY'
import importlib.metadata as md

names = {(d.metadata['Name'] or '').lower() for d in md.distributions()}
print('pioarduino' if 'pioarduino' in names else 'platformio')
PY
)" || return 1

  # the plain release, never a post release: "6.2.0" satisfies ">=6.2.0",
  # "6.2.0.post1" does not
  echo "::warning::Installing ${dist}==${2} into ${dir}"
  if [ -x "${dir}/uv" ]; then
    "${dir}/uv" pip install -p "${dir}/python" "${dist}==${2}" || return 1
  else
    "${dir}/python" -m pip install "${dist}==${2}" || return 1
  fi
  "${dir}/pio" --version
}

# The Core version the installed platform requires, e.g. "6.2.0" out of
# {"engines": {"platformio": ">=6.2.0-0"}}. Empty when the platform is not
# installed yet, which is the case on a cold cache.
platform_requirement() {
  local required
  [ -f "${PLATFORM_MANIFEST}" ] || return 1
  required="$(sed -nE \
    's/.*"platformio"[[:space:]]*:[[:space:]]*">=?[[:space:]]*v?([0-9]+(\.[0-9]+)*).*/\1/p' \
    "${PLATFORM_MANIFEST}" | head -n1)"
  [ -n "${required}" ] || return 1
  printf '%s\n' "${required}"
}

# repairs every Core that runs the build: the one on PATH and the one the
# platform provisions in <core_dir>/penv
repair_cores() {
  local required="$1" pio_bin repaired=1

  for pio_bin in "$(command -v pio)" "${CORE_DIR}/penv/bin/pio"; do
    [ -n "${pio_bin}" ] && [ -x "${pio_bin}" ] || continue
    needs_repair "${pio_bin}" "${required}" || continue
    repair_env "${pio_bin}" "${required}" || return 1
    repaired=0
  done

  [ "${repaired}" -eq 0 ]
}

# Runs before the build so a cached runner does not burn a full build cycle on
# a Core it already knows is rejected.
repair_core_before_build() {
  local required
  required="$(platform_requirement)" || return 1
  repair_cores "${required}"
}

# Fallback for a cold cache: the required version comes from the error message.
repair_platform_core() {
  local required
  required="$(grep -oE 'depends on PlatformIO Core >= ?[0-9]+(\.[0-9]+)*' "${LOG}" \
    | tail -n1 | sed -E 's/.*>= ?//')"
  [ -n "${required}" ] || return 1
  repair_cores "${required}"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

for attempt in 1 2 3 4; do
  if repair_core_before_build; then
    echo "::warning::PlatformIO Core repaired before the build"
  fi
  if pio run --environment "${ENV}" 2>&1 | tee "${LOG}"; then
    exit 0
  fi
  if repair_platform_core; then
    echo "::warning::PlatformIO Core repaired, rebuilding ${ENV}"
    continue
  fi
  if grep -qiE 'PackageException|unrecognized status code|HTTP error|timed out|connection (reset|aborted)' "${LOG}"; then
    echo "::warning::Transient download error (attempt ${attempt}/4), retrying in $((attempt * 20))s"
    sleep $((attempt * 20))
    continue
  fi
  echo "::error::Build of ${ENV} failed with a non-transient error"
  exit 1
done

echo "::error::Build of ${ENV} failed after 4 attempts"
exit 1
