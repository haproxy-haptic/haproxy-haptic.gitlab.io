#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:?version required}"
MAIN_REPO="${2:?main repo path required}"
PUBLIC_DIR="${3:?public directory required}"
MODE="${4:-publish}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION#v}"
MAIN_REPO="$(cd "$MAIN_REPO" && pwd)"
PUBLIC_DIR="$(mkdir -p "$PUBLIC_DIR" && cd "$PUBLIC_DIR" && pwd)"

[[ "$MODE" == publish || "$MODE" == preview ]] || { echo "invalid deployment mode: $MODE" >&2; exit 1; }
if [ "$MODE" = publish ]; then
  SOURCE_COMMIT="${HAPTIC_RELEASE_COMMIT_SHA:?HAPTIC_RELEASE_COMMIT_SHA is required}"
  SOURCE_PIPELINE="${HAPTIC_RELEASE_PIPELINE_ID:?HAPTIC_RELEASE_PIPELINE_ID is required}"
  SOURCE_JOB_NAME="${HAPTIC_RELEASE_PLAYGROUND_JOB_NAME:?HAPTIC_RELEASE_PLAYGROUND_JOB_NAME is required}"
  CI_JOB_TOKEN="${CI_JOB_TOKEN:?CI_JOB_TOKEN is required}"
else
  SOURCE_COMMIT="${CI_COMMIT_SHA:-$(git -C "$MAIN_REPO" rev-parse HEAD)}"
  SOURCE_PIPELINE="${CI_PIPELINE_ID:-0}"
  SOURCE_JOB="${CI_JOB_ID:-0}"
  SOURCE_JOB_NAME=preview
fi

