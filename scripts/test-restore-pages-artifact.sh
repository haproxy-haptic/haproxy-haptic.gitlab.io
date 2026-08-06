#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/artifact/public"
printf 'preserved\n' >"$test_root/artifact/public/version.txt"
python3 - "$test_root/artifact" "$test_root/pages.zip" <<'PY'
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w") as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(source))
PY

cat >"$test_root/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --header) shift 2 ;;
    --globoff|-s|-S|-f|-L|-sSf|-sSfL) shift ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == *'/jobs?'* ]]; then
  printf '%s\n' "$FAKE_JOBS"
  exit 0
fi
if [[ "$url" == *'/repository/tags/'* ]]; then
  ref=${url##*/}
  protected=false
  [ "${FAKE_TAG_PROTECTED:-true}" = true ] && protected=true
  printf '{"name":"%s","protected":%s,"commit":{"id":"%s"}}\n' \
    "$ref" "$protected" "${ref#pages-publisher-}"
  exit 0
fi
if [[ "$url" == *"/jobs/${FAKE_EXPECTED_JOB}/artifacts" ]]; then
  [ "${FAKE_DOWNLOAD_FAIL:-false}" = false ] || exit 22
  cp "$FAKE_ARCHIVE" "$output"
  exit 0
fi
exit 22
FAKE
chmod +x "$test_root/bin/curl"

run_restore() {
  local destination=$1
  PATH="$test_root/bin:$PATH" \
    CI_API_V4_URL=https://gitlab.example/api/v4 \
    CI_PROJECT_ID=1 CI_JOB_TOKEN=test \
    FAKE_ARCHIVE="$test_root/pages.zip" \
    "$repo_root/scripts/restore-pages-artifact.sh" "$destination"
}

commit=0123456789abcdef0123456789abcdef01234567
export FAKE_JOBS="$(jq -nc --arg commit "$commit" '[
  {id: 300, name: "pages", ref: "feature/untrusted", commit: {id: $commit}},
  {id: 250, name: "pages", ref: "main", commit: {id: $commit}},
  {id: 200, name: "pages", ref: ("pages-publisher-" + $commit), commit: {id: $commit}}
]')"
export FAKE_EXPECTED_JOB=200
run_restore "$test_root/trusted" >/dev/null
[ "$(cat "$test_root/trusted/version.txt")" = preserved ]

export FAKE_JOBS="$(jq -nc --arg commit "$commit" '[
  {id: 250, name: "pages", ref: "main", commit: {id: $commit}}
]')"
export FAKE_EXPECTED_JOB=250
run_restore "$test_root/legacy" >/dev/null
[ "$(cat "$test_root/legacy/version.txt")" = preserved ]

export FAKE_JOBS="$(jq -nc --arg commit "$commit" '[
  {id: 250, name: "pages", ref: "main", commit: {id: $commit}},
  {id: 200, name: "pages", ref: ("pages-publisher-" + $commit), commit: {id: $commit}}
]')"
export FAKE_EXPECTED_JOB=200 FAKE_TAG_PROTECTED=false
if run_restore "$test_root/unprotected" >/dev/null 2>&1; then
  echo "unprotected publisher artifact was accepted" >&2
  exit 1
fi
unset FAKE_TAG_PROTECTED

export FAKE_DOWNLOAD_FAIL=true
if run_restore "$test_root/download-failure" >/dev/null 2>&1; then
  echo "artifact download failure was ignored" >&2
  exit 1
fi

echo "Pages artifact restoration accepts only the protected publication chain"
