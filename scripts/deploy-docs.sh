#!/bin/bash
set -e

# Deploy MkDocs documentation with versioning support
#
# Usage: ./scripts/deploy-docs.sh <version> <main-repo-path> <public-dir>
# Example: ./scripts/deploy-docs.sh dev ./main-repo ./public
# Example: ./scripts/deploy-docs.sh v1.0.0 ./main-repo ./public

VERSION="${1:?Version required (e.g., dev, v1.0.0)}"
MAIN_REPO="${2:?Main repo path required}"
PUBLIC_DIR="${3:?Public directory required}"

# Convert to absolute paths
MAIN_REPO="$(cd "$MAIN_REPO" && pwd)"
PUBLIC_DIR="$(mkdir -p "$PUBLIC_DIR" && cd "$PUBLIC_DIR" && pwd)"

# Determine if this version should be "latest"
# Tagged versions (v*) and dev get the latest alias
if [[ "$VERSION" == "dev" ]] || [[ "$VERSION" =~ ^v[0-9] ]]; then
  IS_LATEST=true
else
  IS_LATEST=false
fi

# Function to update versions.json
update_versions_json() {
  local prefix=$1
  local versions_file="${PUBLIC_DIR}/${prefix}/versions.json"

  mkdir -p "${PUBLIC_DIR}/${prefix}"

  if [ -f "$versions_file" ]; then
    # Remove latest alias from all existing versions, add new version at beginning
    if [ "$IS_LATEST" = true ]; then
      jq --arg v "$VERSION" \
        '[{"version":$v,"title":$v,"aliases":["latest"]}] + [.[] | select(.version != $v) | .aliases = []]' \
        "$versions_file" > /tmp/versions.json && mv /tmp/versions.json "$versions_file"
    else
      jq --arg v "$VERSION" \
        '[{"version":$v,"title":$v,"aliases":[]}] + [.[] | select(.version != $v)]' \
        "$versions_file" > /tmp/versions.json && mv /tmp/versions.json "$versions_file"
    fi
  else
    # Create new versions.json
    if [ "$IS_LATEST" = true ]; then
      echo "[{\"version\":\"${VERSION}\",\"title\":\"${VERSION}\",\"aliases\":[\"latest\"]}]" > "$versions_file"
    else
      echo "[{\"version\":\"${VERSION}\",\"title\":\"${VERSION}\",\"aliases\":[]}]" > "$versions_file"
    fi
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

  # Update versions.json
  update_versions_json "$name"
}

echo "=== Deploying docs ==="
echo "Version: ${VERSION}"
echo "Main repo: ${MAIN_REPO}"
echo "Public dir: ${PUBLIC_DIR}"
echo "Is latest: ${IS_LATEST}"
echo ""

# Copy shared CSS to all doc sites
echo "Copying shared CSS..."
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/docs/controller/docs/stylesheets/"
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/docs/landing/docs/stylesheets/"
cp "${MAIN_REPO}/docs/shared/colors.css" "${MAIN_REPO}/charts/haproxy-template-ic/docs/stylesheets/"

# Build landing page (not versioned)
echo "Building landing page..."
cd "${MAIN_REPO}/docs/landing"
mkdocs build -d "${PUBLIC_DIR}"
cd - > /dev/null

# Deploy versioned doc sites
deploy_doc_site "controller" "${MAIN_REPO}/docs/controller"
deploy_doc_site "helm-chart" "${MAIN_REPO}/charts/haproxy-template-ic"

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
