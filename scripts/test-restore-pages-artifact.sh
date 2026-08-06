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
write_status=false
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --write-out) write_status=true; shift 2 ;;
    --header) shift 2 ;;
    -s|-S|-f|-L|-sSf|-sSL) shift ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == *'/repository/tags/'* ]]; then
  ref=${url##*/}
  protected=${FAKE_TAG_PROTECTED:-true}
  printf '{"name":"%s","protected":%s,"commit":{"id":"%s"}}\n' \
    "$ref" "$protected" "${ref#pages-publisher-}"
  exit 0
fi
if [[ "$url" == *'/jobs/artifacts/'* ]]; then
  ref=${url#*/jobs/artifacts/}
  ref=${ref%%/*}
  status=404
  if [ "$ref" = "$FAKE_CURRENT_REF" ]; then
    status=${FAKE_CURRENT_STATUS:-200}
  elif [ "$ref" = "$FAKE_FALLBACK_REF" ]; then
    status=${FAKE_FALLBACK_STATUS:-200}
  fi
  if [ "$status" = 200 ]; then
    cp "$FAKE_ARCHIVE" "$output"
  fi
  [ "$write_status" = true ] && printf '%s' "$status"
  exit 0
fi
if [[ "$url" == *'/jobs/'*'/artifacts' ]]; then
  status=${FAKE_BOOTSTRAP_STATUS:-200}
  if [ "$status" = 200 ]; then
    cp "$FAKE_ARCHIVE" "$output"
  fi
  [ "$write_status" = true ] && printf '%s' "$status"
  exit 0
fi
exit 22
FAKE
chmod +x "$test_root/bin/curl"

commit=0123456789abcdef0123456789abcdef01234567
current_ref="pages-publisher-$commit"
fallback_ref=$current_ref
bootstrap_sha256=$(sha256sum "$test_root/pages.zip" | awk '{print $1}')

run_restore() {
  local destination=$1
  PATH="$test_root/bin:$PATH" \
    CI_API_V4_URL=https://gitlab.example/api/v4 \
    CI_PROJECT_ID=1 CI_JOB_TOKEN=test \
    CI_COMMIT_REF_NAME="$current_ref" CI_COMMIT_SHA="$commit" \
    PAGES_ARTIFACT_FALLBACK_REF="$fallback_ref" \
    FAKE_CURRENT_REF="$current_ref" FAKE_FALLBACK_REF="$fallback_ref" \
    FAKE_ARCHIVE="$test_root/pages.zip" \
    "$repo_root/scripts/restore-pages-artifact.sh" "$destination"
}

run_restore "$test_root/current" >/dev/null
[ "$(cat "$test_root/current/version.txt")" = preserved ]

export FAKE_CURRENT_STATUS=404
PAGES_BOOTSTRAP_JOB_ID=123 \
  PAGES_BOOTSTRAP_ARTIFACT_SHA256="$bootstrap_sha256" \
  run_restore "$test_root/bootstrap" >/dev/null
[ "$(cat "$test_root/bootstrap/version.txt")" = preserved ]

if run_restore "$test_root/missing" >/dev/null 2>&1; then
  echo "missing current artifact was accepted without a bootstrap" >&2
  exit 1
fi

if PAGES_BOOTSTRAP_JOB_ID=123 \
  PAGES_BOOTSTRAP_ARTIFACT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  run_restore "$test_root/wrong-hash" >/dev/null 2>&1; then
  echo "bootstrap artifact with the wrong digest was accepted" >&2
  exit 1
fi

predecessor_commit=89abcdef0123456789abcdef0123456789abcdef
fallback_ref="pages-publisher-$predecessor_commit"
run_restore "$test_root/predecessor" >/dev/null
[ "$(cat "$test_root/predecessor/version.txt")" = preserved ]
fallback_ref=$current_ref

export FAKE_CURRENT_STATUS=500
if run_restore "$test_root/server-error" >/dev/null 2>&1; then
  echo "non-404 artifact failure used the predecessor" >&2
  exit 1
fi
unset FAKE_CURRENT_STATUS

export FAKE_TAG_PROTECTED=false
if run_restore "$test_root/unprotected" >/dev/null 2>&1; then
  echo "unprotected publisher ref was accepted" >&2
  exit 1
fi
unset FAKE_TAG_PROTECTED

current_ref=main
if run_restore "$test_root/unbound" >/dev/null 2>&1; then
  echo "publisher pipeline not bound to its commit tag was accepted" >&2
  exit 1
fi

echo "Pages artifact restoration follows one protected publisher lineage"
