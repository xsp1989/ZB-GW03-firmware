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
#     provisions its own Core in <core_dir>/penv and runs the child build with
#     <core_dir>/penv/bin/pio (builder/frameworks/espidf.py), installing
#     "pioarduino>=<engine>" there. pip resolves such a spec to the newest post
#     release, and a post release (6.2.0.post1) is read by PlatformIO as the
#     prerelease 6.2.0-post.1, which ranks below 6.2.0, so a platform requiring
#     ">=6.2.0" refuses to load it ("IncompatiblePlatform").
#
#     The version the platform actually requires is read from that error
#     message, so nothing has to be pinned or updated here when Tasmota moves
#     to a newer platform and Core.

set -uo pipefail

ENV="${1:?usage: build-env.sh <environment> [log file]}"
LOG="${2:-${RUNNER_TEMP:-/tmp}/pio-${ENV}.log}"
CORE_DIR="${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}"

version_ge() {
  [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Core versions PlatformIO cannot accept: a post release is reported as the
# prerelease "x.y.z-post.N", which always sorts before "x.y.z".
core_is_rejected() {
  local out="$1" current
  case "${out}" in
    *-post.*|*-rc.*|*-alpha.*|*-beta.*|*-dev.*) return 0 ;;
  esac
  current="$(printf '%s\n' "${out}" | sed -nE 's/^.*version v?([0-9]+(\.[0-9]+)*).*$/\1/p')"
  [ -n "${current}" ] || return 0
  ! version_ge "${current}" "$2"
}

needs_repair() {
  local out
  out="$("$1" --version 2>&1)" || return 1
  core_is_rejected "${out}" "$2"
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

  echo "::warning::Installing ${dist}==${2} into ${dir}"
  if [ -x "${dir}/uv" ]; then
    "${dir}/uv" pip install -p "${dir}/python" "${dist}==${2}" || return 1
  else
    "${dir}/python" -m pip install "${dist}==${2}" || return 1
  fi
  "${dir}/pio" --version
}

repair_platform_core() {
  local required pio_bin repaired=1

  required="$(grep -oE 'depends on PlatformIO Core >= ?[0-9]+(\.[0-9]+)*' "${LOG}" \
    | tail -n1 | sed -E 's/.*>= ?//')"
  [ -n "${required}" ] || return 1

  # both the platform's own environment and the one that started the build
  for pio_bin in "$(command -v pio)" "${CORE_DIR}/penv/bin/pio"; do
    [ -n "${pio_bin}" ] && [ -x "${pio_bin}" ] || continue
    needs_repair "${pio_bin}" "${required}" || continue
    repair_env "${pio_bin}" "${required}" || return 1
    repaired=0
  done

  [ "${repaired}" -eq 0 ]
}

for attempt in 1 2 3 4; do
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
