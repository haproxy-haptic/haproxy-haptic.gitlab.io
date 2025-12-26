#!/bin/bash
set -e

# Deploy MkDocs documentation with versioning support
#
# Usage: ./scripts/deploy-docs.sh <version> <main-repo-path> <public-dir>
# Example: ./scripts/deploy-docs.sh dev ./main-repo ./public
# Example: ./scripts/deploy-docs.sh v1.0.0 ./main-repo ./public
# Example: ./scripts/deploy-docs.sh v1.0.0-alpha.1 ./main-repo ./public
#
# Version handling:
#   - "dev": Gets "latest" alias (development builds)
#   - "v1.0.0": Final release, gets "latest" alias, removes matching prereleases
#   - "v1.0.0-alpha.1": Prerelease, NO "latest" alias, kept until final release

VERSION="${1:?Version required (e.g., dev, v1.0.0, v1.0.0-alpha.1)}"
MAIN_REPO="${2:?Main repo path required}"
PUBLIC_DIR="${3:?Public directory required}"

# Convert to absolute paths
MAIN_REPO="$(cd "$MAIN_REPO" && pwd)"
PUBLIC_DIR="$(mkdir -p "$PUBLIC_DIR" && cd "$PUBLIC_DIR" && pwd)"

# Check if version is a prerelease (contains -alpha, -beta, or -rc)
is_prerelease() {
  [[ "$1" =~ -(alpha|beta|rc)\. ]]
}

# Extract base version from prerelease (v1.0.0-alpha.1 -> v1.0.0)
get_base_version() {
  echo "$1" | sed 's/-\(alpha\|beta\|rc\)\..*//'
}

# Determine if this version should be "latest"
# - "dev" gets latest alias
# - Final releases (v1.0.0) get latest alias
# - Prereleases (v1.0.0-alpha.1) do NOT get latest alias
if [[ "$VERSION" == "dev" ]]; then
  IS_LATEST=true
  IS_PRERELEASE=false
  IS_FINAL_RELEASE=false
elif is_prerelease "$VERSION"; then
  IS_LATEST=false
  IS_PRERELEASE=true
  IS_FINAL_RELEASE=false
elif [[ "$VERSION" =~ ^v[0-9] ]]; then
  IS_LATEST=true
  IS_PRERELEASE=false
  IS_FINAL_RELEASE=true
  BASE_VERSION="$VERSION"
else
  IS_LATEST=false
  IS_PRERELEASE=false
  IS_FINAL_RELEASE=false
fi

# Function to update versions.json
update_versions_json() {
  local prefix=$1
  local versions_file="${PUBLIC_DIR}/${prefix}/versions.json"

  mkdir -p "${PUBLIC_DIR}/${prefix}"

  # Restore backup if exists (mkdocs cleans public dir during build)
  local backup_file="${VERSIONS_BACKUP_DIR:-/tmp/versions-backup}/${prefix}-versions.json"
  if [ ! -f "$versions_file" ] && [ -f "$backup_file" ]; then
    echo "Restoring ${prefix}/versions.json from backup..."
    cp "$backup_file" "$versions_file"
  fi

  if [ -f "$versions_file" ]; then
    local tmp_file="/tmp/versions_update.json"

    if [ "$IS_FINAL_RELEASE" = true ]; then
      # Final release: remove matching prereleases (v1.0.0-alpha.*, v1.0.0-beta.*, v1.0.0-rc.*)
      # Also remove latest alias from other versions and add this as latest
      echo "Cleaning up prereleases matching ${BASE_VERSION}..."
      jq --arg v "$VERSION" --arg base "$BASE_VERSION" \
        '[{"version":$v,"title":$v,"aliases":["latest"]}] + [.[] | select(.version != $v and (.version | startswith($base + "-") | not)) | .aliases = []]' \
        "$versions_file" > "$tmp_file" && mv "$tmp_file" "$versions_file"
    elif [ "$IS_LATEST" = true ]; then
      # Dev or other latest: remove latest alias from others, add to this version
      jq --arg v "$VERSION" \
        '[{"version":$v,"title":$v,"aliases":["latest"]}] + [.[] | select(.version != $v) | .aliases = []]' \
        "$versions_file" > "$tmp_file" && mv "$tmp_file" "$versions_file"
    else
      # Prerelease or other: just add without latest alias
      jq --arg v "$VERSION" \
        '[{"version":$v,"title":$v,"aliases":[]}] + [.[] | select(.version != $v)]' \
        "$versions_file" > "$tmp_file" && mv "$tmp_file" "$versions_file"
    fi
  else
    # Create new versions.json
    if [ "$IS_LATEST" = true ]; then
      echo "[{\"version\":\"${VERSION}\",\"title\":\"${VERSION}\",\"aliases\":[\"latest\"]}]" > "$versions_file"
    else
      echo "[{\"version\":\"${VERSION}\",\"title\":\"${VERSION}\",\"aliases\":[]}]" > "$versions_file"
    fi
  fi

  # Ensure dev is always in versions.json if dev directory exists
  local dev_dir="${PUBLIC_DIR}/${prefix}/dev"
  if [ -d "$dev_dir" ] && ! jq -e '.[] | select(.version == "dev")' "$versions_file" > /dev/null 2>&1; then
    echo "Adding missing 'dev' entry to versions.json..."
    local tmp_file="/tmp/versions_dev_fix.json"
    jq '. + [{"version":"dev","title":"dev","aliases":[]}]' "$versions_file" > "$tmp_file" && mv "$tmp_file" "$versions_file"
  fi
}

