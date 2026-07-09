#!/bin/bash
set -e

# Deploy MkDocs documentation with versioning support
#
# Usage: ./scripts/deploy-docs.sh <version> <main-repo-path> <public-dir>
# Example: ./scripts/deploy-docs.sh dev ./main-repo ./public
# Example: ./scripts/deploy-docs.sh v1.0.0 ./main-repo ./public
# Example: ./scripts/deploy-docs.sh v1.0.0-alpha.1 ./main-repo ./public
#
# Version handling (leading "v" is stripped automatically):
#   - "dev": No "latest" alias (JS fallback picks it when no release exists)
#   - "v1.0.0" / "1.0.0": Final release, gets "latest" alias, removes matching prereleases
#   - "v1.0.0-alpha.1": Prerelease, NO "latest" alias, kept until final release

VERSION="${1:?Version required (e.g., dev, v1.0.0, v1.0.0-alpha.1)}"
MAIN_REPO="${2:?Main repo path required}"
PUBLIC_DIR="${3:?Public directory required}"

# Normalize: strip leading "v" (CI passes v0.1.0, helm expects 0.1.0)
VERSION="${VERSION#v}"

# Convert to absolute paths
MAIN_REPO="$(cd "$MAIN_REPO" && pwd)"
PUBLIC_DIR="$(mkdir -p "$PUBLIC_DIR" && cd "$PUBLIC_DIR" && pwd)"

# Check if version is a prerelease (contains -alpha, -beta, or -rc)
is_prerelease() {
  [[ "$1" =~ -(alpha|beta|rc)\. ]]
}

# Extract base version from prerelease (1.0.0-alpha.1 -> 1.0.0)
get_base_version() {
  echo "$1" | sed 's/-\(alpha\|beta\|rc\)\..*//'
}

# Determine if this version should be "latest"
# - "dev" does NOT get latest alias (JS fallback picks versions[0])
# - Final releases (1.0.0) get latest alias
# - Prereleases (1.0.0-alpha.1) do NOT get latest alias
if [[ "$VERSION" == "dev" ]]; then
  IS_LATEST=false
  IS_PRERELEASE=false
  IS_FINAL_RELEASE=false
elif is_prerelease "$VERSION"; then
  IS_LATEST=false
  IS_PRERELEASE=true
  IS_FINAL_RELEASE=false
elif [[ "$VERSION" =~ ^[0-9] ]]; then
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
        '[{"version":$v,"title":$v,"aliases":["latest"]}] + [.[] | select(.version != $v and .version != ("v" + $v) and (.version | startswith($base + "-") | not)) | .aliases = []]' \
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

# Refresh the shared public/playground/versions.json (object schema the shell's
# initVersions consumes: { current, versions: [{version, stable}] }). Upserts this
# VERSION and sets `current` to the newest non-dev release (prereleases included).
update_playground_versions() {
  local vfile="${PUBLIC_DIR}/playground/versions.json"
  mkdir -p "$(dirname "$vfile")"
  local stable=true
  if [ "$VERSION" = "dev" ] || is_prerelease "$VERSION"; then stable=false; fi
  [ -f "$vfile" ] || echo '{"versions":[]}' > "$vfile"

  local tmp="/tmp/pg-versions.json"
  jq --arg v "$VERSION" --argjson stable "$stable" \
    '.versions = ([{version:$v, stable:$stable}] + [.versions[] | select(.version != $v)])' \
    "$vfile" > "$tmp" && mv "$tmp" "$vfile"

  # current = newest non-dev version (dev is never `current`); omitted while only dev exists.
  local current
  current="$(jq -r '[.versions[] | select(.version != "dev") | .version] | .[0] // empty' "$vfile")"
  if [ -n "$current" ]; then
    jq --arg c "$current" '.current = $c' "$vfile" > "$tmp" && mv "$tmp" "$vfile"
  fi
  echo "playground/versions.json:"; cat "$vfile"

  # Landing redirect so bare /playground/ resolves to the current (or dev) shell.
  # The JS redirect carries the query string and fragment through, so deep-links
  # like /playground/?preset=ingress and /playground/#s=<share> keep working; the
  # meta-refresh + link is a no-JS fallback (target shell only).
  local landing="${current:-dev}"
  cat > "${PUBLIC_DIR}/playground/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>HAPTIC Playground</title>
<script>location.replace('./${landing}/' + location.search + location.hash)</script>
<meta http-equiv="refresh" content="0; url=./${landing}/">
<link rel="canonical" href="./${landing}/"></head>
<body><p><a href="./${landing}/">HAPTIC Playground &rarr;</a></p></body></html>
HTML
}

