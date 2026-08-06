#!/usr/bin/env bash

set -euo pipefail

destination=${1:?public directory required}
case "$destination" in
  /|.|..)
    echo "Refusing unsafe Pages destination: $destination" >&2
    exit 1
    ;;
esac
api_url=${CI_API_V4_URL:?CI_API_V4_URL is required}
project_id=${CI_PROJECT_ID:?CI_PROJECT_ID is required}
job_token=${CI_JOB_TOKEN:?CI_JOB_TOKEN is required}
current_ref=${CI_COMMIT_REF_NAME:?CI_COMMIT_REF_NAME is required}
current_commit=${CI_COMMIT_SHA:?CI_COMMIT_SHA is required}
fallback_ref=${PAGES_ARTIFACT_FALLBACK_REF:?PAGES_ARTIFACT_FALLBACK_REF is required}
bootstrap_job=${PAGES_BOOTSTRAP_JOB_ID:-}
bootstrap_sha256=${PAGES_BOOTSTRAP_ARTIFACT_SHA256:-}
project_api="${api_url}/projects/${project_id}"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT
archive="$tmp_root/pages-artifact.zip"

api_get() {
  curl -sSf --header "JOB-TOKEN: ${job_token}" "$1" 2>/dev/null || curl -sSf "$1"
}

validate_publisher_ref() {
  local ref=$1
  local expected_commit=${ref#pages-publisher-}
  local encoded_ref tag
  [[ "$ref" =~ ^pages-publisher-[0-9a-f]{40}$ ]] || {
    echo "Invalid Pages publisher ref: $ref" >&2
    return 1
  }
  encoded_ref=$(jq -nr --arg value "$ref" '$value | @uri')
  tag=$(api_get "${project_api}/repository/tags/${encoded_ref}")
  jq -e --arg ref "$ref" --arg commit "$expected_commit" \
    '.name == $ref and .protected == true and .commit.id == $commit' <<<"$tag" >/dev/null || {
    echo "Pages publisher ref $ref is not a protected commit-bound tag" >&2
    return 1
  }
}

expected_current_ref="pages-publisher-${current_commit}"
[ "$current_ref" = "$expected_current_ref" ] || {
  echo "Pages pipeline ref $current_ref does not bind commit $current_commit" >&2
  exit 1
}
validate_publisher_ref "$current_ref"
if [ "$fallback_ref" != "$current_ref" ]; then
  validate_publisher_ref "$fallback_ref"
fi

download_ref() {
  local ref=$1
  local encoded_ref status
  encoded_ref=$(jq -nr --arg value "$ref" '$value | @uri')
  if ! status=$(curl -sSL --output "$archive" --write-out '%{http_code}' \
    --header "JOB-TOKEN: ${job_token}" \
    "${project_api}/jobs/artifacts/${encoded_ref}/download?job=pages"); then
    echo "Downloading the Pages artifact for $ref failed" >&2
    return 2
  fi
  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      echo "Downloading the Pages artifact for $ref returned HTTP $status" >&2
      return 2
      ;;
  esac
}

download_bootstrap() {
  local status
  [[ "$bootstrap_job" =~ ^[1-9][0-9]*$ ]] || {
    echo "PAGES_BOOTSTRAP_JOB_ID must identify one exact Pages job" >&2
    return 1
  }
  [[ "$bootstrap_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "PAGES_BOOTSTRAP_ARTIFACT_SHA256 must be a SHA-256 digest" >&2
    return 1
  }
  if ! status=$(curl -sSL --output "$archive" --write-out '%{http_code}' \
    --header "JOB-TOKEN: ${job_token}" \
    "${project_api}/jobs/${bootstrap_job}/artifacts"); then
    echo "Downloading bootstrap Pages artifact job $bootstrap_job failed" >&2
    return 1
  fi
  [ "$status" = 200 ] || {
    echo "Downloading bootstrap Pages artifact job $bootstrap_job returned HTTP $status" >&2
    return 1
  }
  printf '%s  %s\n' "$bootstrap_sha256" "$archive" | sha256sum --check --status || {
    echo "Bootstrap Pages artifact job $bootstrap_job failed its SHA-256 check" >&2
    return 1
  }
}

source_ref=$current_ref
if download_ref "$current_ref"; then
  :
else
  download_status=$?
  [ "$download_status" -eq 1 ] || exit "$download_status"
  if [ "$fallback_ref" != "$current_ref" ]; then
    source_ref=$fallback_ref
    download_ref "$fallback_ref" || {
      echo "The Pages artifact is absent from $current_ref and its predecessor $fallback_ref" >&2
      exit 1
    }
  elif [ -n "$bootstrap_job" ] || [ -n "$bootstrap_sha256" ]; then
    source_ref="bootstrap job $bootstrap_job"
    download_bootstrap
  else
    echo "The Pages artifact is absent from $current_ref" >&2
    exit 1
  fi
fi

extract="$tmp_root/extract"
mkdir "$extract"
unzip -q "$archive" -d "$extract"
if [ ! -d "$extract/public" ]; then
  echo "Pages artifact from $source_ref has no public directory" >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
rm -rf -- "$destination"
mv "$extract/public" "$destination"
echo "Restored Pages artifact from $source_ref"
