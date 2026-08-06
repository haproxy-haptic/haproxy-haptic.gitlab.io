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
project_api="${api_url}/projects/${project_id}"
publisher_prefix=pages-publisher-
page=1
trusted_job=0
legacy_job=0
publisher_job_seen=false
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

api_get() {
  curl --globoff -sSf --header "JOB-TOKEN: ${job_token}" "$1"
}

while [ "$page" -le 100 ]; do
  jobs=$(api_get "${project_api}/jobs?scope[]=success&per_page=100&page=${page}")
  while IFS=$'\t' read -r job_id job_ref job_commit; do
    [[ "$job_id" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$job_commit" =~ ^[0-9a-f]{40}$ ]] || continue
    if [[ "$job_ref" == "${publisher_prefix}"* ]]; then
      publisher_job_seen=true
      suffix=${job_ref#"$publisher_prefix"}
      [ "$suffix" = "$job_commit" ] || continue
      encoded_ref=$(jq -nr --arg value "$job_ref" '$value | @uri')
      if ! tag=$(api_get "${project_api}/repository/tags/${encoded_ref}"); then
        continue
      fi
      if jq -e --arg ref "$job_ref" --arg commit "$job_commit" \
        '.name == $ref and .protected == true and .commit.id == $commit' <<<"$tag" >/dev/null; then
        if [ "$job_id" -gt "$trusted_job" ]; then
          trusted_job=$job_id
        fi
      fi
    elif [ "$job_ref" = main ] && [ "$job_id" -gt "$legacy_job" ]; then
      legacy_job=$job_id
    fi
  done < <(jq -r '.[] | select(.name == "pages") | [.id, .ref, .commit.id] | @tsv' <<<"$jobs")

  job_count=$(jq 'length' <<<"$jobs")
  [ "$job_count" -eq 100 ] || break
  if [ "$page" -eq 100 ]; then
    echo "Pages job history exceeds 10000 entries" >&2
    exit 1
  fi
  page=$((page + 1))
done

source_job=$trusted_job
if [ "$source_job" -eq 0 ]; then
  if [ "$publisher_job_seen" = true ]; then
    echo "Publisher-tagged Pages jobs exist, but none has a live protected commit-bound tag" >&2
    exit 1
  fi
  source_job=$legacy_job
fi
if [ "$source_job" -eq 0 ]; then
  echo "No trusted previous Pages artifact exists" >&2
  exit 1
fi

archive="$tmp_root/pages-artifact.zip"
curl -sSfL --output "$archive" --header "JOB-TOKEN: ${job_token}" \
  "${project_api}/jobs/${source_job}/artifacts"
extract="$tmp_root/extract"
mkdir "$extract"
unzip -q "$archive" -d "$extract"
if [ ! -d "$extract/public" ]; then
  echo "Pages job ${source_job} has no public directory" >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
rm -rf -- "$destination"
mv "$extract/public" "$destination"
echo "Restored Pages artifact from job ${source_job}"