# GitLab API GET / artifact download with the CI job token, falling back to an
# anonymous request (haptic is a public project).
gl_get() { curl -sSf --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$1" 2>/dev/null || curl -sSf "$1" 2>/dev/null; }
gl_dl()  { curl -sSf --location --output "$2" --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$1" 2>/dev/null || curl -sSf --location --output "$2" "$1" 2>/dev/null; }

# Fetch the browser-playground bundle from the haptic build-playground-wasm job
# artifact and publish it under public/playground/<version>/, then refresh
# versions.json. CI-only (needs CI_JOB_TOKEN); skipped locally, where the bundle is
# built directly via scripts/build-playground.sh.
deploy_playground() {
  if [ -z "${CI_JOB_TOKEN:-}" ]; then
    echo "Skipping playground publish (no CI_JOB_TOKEN; build locally with scripts/build-playground.sh)"
    return 0
  fi
  # dev pulls the latest main build; a release pulls its v-tag build.
  local ref="main"
  [ "$VERSION" = "dev" ] || ref="v${VERSION}"
  local project="haproxy-haptic%2Fhaptic"
  local api="https://gitlab.com/api/v4/projects/${project}"

  # Resolve the build-playground-wasm artifact for the LATEST pipeline on $ref by
  # its specific job id. A job's artifact downloads as soon as that job succeeds —
  # unlike jobs/artifacts/<ref>/download, which resolves to the latest *fully
  # successful pipeline* and returns a stale bundle while this commit's pipeline is
  # still running its other (e.g. e2e) jobs. haptic's trigger-pages waits for
  # build-playground-wasm, so the job is finished on the newest pipeline by now.
  echo "Resolving playground bundle (ref=${ref})..."
  # Fetch the build-playground-wasm artifact for the SAME commit the docs were
  # just built from (the cloned main-repo HEAD), so the published docs and
  # playground never drift. Pinning by sha (not "latest pipeline") avoids the race
  # where this deploy is triggered before that commit's build-playground-wasm has
  # finished and would otherwise grab a stale bundle; wait briefly if it hasn't.
  local sha pid jobid url tries=0
  sha="$(git -C "${MAIN_REPO}" rev-parse HEAD 2>/dev/null || true)"
  while [ -n "$sha" ]; do
    pid="$(gl_get "${api}/pipelines?ref=${ref}&sha=${sha}&per_page=1" | jq -r '.[0].id // empty')"
    [ -n "$pid" ] && jobid="$(gl_get "${api}/pipelines/${pid}/jobs?per_page=100" | jq -r '[.[] | select(.name=="build-playground-wasm" and .status=="success")][0].id // empty')"
    [ -n "${jobid:-}" ] && break
    tries=$((tries + 1)); [ "$tries" -ge 12 ] && break   # ~4 min ceiling, then fall back
    echo "  waiting for build-playground-wasm on ${sha:0:8} (try ${tries}/12)..."; sleep 20
  done
  if [ -n "${jobid:-}" ]; then
    url="${api}/jobs/${jobid}/artifacts"
    echo "  pipeline ${pid} (${sha:0:8}) -> build-playground-wasm job ${jobid}"
  else
    url="${api}/jobs/artifacts/${ref}/download?job=build-playground-wasm"
    echo "  no build-playground-wasm for ${sha:-$ref}; falling back to latest-successful-pipeline artifact" >&2
  fi
  if ! gl_dl "$url" /tmp/pg.zip; then
    echo "WARNING: no playground artifact for ref ${ref}; leaving existing /playground/ untouched" >&2
    return 0
  fi
  rm -rf /tmp/pg-extract && mkdir -p /tmp/pg-extract
  unzip -q -o /tmp/pg.zip -d /tmp/pg-extract
  rm -f /tmp/pg.zip
  if [ ! -d /tmp/pg-extract/public/playground ]; then
    echo "WARNING: artifact had no public/playground/; skipping" >&2
    return 0
  fi
  mkdir -p "${PUBLIC_DIR}/playground"
  # Copies the <version>/ dir (raw + .br + .gz siblings) into the site.
  cp -a /tmp/pg-extract/public/playground/. "${PUBLIC_DIR}/playground/"
  rm -rf /tmp/pg-extract
  update_playground_versions
  echo "Published playground/${VERSION}:"
  ls "${PUBLIC_DIR}/playground/${VERSION}" 2>/dev/null | head
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
# Use temp directory to avoid mkdocs cleaning existing version directories
echo "Building landing page..."
cd "${MAIN_REPO}/docs/landing"
LANDING_TEMP=$(mktemp -d)
mkdocs build -d "${LANDING_TEMP}"
# Copy landing files to public dir without removing existing version directories
cp -a "${LANDING_TEMP}"/* "${PUBLIC_DIR}/"
rm -rf "${LANDING_TEMP}"
cd - > /dev/null

# Deploy versioned doc sites
deploy_doc_site "controller" "${MAIN_REPO}/docs/controller"
deploy_doc_site "helm-chart" "${MAIN_REPO}/charts/haptic"

# Publish the browser playground bundle (fetched from the haptic build artifact).
# Non-fatal: a playground hiccup must never block the docs deploy (and also disables
# set -e inside the function so a partial failure returns cleanly).
deploy_playground || echo "WARNING: playground publish step failed (non-fatal); docs unaffected"

# Copy shared assets (referenced by every site via absolute /shared/... URLs)
mkdir -p "${PUBLIC_DIR}/shared"
cp "${MAIN_REPO}/docs/shared/colors.css" "${PUBLIC_DIR}/shared/colors.css"
# Interactive playground embed component (loaded by each site's mkdocs.yml)
for f in playground-embed.css playground-embed.js; do
  [ -f "${MAIN_REPO}/docs/shared/$f" ] && cp "${MAIN_REPO}/docs/shared/$f" "${PUBLIC_DIR}/shared/$f"
done

echo ""
echo "=== Deployment complete ==="
echo "Controller versions.json:"
cat "${PUBLIC_DIR}/controller/versions.json"
echo ""
echo "Helm-chart versions.json:"
cat "${PUBLIC_DIR}/helm-chart/versions.json"