[[ "$VERSION" == dev || "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || {
  echo "invalid documentation version: $VERSION" >&2
  exit 1
}
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source commit: $SOURCE_COMMIT" >&2; exit 1; }
[[ "$SOURCE_PIPELINE" =~ ^[0-9]+$ ]] || { echo "invalid source pipeline: $SOURCE_PIPELINE" >&2; exit 1; }
[[ "$SOURCE_JOB_NAME" =~ ^[a-z0-9-]+$ ]] || { echo "invalid playground job name: $SOURCE_JOB_NAME" >&2; exit 1; }

EXPECTED_REF=main
[ "$VERSION" = dev ] || EXPECTED_REF="v${VERSION}"

tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

gl_get() {
  curl -sSf --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$1" 2>/dev/null || curl -sSf "$1"
}

gl_download() {
  curl -sSfL --output "$2" --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$1" 2>/dev/null ||
    curl -sSfL --output "$2" "$1"
}

identity_matches() {
  local file=$1
  jq -e \
    --arg version "$VERSION" \
    --arg commit "$SOURCE_COMMIT" \
    --arg pipeline "$SOURCE_PIPELINE" \
    --arg job "$SOURCE_JOB" \
    '.version == $version and .commit == $commit and .pipeline == $pipeline and .job == $job' \
    "$file" >/dev/null
}

write_identity() {
  jq -n \
    --arg version "$VERSION" \
    --arg commit "$SOURCE_COMMIT" \
    --arg pipeline "$SOURCE_PIPELINE" \
    --arg job "$SOURCE_JOB" \
    '{version:$version, commit:$commit, pipeline:$pipeline, job:$job}' > "$1"
}

publish_version_dir() {
  local source=$1
  local destination=$2
  local required_file=$3

  if [ -e "$destination" ]; then
    [ -d "$destination" ] || { echo "$destination is not a directory" >&2; return 1; }
    [ -s "$destination/$required_file" ] || { echo "$destination is incomplete" >&2; return 1; }
    if [ -s "$destination/release-identity.json" ]; then
      identity_matches "$destination/release-identity.json" || {
        echo "$destination belongs to another source" >&2
        return 1
      }
      echo "Keeping existing immutable $destination"
      return 0
    fi

    local comparison="$tmp_root/legacy-comparison"
    rm -rf -- "$comparison"
    cp -a "$source" "$comparison"
    rm -f -- "$comparison/release-identity.json"
    diff -qr "$destination" "$comparison" >/dev/null || {
      echo "$destination has no identity marker and differs from the exact rebuild" >&2
      return 1
    }
    cp "$source/release-identity.json" "$destination/release-identity.json"
    return 0
  fi

  local parent name stage
  parent=$(dirname "$destination")
  name=$(basename "$destination")
  mkdir -p "$parent"
  stage=$(mktemp -d "$parent/.${name}.stage.XXXXXX")
  cp -a "$source/." "$stage/"
  mv "$stage" "$destination"
}

replace_moving_dir() {
  local source=$1
  local destination=$2
  local parent name stage
  parent=$(dirname "$destination")
  name=$(basename "$destination")
  mkdir -p "$parent"
  stage=$(mktemp -d "$parent/.${name}.stage.XXXXXX")
  cp -a "$source/." "$stage/"
  rm -rf -- "$destination"
  mv "$stage" "$destination"
}

collect_versions() {
  local prefix=$1
  local versions_file="$PUBLIC_DIR/$prefix/versions.json"

  {
    if [ -f "$versions_file" ]; then
      jq -r 'if type == "array" then .[].version else .versions[].version end' "$versions_file"
    fi
    find "$PUBLIC_DIR/$prefix" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
    printf '%s\n' "$VERSION"
  } | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$' | sort -u |
    "$SCRIPT_DIR/semver-order.py"
}

update_docs_versions() {
  local prefix=$1
  local versions_file="$PUBLIC_DIR/$prefix/versions.json"
  local latest=
  local -a releases=()
  mapfile -t releases < <(collect_versions "$prefix")

  local release
  for release in "${releases[@]}"; do
    if [[ "$release" != *-* ]]; then
      latest=$release
      break
    fi
  done

  mkdir -p "$PUBLIC_DIR/$prefix"
  jq -n --args '$ARGS.positional | map({version:., title:., aliases:[]})' \
    "${releases[@]}" > "$versions_file"
  if [ -d "$PUBLIC_DIR/$prefix/dev" ]; then
    jq '. + [{version:"dev", title:"dev", aliases:[]}]' "$versions_file" > "$tmp_root/docs-versions.json"
    mv "$tmp_root/docs-versions.json" "$versions_file"
  fi
  if [ -n "$latest" ]; then
    [ -d "$PUBLIC_DIR/$prefix/$latest" ] || { echo "missing latest target: $prefix/$latest" >&2; return 1; }
    jq --arg latest "$latest" 'map(.aliases = (if .version == $latest then ["latest"] else [] end))' \
      "$versions_file" > "$tmp_root/docs-versions.json"
    mv "$tmp_root/docs-versions.json" "$versions_file"
    if [ -e "$PUBLIC_DIR/$prefix/latest" ] && [ ! -L "$PUBLIC_DIR/$prefix/latest" ]; then
      echo "$prefix/latest is not a symlink" >&2
      return 1
    fi
    ln -sfn "$latest" "$PUBLIC_DIR/$prefix/latest"
  fi
}

update_playground_versions() {
  local versions_file="$PUBLIC_DIR/playground/versions.json"
  local current=
  local -a releases=()
  mapfile -t releases < <(collect_versions playground)

  local release
  for release in "${releases[@]}"; do
    if [[ "$release" != *-* ]]; then
      current=$release
      break
    fi
  done
  if [ -z "$current" ] && [ "${#releases[@]}" -gt 0 ]; then
    current=${releases[0]}
  fi

  jq -n --args '$ARGS.positional | map({version:., stable:(contains("-") | not)})' \
    "${releases[@]}" > "$tmp_root/playground-releases.json"
  if [ -d "$PUBLIC_DIR/playground/dev" ]; then
    jq '. + [{version:"dev", stable:false}]' "$tmp_root/playground-releases.json" > "$tmp_root/playground-with-dev.json"
  else
    cp "$tmp_root/playground-releases.json" "$tmp_root/playground-with-dev.json"
  fi
  if [ -n "$current" ]; then
    jq --arg current "$current" '{current:$current, versions:.}' \
      "$tmp_root/playground-with-dev.json" > "$versions_file"
  else
    jq '{versions:.}' "$tmp_root/playground-with-dev.json" > "$versions_file"
  fi

  local landing=${current:-dev}
  [ -d "$PUBLIC_DIR/playground/$landing" ] || { echo "missing playground landing target: $landing" >&2; return 1; }
  cat > "$PUBLIC_DIR/playground/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>HAPTIC Playground</title>
<script>location.replace('./${landing}/' + location.search + location.hash)</script>
<meta http-equiv="refresh" content="0; url=./${landing}/">
<link rel="canonical" href="./${landing}/"></head>
<body><p><a href="./${landing}/">HAPTIC Playground &rarr;</a></p></body></html>
HTML
}

deploy_doc_site() {
  local name=$1
  local source=$2
  local build_dir="$tmp_root/docs-$name"
  local destination="$PUBLIC_DIR/$name/$VERSION"
  local canonical=$VERSION
  local -a releases=()

  if [ "$VERSION" != dev ] && [ -s "$destination/release-identity.json" ]; then
    [ -s "$destination/index.html" ] || { echo "$destination is incomplete" >&2; return 1; }
    identity_matches "$destination/release-identity.json" || {
      echo "$destination belongs to another source" >&2
      return 1
    }
    echo "Keeping existing immutable $destination"
    update_docs_versions "$name"
    return 0
  fi

  mapfile -t releases < <(collect_versions "$name")
  local release
  for release in "${releases[@]}"; do
    if [[ "$release" != *-* ]]; then
      canonical=latest
      break
    fi
  done

  DOCS_SITE_URL="https://haproxy-haptic.org/${name}/${canonical}/" mkdocs build -f "$source/mkdocs.yml" -d "$build_dir"
  write_identity "$build_dir/release-identity.json"
  if [ "$VERSION" = dev ]; then
    replace_moving_dir "$build_dir" "$PUBLIC_DIR/$name/dev"
  else
    publish_version_dir "$build_dir" "$destination" index.html
  fi
  update_docs_versions "$name"
}

repo_commit=$(git -C "$MAIN_REPO" rev-parse HEAD)
[ "$repo_commit" = "$SOURCE_COMMIT" ] || {
  echo "documentation checkout is $repo_commit, expected $SOURCE_COMMIT" >&2
  exit 1
}

if [ "$MODE" = publish ]; then
  api="${HAPTIC_API_BASE:-https://gitlab.com/api/v4/projects/haproxy-haptic%2Fhaptic}"
  pipeline_json=$(gl_get "$api/pipelines/$SOURCE_PIPELINE")
  jq -e \
    --arg ref "$EXPECTED_REF" \
    --arg commit "$SOURCE_COMMIT" \
    '.ref == $ref and .sha == $commit' <<<"$pipeline_json" >/dev/null || {
    echo "source pipeline $SOURCE_PIPELINE does not match ref $EXPECTED_REF and commit $SOURCE_COMMIT" >&2
    exit 1
  }
  page=1
  job_ids=()
  while true; do
    jobs_json=$(gl_get "$api/pipelines/$SOURCE_PIPELINE/jobs?include_retried=false&per_page=100&page=$page")
    mapfile -t page_job_ids < <(jq -r --arg name "$SOURCE_JOB_NAME" \
      '.[] | select(.name == $name and .status == "success") | .id' <<<"$jobs_json")
    job_ids+=("${page_job_ids[@]}")
    [ "$(jq 'length' <<<"$jobs_json")" -eq 100 ] || break
    page=$((page + 1))
    [ "$page" -le 100 ] || { echo "source pipeline job list exceeds 10000 entries" >&2; exit 1; }
  done
  [ "${#job_ids[@]}" -eq 1 ] || {
    echo "pipeline $SOURCE_PIPELINE does not have exactly one successful $SOURCE_JOB_NAME job" >&2
    exit 1
  }
  SOURCE_JOB=${job_ids[0]}
  job_json=$(gl_get "$api/jobs/$SOURCE_JOB")
  jq -e \
    --arg name "$SOURCE_JOB_NAME" \
    --arg status success \
    --arg ref "$EXPECTED_REF" \
    --arg commit "$SOURCE_COMMIT" \
    --argjson pipeline "$SOURCE_PIPELINE" \
    --argjson job "$SOURCE_JOB" \
    '.id == $job and .name == $name and .status == $status and .ref == $ref and .commit.id == $commit and .pipeline.id == $pipeline' \
    <<<"$job_json" >/dev/null || {
    echo "playground job $SOURCE_JOB does not match pipeline $SOURCE_PIPELINE, ref $EXPECTED_REF, and commit $SOURCE_COMMIT" >&2
    exit 1
  }

  playground_source="$PUBLIC_DIR/playground/$VERSION"
  reuse_playground=false
  if [ "$VERSION" != dev ] && [ -s "$playground_source/release-identity.json" ]; then
    reuse_playground=true
    for required in index.html playground.wasm schemas.json release-identity.json; do
      [ -s "$playground_source/$required" ] || reuse_playground=false
    done
    identity_matches "$playground_source/release-identity.json" || reuse_playground=false
  fi
  if [ "$reuse_playground" = true ]; then
    echo "Using the existing exact playground mirror for retry $VERSION"
  else
    artifact="$tmp_root/playground.zip"
    gl_download "$api/jobs/$SOURCE_JOB/artifacts" "$artifact" || {
      echo "playground artifact download failed for exact job $SOURCE_JOB" >&2
      exit 1
    }
    unzip -q "$artifact" -d "$tmp_root/playground-artifact"
    playground_source="$tmp_root/playground-artifact/public/playground/$VERSION"
    for required in index.html playground.wasm schemas.json release-identity.json; do
      [ -s "$playground_source/$required" ] || {
        echo "playground job $SOURCE_JOB is missing public/playground/$VERSION/$required" >&2
        exit 1
      }
    done
    identity_matches "$playground_source/release-identity.json" || {
      echo "playground job $SOURCE_JOB carries stale release identity" >&2
      exit 1
    }
  fi
fi

cp "$MAIN_REPO/docs/shared/colors.css" "$MAIN_REPO/docs/landing/docs/stylesheets/"
merged_docs=false
if [ -d "$MAIN_REPO/docs/site" ]; then
  merged_docs=true
  cp "$MAIN_REPO/docs/shared/colors.css" "$MAIN_REPO/docs/site/docs/stylesheets/"
else
  cp "$MAIN_REPO/docs/shared/colors.css" "$MAIN_REPO/docs/controller/docs/stylesheets/"
  cp "$MAIN_REPO/docs/shared/colors.css" "$MAIN_REPO/charts/haptic/docs/stylesheets/"
fi

if [ "$VERSION" = dev ]; then
  landing_dir="$tmp_root/landing"
  mkdocs build -f "$MAIN_REPO/docs/landing/mkdocs.yml" -d "$landing_dir"
  cp -a "$landing_dir/." "$PUBLIC_DIR/"
  mkdir -p "$PUBLIC_DIR/shared"
  cp -a "$MAIN_REPO/docs/shared/." "$PUBLIC_DIR/shared/"
else
  [ -s "$PUBLIC_DIR/index.html" ] || { echo "existing landing site is missing" >&2; exit 1; }
  [ -d "$PUBLIC_DIR/shared" ] || { echo "existing shared assets are missing" >&2; exit 1; }
fi

if [ "$merged_docs" = true ]; then
  deploy_doc_site docs "$MAIN_REPO/docs/site"
  rm -rf -- "$PUBLIC_DIR/controller/latest" "$PUBLIC_DIR/helm-chart/latest"
  legacy_target=/docs/dev
  [ -e "$PUBLIC_DIR/docs/latest" ] && legacy_target=/docs/latest
  if [ -f "$PUBLIC_DIR/robots.txt" ]; then
    sed -i -E "s#/docs/(dev|latest)/sitemap.xml#${legacy_target}/sitemap.xml#" "$PUBLIC_DIR/robots.txt"
  fi
  cat > "$PUBLIC_DIR/_redirects" <<REDIRECTS
/controller/latest/* ${legacy_target}/:splat 301
/helm-chart/latest/* ${legacy_target}/:splat 301
/controller/latest ${legacy_target}/ 301
/helm-chart/latest ${legacy_target}/ 301
/controller/ /docs/ 301
/helm-chart/ /docs/ 301
REDIRECTS
else
  deploy_doc_site controller "$MAIN_REPO/docs/controller"
  deploy_doc_site helm-chart "$MAIN_REPO/charts/haptic"
fi

if [ "$MODE" = preview ]; then
  echo "Preview kept the production playground unchanged"
else
  if [ "$VERSION" = dev ]; then
    replace_moving_dir "$playground_source" "$PUBLIC_DIR/playground/dev"
  else
    publish_version_dir "$playground_source" "$PUBLIC_DIR/playground/$VERSION" index.html
  fi
  update_playground_versions
fi

echo "Deployed $MODE docs $VERSION from $SOURCE_COMMIT (pipeline $SOURCE_PIPELINE, job $SOURCE_JOB)"
