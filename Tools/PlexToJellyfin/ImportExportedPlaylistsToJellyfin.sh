#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/exports"

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: required command '$1' not found in PATH."
		exit 1
	fi
}

prompt_config() {
	local default_url="http://localhost:8096"

	read -r -p "Jellyfin URL [${default_url}]: " JELLYFIN_URL
	if [[ -z "${JELLYFIN_URL}" ]]; then
		JELLYFIN_URL="${default_url}"
	fi
	JELLYFIN_URL="${JELLYFIN_URL%/}"

	read -r -p "Jellyfin API key: " JELLYFIN_API_KEY
	if [[ -z "${JELLYFIN_API_KEY}" ]]; then
		echo "Error: API key cannot be empty."
		exit 1
	fi

	read -r -p "Jellyfin username (blank = first user for this key): " JELLYFIN_USERNAME

	read -r -p "Overwrite existing playlists with same name? [Y/n]: " overwrite_choice
	if [[ "${overwrite_choice}" =~ ^[Nn]$ ]]; then
		OVERWRITE_EXISTING="false"
	else
		OVERWRITE_EXISTING="true"
	fi
}

validate_exports() {
	if [[ ! -d "${EXPORT_DIR}" ]]; then
		echo "Error: export directory not found: ${EXPORT_DIR}"
		exit 1
	fi

	if ! find "${EXPORT_DIR}" -maxdepth 1 -type f -name '*.m3u' | grep -q .; then
		echo "Error: no .m3u files found in ${EXPORT_DIR}"
		exit 1
	fi
}