# Function to clean up prerelease directories when final release ships
cleanup_prerelease_dirs() {
  local prefix=$1
  local base_version=$2
  local site_dir="${PUBLIC_DIR}/${prefix}"

  if [ -d "$site_dir" ]; then
    echo "Cleaning up prerelease directories for ${base_version}..."
    for prerelease_dir in "${site_dir}/${base_version}"-{alpha,beta,rc}.*; do
      if [ -d "$prerelease_dir" ]; then
        echo "  Removing: $(basename "$prerelease_dir")"
        rm -rf "$prerelease_dir"
      fi
    done
  fi
}

# Function to build and deploy a doc site
deploy_doc_site() {
  local name=$1
  local src_dir=$2

  echo "Building ${name} docs version ${VERSION}..."

  cd "$src_dir"
  mkdocs build -d "${PUBLIC_DIR}/${name}/${VERSION}"
  cd - > /dev/null

  # Update latest symlink if this is the latest version
  if [ "$IS_LATEST" = true ]; then
    cd "${PUBLIC_DIR}/${name}"
    rm -f latest
    ln -s "$VERSION" latest
    cd - > /dev/null
  fi

  # Clean up prerelease directories if this is a final release
  if [ "$IS_FINAL_RELEASE" = true ]; then
    cleanup_prerelease_dirs "$name" "$BASE_VERSION"
  fi

  # Update versions.json
  update_versions_json "$name"
}

echo "=== Deploying docs ==="
echo "Version: ${VERSION}"
echo "Main repo: ${MAIN_REPO}"
echo "Public dir: ${PUBLIC_DIR}"
echo "Is latest: ${IS_LATEST}"
echo "Is prerelease: ${IS_PRERELEASE}"
echo "Is final release: ${IS_FINAL_RELEASE}"
echo ""

# Copy shared CSS to all doc sites
echo "Copying shared CSS..."
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/docs/controller/docs/stylesheets/"
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/docs/landing/docs/stylesheets/"
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/charts/haptic/docs/stylesheets/"

# Build landing page (not versioned)
echo "Building landing page..."
cd "${MAIN_REPO}/docs/landing"
mkdocs build -d "${PUBLIC_DIR}"
cd - > /dev/null

# Deploy versioned doc sites
deploy_doc_site "controller" "${MAIN_REPO}/docs/controller"
deploy_doc_site "helm-chart" "${MAIN_REPO}/charts/haptic"

# Copy shared assets
mkdir -p "${PUBLIC_DIR}/shared"
cp "${MAIN_REPO}/docs/shared/colors.css" "${PUBLIC_DIR}/shared/colors.css"

echo ""
echo "=== Deployment complete ==="
echo "Controller versions.json:"
cat "${PUBLIC_DIR}/controller/versions.json"
echo ""
echo "Helm-chart versions.json:"
cat "${PUBLIC_DIR}/helm-chart/versions.json"
