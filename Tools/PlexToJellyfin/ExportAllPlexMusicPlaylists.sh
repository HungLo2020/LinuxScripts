#!/usr/bin/env bash

set -euo pipefail

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: required command '$1' not found in PATH."
		exit 1
	fi
}

sanitize_filename() {
	local value="$1"
	value="${value//\//-}"
	value="${value//:/-}"
	value="${value//$'\n'/ }"
	printf '%s' "$value" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//; s/[^[:alnum:]_. -]/_/g'
}

prompt_defaults() {
	local default_url="http://localhost:32400"
	read -r -p "Plex URL [${default_url}]: " PLEX_URL
	if [[ -z "${PLEX_URL}" ]]; then
		PLEX_URL="${default_url}"
	fi
	PLEX_URL="${PLEX_URL%/}"

	read -r -p "Plex token (X-Plex-Token): " PLEX_TOKEN
	if [[ -z "${PLEX_TOKEN}" ]]; then
		echo "Error: Plex token cannot be empty."
		exit 1
	fi

	local default_output
	default_output="${PWD}/plex-playlists-export-$(date +%F-%H%M%S)"
	read -r -p "Output directory [${default_output}]: " OUTPUT_DIR
	if [[ -z "${OUTPUT_DIR}" ]]; then
		OUTPUT_DIR="${default_output}"
	fi
}

fetch_audio_playlists_xml() {
	curl -fsSL "${PLEX_URL}/playlists?playlistType=audio&X-Plex-Token=${PLEX_TOKEN}"
}

parse_playlists_to_tsv() {
	python3 - <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_data = sys.stdin.read()
if not xml_data.strip():
    sys.exit(0)

try:
    root = ET.fromstring(xml_data)
except ET.ParseError as exc:
    print(f"ERROR\tPARSE\t{exc}")
    sys.exit(2)

for playlist in root.findall('.//Playlist'):
    key = playlist.get('ratingKey', '').strip()
    title = playlist.get('title', '').strip() or 'Untitled Playlist'
    if key:
        print(f"{key}\t{title}")
PY
}

write_m3u_from_xml() {
	local xml_file="$1"
	local m3u_file="$2"

	python3 - "$xml_file" "$m3u_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path, m3u_path = sys.argv[1], sys.argv[2]

tree = ET.parse(xml_path)
root = tree.getroot()

count = 0
with open(m3u_path, 'w', encoding='utf-8') as out:
    out.write('#EXTM3U\n')
    for track in root.findall('.//Track'):
        part = track.find('./Media/Part')
        if part is None:
            continue
        file_path = part.get('file')
        if not file_path:
            continue
        out.write(file_path + '\n')
        count += 1

print(count)
PY
}

main() {
	require_command curl
	require_command python3

	prompt_defaults
	mkdir -p "${OUTPUT_DIR}"

	echo "Fetching Plex audio playlists from ${PLEX_URL} ..."
	playlist_xml="$(fetch_audio_playlists_xml)"

	playlist_tsv="$(printf '%s' "${playlist_xml}" | parse_playlists_to_tsv)"

	if printf '%s\n' "${playlist_tsv}" | grep -q '^ERROR'; then
		echo "Error: failed to parse Plex playlist response."
		printf '%s\n' "${playlist_tsv}"
		exit 1
	fi

	if [[ -z "${playlist_tsv}" ]]; then
		echo "No Plex audio playlists found."
		echo "Done."
		exit 0
	fi

	local total=0
	local succeeded=0
	local failed=0

	echo "Exporting playlists to ${OUTPUT_DIR} ..."
	while IFS=$'\t' read -r rating_key title; do
		[[ -z "${rating_key}" ]] && continue
		total=$((total + 1))

		safe_title="$(sanitize_filename "${title}")"
		if [[ -z "${safe_title}" ]]; then
			safe_title="Playlist_${rating_key}"
		fi

		xml_file="${OUTPUT_DIR}/${safe_title}.xml"
		m3u_file="${OUTPUT_DIR}/${safe_title}.m3u"

		if ! curl -fsSL "${PLEX_URL}/playlists/${rating_key}/items?X-Plex-Token=${PLEX_TOKEN}" -o "${xml_file}"; then
			echo "[FAIL] ${title} (key=${rating_key}) - could not fetch items"
			failed=$((failed + 1))
			continue
		fi

		track_count="$(write_m3u_from_xml "${xml_file}" "${m3u_file}" || true)"
		if [[ -z "${track_count}" || ! "${track_count}" =~ ^[0-9]+$ ]]; then
			echo "[FAIL] ${title} (key=${rating_key}) - could not parse playlist XML"
			failed=$((failed + 1))
			continue
		fi

		echo "[OK]   ${title} -> ${safe_title}.m3u (${track_count} tracks)"
		succeeded=$((succeeded + 1))
	done <<<"${playlist_tsv}"

	echo
	echo "Export complete."
	echo "  Total playlists found : ${total}"
	echo "  Successfully exported : ${succeeded}"
	echo "  Failed                : ${failed}"
	echo "  Output directory      : ${OUTPUT_DIR}"
}

main