run_import() {
	JELLYFIN_URL="${JELLYFIN_URL}" \
	JELLYFIN_API_KEY="${JELLYFIN_API_KEY}" \
	JELLYFIN_USERNAME="${JELLYFIN_USERNAME}" \
	OVERWRITE_EXISTING="${OVERWRITE_EXISTING}" \
	EXPORT_DIR="${EXPORT_DIR}" \
	python3 - <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

base_url = os.environ["JELLYFIN_URL"].rstrip("/")
api_key = os.environ["JELLYFIN_API_KEY"]
username = os.environ.get("JELLYFIN_USERNAME", "").strip()
overwrite_existing = os.environ.get("OVERWRITE_EXISTING", "true").lower() == "true"
export_dir = Path(os.environ["EXPORT_DIR"])

headers = {
    "X-Emby-Token": api_key,
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def request_json(method: str, path: str, query: dict | None = None, body: dict | None = None):
    query = query or {}
    query_string = urllib.parse.urlencode(query, doseq=True)
    url = f"{base_url}{path}"
    if query_string:
        url = f"{url}?{query_string}"

    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")

    req = urllib.request.Request(url, method=method, headers=headers, data=data)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = resp.read()
            if not content:
                return {}
            return json.loads(content.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"HTTP {exc.code} for {method} {url}\n{details}") from exc


def normalize_path(path: str) -> str:
    return path.strip().rstrip("/")


def get_users():
    return request_json("GET", "/Users")


def choose_user(users):
    if not users:
        raise RuntimeError("No Jellyfin users returned by API key.")

    if username:
        for user in users:
            if user.get("Name", "").lower() == username.lower():
                return user
        raise RuntimeError(f"User '{username}' not found for this API key.")

    return users[0]


def paged_items(user_id: str, include_item_types: str, fields: str):
    start = 0
    limit = 500
    all_items = []

    while True:
        payload = request_json(
            "GET",
            f"/Users/{user_id}/Items",
            {
                "Recursive": "true",
                "IncludeItemTypes": include_item_types,
                "Fields": fields,
                "StartIndex": str(start),
                "Limit": str(limit),
            },
        )

        items = payload.get("Items", [])
        all_items.extend(items)

        if len(items) < limit:
            break
        start += limit

    return all_items


def build_audio_path_index(user_id: str):
    audio_items = paged_items(user_id, "Audio", "Path")
    index = {}
    for item in audio_items:
        item_id = item.get("Id")
        item_path = item.get("Path")
        if not item_id or not item_path:
            continue
        index[normalize_path(item_path)] = item_id
    return index


def get_existing_playlists_by_name(user_id: str):
    playlists = paged_items(user_id, "Playlist", "")
    by_name = {}
    for item in playlists:
        name = item.get("Name")
        item_id = item.get("Id")
        if name and item_id:
            by_name[name] = item_id
    return by_name


def delete_playlist(item_id: str):
    request_json("DELETE", f"/Items/{item_id}")


def create_playlist(user_id: str, name: str, first_item_id: str):
    return request_json(
        "POST",
        "/Playlists",
        {
            "UserId": user_id,
            "Name": name,
            "MediaType": "Audio",
            "Ids": first_item_id,
        },
    )


def add_items_to_playlist(playlist_id: str, user_id: str, item_ids: list[str]):
    if not item_ids:
        return

    chunk_size = 200
    for i in range(0, len(item_ids), chunk_size):
        chunk = item_ids[i : i + chunk_size]
        request_json(
            "POST",
            f"/Playlists/{playlist_id}/Items",
            {
                "UserId": user_id,
                "Ids": ",".join(chunk),
            },
        )


def parse_m3u_paths(path: Path):
    entries = []
    text = path.read_text(encoding="utf-8", errors="ignore")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        entries.append(normalize_path(stripped))
    return entries


users = get_users()
user = choose_user(users)
user_id = user.get("Id")
user_name = user.get("Name", "unknown")

if not user_id:
    raise RuntimeError("Chosen Jellyfin user has no Id.")

print(f"Using Jellyfin user: {user_name} ({user_id})")
print("Indexing Jellyfin audio items by full path...")
audio_index = build_audio_path_index(user_id)
print(f"Indexed audio items: {len(audio_index)}")

existing_playlists = get_existing_playlists_by_name(user_id)

m3u_files = sorted(export_dir.glob("*.m3u"))
if not m3u_files:
    print(f"No .m3u files found in {export_dir}")
    sys.exit(1)

imported = 0
skipped = 0
missing_total = 0

for m3u_file in m3u_files:
    playlist_name = m3u_file.stem
    paths = parse_m3u_paths(m3u_file)

    if not paths:
        print(f"[SKIP] {playlist_name}: no track entries in file")
        skipped += 1
        continue

    resolved_ids = []
    missing = []
    for p in paths:
        item_id = audio_index.get(p)
        if item_id:
            resolved_ids.append(item_id)
        else:
            missing.append(p)

    missing_total += len(missing)

    if not resolved_ids:
        print(f"[SKIP] {playlist_name}: 0 matched tracks, {len(missing)} missing")
        skipped += 1
        continue

    existing_id = existing_playlists.get(playlist_name)
    if existing_id and overwrite_existing:
        delete_playlist(existing_id)
        existing_playlists.pop(playlist_name, None)
        print(f"[INFO] Deleted existing playlist: {playlist_name}")
    elif existing_id and not overwrite_existing:
        print(f"[SKIP] {playlist_name}: already exists (overwrite disabled)")
        skipped += 1
        continue

    create_response = create_playlist(user_id, playlist_name, resolved_ids[0])
    playlist_id = create_response.get("Id")
    if not playlist_id:
        item = create_response.get("Item") or {}
        playlist_id = item.get("Id")
    if not playlist_id:
        raise RuntimeError(f"Failed to create playlist '{playlist_name}': no Id in response")

    add_items_to_playlist(playlist_id, user_id, resolved_ids[1:])
    imported += 1

    print(
        f"[OK]   {playlist_name}: imported {len(resolved_ids)} tracks"
        + (f", missing {len(missing)}" if missing else "")
    )

print()
print("Import complete.")
print(f"  Imported playlists : {imported}")
print(f"  Skipped playlists  : {skipped}")
print(f"  Missing tracks     : {missing_total}")
PY
}

main() {
	require_command python3
	validate_exports
	prompt_config
	run_import
}

main
