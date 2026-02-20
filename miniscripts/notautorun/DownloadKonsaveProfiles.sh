#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILES_DIR="$REPO_ROOT/KDEProfiles"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run: gh auth login"
  exit 1
fi

if ! mkdir -p "$PROFILES_DIR"; then
  echo "Error: Could not create profiles directory: $PROFILES_DIR"
  exit 1
fi

if [[ ! -w "$PROFILES_DIR" ]]; then
  echo "Error: Profiles directory is not writable: $PROFILES_DIR"
  exit 1
fi

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [[ -z "$ORIGIN_URL" ]]; then
  echo "Error: Could not determine git origin URL."
  exit 1
fi

if [[ "$ORIGIN_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  echo "Error: Origin is not a recognizable GitHub URL: $ORIGIN_URL"
  exit 1
fi

REPO_SLUG="$OWNER/$REPO"

echo "Fetching releases from $REPO_SLUG..."
mapfile -t RELEASE_TAGS < <(gh api --paginate "/repos/$REPO_SLUG/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null || true)

if [[ ${#RELEASE_TAGS[@]} -eq 0 ]]; then
  echo "No releases found in $REPO_SLUG."
  exit 0
fi

echo "Found ${#RELEASE_TAGS[@]} release(s). Downloading assets to $PROFILES_DIR"
for tag in "${RELEASE_TAGS[@]}"; do
  echo "Downloading assets for release: $tag"
  gh release download "$tag" --repo "$REPO_SLUG" --dir "$PROFILES_DIR" --clobber

done

echo "Done. Downloaded release assets into $PROFILES_DIR"