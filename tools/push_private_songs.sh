#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd "${script_directory}/.." && pwd)"

adb_binary="${MUSIRAIL_ADB:-adb}"
device_serial="${MUSIRAIL_DEVICE:-}"
package="${MUSIRAIL_PACKAGE:-io.github.bbodin.musirail}"
source_directory="${MUSIRAIL_PRIVATE_SONGS_DIR:-${project_directory}/songs}"
destination_directory="${MUSIRAIL_APP_SONGS_DIR:-files/songs}"
import_directory="${MUSIRAIL_DEVICE_IMPORT_DIR:-/sdcard/Download/Musirail}"

if [[ ! -d "${source_directory}" ]]; then
  echo "Private song directory does not exist: ${source_directory}" >&2
  exit 1
fi

adb_command=("${adb_binary}")
if [[ -n "${device_serial}" ]]; then
  adb_command+=(-s "${device_serial}")
fi

if [[ ! "${package}" =~ ^[A-Za-z0-9._]+$ ]]; then
  echo "Invalid Android package name: ${package}" >&2
  exit 1
fi

if [[
  -z "${destination_directory}"
  || "${destination_directory}" == /*
  || ! "${destination_directory}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$
  || "${destination_directory}" =~ (^|/)\.\.?($|/)
]]; then
  echo "Invalid app-relative song directory: ${destination_directory}" >&2
  exit 1
fi

if [[
  -z "${import_directory}"
  || ! "${import_directory}" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$
  || "${import_directory}" =~ (^|/)\.\.?($|/)
]]; then
  echo "Device import directory must be an absolute path: ${import_directory}" >&2
  exit 1
fi

shopt -s nullglob
song_directories=("${source_directory}"/song_*)
shopt -u nullglob

private_song_count=0
for song_directory in "${song_directories[@]}"; do
  if [[ -d "${song_directory}" ]]; then
    private_song_count=$((private_song_count + 1))
  fi
done

if ((private_song_count == 0)); then
  echo "No private song_* directories found in ${source_directory}; skipping copy."
  exit 0
fi

staging_directory="/data/local/tmp/musirail-private-songs-${package//./-}"

cleanup() {
  "${adb_command[@]}" shell rm -rf "${staging_directory}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
"${adb_command[@]}" shell mkdir -p "${staging_directory}"
"${adb_command[@]}" shell mkdir -p "${import_directory}"
"${adb_command[@]}" shell run-as "${package}" mkdir -p "${destination_directory}"

playable_candidate_count=0
for song_directory in "${song_directories[@]}"; do
  if [[ ! -d "${song_directory}" ]]; then
    continue
  fi
  song_name="$(basename "${song_directory}")"
  staged_song="${staging_directory}/${song_name}"
  installed_song="${destination_directory}/${song_name}"
  import_song="${import_directory}/${song_name}"
  echo "Installing ${song_name} in ${package}:${installed_song}"
  "${adb_command[@]}" push "${song_directory}" "${staging_directory}/"
  "${adb_command[@]}" shell rm -rf "${import_song}"
  "${adb_command[@]}" shell cp -R "${staged_song}" "${import_song}"
  "${adb_command[@]}" shell run-as "${package}" rm -rf "${installed_song}"
  "${adb_command[@]}" shell run-as "${package}" cp -R \
    "${staged_song}" "${installed_song}"
  if [[ -f "${song_directory}/metadata.json" && -f "${song_directory}/chart.json" ]]; then
    playable_candidate_count=$((playable_candidate_count + 1))
  else
    echo "Warning: ${song_name} has no metadata.json and/or chart.json; PLAY will ignore it." >&2
  fi
done

echo "Installed ${private_song_count} private song directories in ${package}:${destination_directory}."
echo "Mirrored them to ${import_directory} for Android's Track Editor picker."
if ((playable_candidate_count == 0)); then
  echo "No playable song workspaces were installed. Raw audio can be used in Track Editor, but PLAY requires metadata.json and chart.json." >&2
fi
