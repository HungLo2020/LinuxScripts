#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILES_DIR="$REPO_ROOT/KDEProfiles"

contains_exact() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run: gh auth login"
  exit 1
fi

if [[ ! -d "$PROFILES_DIR" ]]; then
  echo "Error: KDE profiles directory not found: $PROFILES_DIR"
  exit 1
fi

shopt -s nullglob
PROFILE_FILES=("$PROFILES_DIR"/*.knsv)
shopt -u nullglob

if [[ ${#PROFILE_FILES[@]} -eq 0 ]]; then
  echo "Error: No .knsv profiles found in $PROFILES_DIR"
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

declare -a LOCAL_TAGS=()
for profile_path in "${PROFILE_FILES[@]}"; do
  profile_file="$(basename "$profile_path")"
  profile_name="${profile_file%.knsv}"
  LOCAL_TAGS+=("$profile_name")
done

echo "Sync target repo: $REPO_SLUG"
echo "Local profiles found: ${#LOCAL_TAGS[@]}"

mapfile -t EXISTING_TAGS < <(gh api --paginate "/repos/$REPO_SLUG/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null || true)

# Delete releases not represented by current KDEProfiles/*.knsv files.
for tag in "${EXISTING_TAGS[@]}"; do
  if ! contains_exact "$tag" "${LOCAL_TAGS[@]}"; then
    echo "Deleting stale release: $tag"
    gh release delete "$tag" --repo "$REPO_SLUG" --yes --cleanup-tag
  fi
done

# Recreate each profile release with the same name as the profile.
for profile_path in "${PROFILE_FILES[@]}"; do
  profile_file="$(basename "$profile_path")"
  profile_name="${profile_file%.knsv}"

  if gh release view "$profile_name" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "Deleting existing release for overwrite: $profile_name"
    gh release delete "$profile_name" --repo "$REPO_SLUG" --yes --cleanup-tag
  fi

  echo "Creating release $profile_name with asset $profile_file"
  gh release create "$profile_name" "$profile_path" \
    --repo "$REPO_SLUG" \
    --title "$profile_name" \
    --notes ""
done

echo "Done. GitHub Releases now match local KDEProfiles/*.knsv files."