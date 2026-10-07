#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

publisher_root="$test_root/publisher"
mkdir -p "$publisher_root/scripts"
cp "$repo_root/scripts/"{deploy-docs.sh,semver-order.py,site_versions.py,apply-playground-ui-patches.py,compact_assets.py} "$publisher_root/scripts/"

ordered=$(printf '%s\n' 0.9.0 0.10.0 1.0.0-alpha.2 1.0.0-alpha.10 1.0.0-rc.1 1.0.0 |
  "$repo_root/scripts/semver-order.py")
expected=$'1.0.0\n1.0.0-rc.1\n1.0.0-alpha.10\n1.0.0-alpha.2\n0.10.0\n0.9.0'
[ "$ordered" = "$expected" ]

mkdir -p "$test_root/bin" "$test_root/main-repo/docs/shared" \
  "$test_root/main-repo/docs/landing/docs/stylesheets" \
  "$test_root/main-repo/docs/site/docs/stylesheets"
printf 'body{}\n' > "$test_root/main-repo/docs/shared/colors.css"
printf 'shared\n' > "$test_root/main-repo/docs/shared/playground-embed.js"
printf 'site_name: landing\n' > "$test_root/main-repo/docs/landing/mkdocs.yml"
printf 'site_name: docs\n' > "$test_root/main-repo/docs/site/mkdocs.yml"

git -C "$test_root/main-repo" init -q
git -C "$test_root/main-repo" config user.name test
git -C "$test_root/main-repo" config user.email test@example.com
git -C "$test_root/main-repo" add .
git -C "$test_root/main-repo" commit -qm fixture
source_commit=$(git -C "$test_root/main-repo" rev-parse HEAD)

cat > "$test_root/bin/mkdocs" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) destination=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$destination" ]
mkdir -p "$destination"
mkdir -p "$destination/assets"
printf '%2048s' "${FAKE_DOC_ASSET:-original}" > "$destination/assets/shared.js"
printf '<html>fixture</html>\n' > "$destination/index.html"
printf 'Sitemap: https://haproxy-haptic.org/docs/dev/sitemap.xml\n' > "$destination/robots.txt"
FAKE

cat > "$test_root/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) output=$2; shift 2 ;;
    --header|-H) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == */pipelines/"$FAKE_PIPELINE" ]]; then
  printf '{"id":%s,"ref":"%s","sha":"%s"}\n' "$FAKE_PIPELINE" "$FAKE_REF" "$FAKE_COMMIT"
  exit 0
fi
if [[ "$url" == */pipelines/"$FAKE_PIPELINE"/jobs* ]]; then
  if [ "${FAKE_PAD_FIRST_PAGE:-0}" = 1 ] && [[ "$url" == *'&page=1' ]]; then
    jq -n '[range(0; 100) | {id:., name:"another-job", status:"success"}]'
    exit 0
  fi
  printf '[{"id":%s,"name":"%s","status":"success","ref":"%s","commit":{"id":"%s"},"pipeline":{"id":%s}}]\n' \
    "$FAKE_JOB" "${FAKE_JOB_NAME:-build-playground-wasm}" "$FAKE_REF" \
    "${FAKE_JOB_COMMIT:-$FAKE_COMMIT}" "$FAKE_PIPELINE"
  exit 0
fi
if [[ "$url" == */jobs/"$FAKE_JOB"/artifacts ]]; then
  [ "${FAKE_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
  cp "$FAKE_ARTIFACT" "$output"
  exit 0
fi
exit 22
FAKE
chmod +x "$test_root/bin/mkdocs" "$test_root/bin/curl"

make_artifact() {
  local version=$1
  local pipeline=$2
  local job=$3
  local marker_commit=${4:-$source_commit}
  local source="$test_root/artifact-source"
  rm -rf -- "$source"
  mkdir -p "$source/public/playground/$version"
  printf '<html data-version="%s"></html>\n' "$version" > "$source/public/playground/$version/index.html"
  printf 'wasm\n' > "$source/public/playground/$version/playground.wasm"
  printf '{}\n' > "$source/public/playground/$version/schemas.json"
  printf '{"version":"%s","commit":"%s","pipeline":"%s","job":"%s"}\n' \
    "$version" "$marker_commit" "$pipeline" "$job" > "$source/public/playground/$version/release-identity.json"
  FAKE_ARTIFACT="$test_root/playground-$version-$job.zip"
  export FAKE_ARTIFACT
  python3 - "$source" "$FAKE_ARTIFACT" <<'PY'
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w") as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(source))
PY
}

deploy() {
  local public=$1
  local version=$2
  local pipeline=$3
  local job=$4
  export FAKE_COMMIT=$source_commit FAKE_PIPELINE=$pipeline FAKE_JOB=$job
  if [ "$version" = dev ]; then export FAKE_REF=main; else export FAKE_REF="v$version"; fi
  PATH="$test_root/bin:$PATH" \
    CI_JOB_TOKEN=test \
    HAPTIC_RELEASE_COMMIT_SHA="$source_commit" \
    HAPTIC_RELEASE_PIPELINE_ID="$pipeline" \
    HAPTIC_RELEASE_PLAYGROUND_JOB_NAME=build-playground-wasm \
    "$publisher_root/scripts/deploy-docs.sh" "$version" "$test_root/main-repo" "$public"
}

snapshot() {
  local public=$1
  {
    find "$public" -type f -print0 | sort -z | xargs -0 sha256sum
    find "$public" -type l -printf '%p -> %l\n' | sort
  }
}

public="$test_root/public"
make_artifact dev 100 1000
deploy "$public" dev 100 1000 >/dev/null
cp -a "$public" "$test_root/preview-public"
preview_playground=$(snapshot "$test_root/preview-public/playground")
PATH="$test_root/bin:$PATH" \
  CI_COMMIT_SHA="$source_commit" CI_PIPELINE_ID=600 CI_JOB_ID=6000 \
  "$repo_root/scripts/deploy-docs.sh" dev "$test_root/main-repo" \
  "$test_root/preview-public" preview >/dev/null
[ "$preview_playground" = "$(snapshot "$test_root/preview-public/playground")" ]
jq -e --arg commit "$source_commit" \
  '.version == "dev" and .commit == $commit and .pipeline == "600" and .job == "6000"' \
  "$test_root/preview-public/docs/dev/release-identity.json" >/dev/null
make_artifact 0.2.0 200 2000
deploy "$public" 0.2.0 200 2000 >/dev/null
make_artifact 0.3.0-rc.1 300 3000
export FAKE_PAD_FIRST_PAGE=1
deploy "$public" 0.3.0-rc.1 300 3000 >/dev/null
unset FAKE_PAD_FIRST_PAGE
[ "$(readlink "$public/docs/latest")" = 0.2.0 ]
[ "$(jq -r .current "$public/playground/versions.json")" = 0.2.0 ]
make_artifact 0.3.0 301 3001
deploy "$public" 0.3.0 301 3001 >/dev/null
[ "$(readlink "$public/docs/latest")" = 0.3.0 ]
[ "$(jq -r .current "$public/playground/versions.json")" = 0.3.0 ]
for version in 0.2.0 0.3.0; do
  [ -d "$public/docs/$version" ]
  [ -d "$public/playground/$version" ]
done

[ ! -e "$public/docs/0.3.0-rc.1" ]
[ ! -e "$public/playground/0.3.0-rc.1" ]

before_retired_retry=$(snapshot "$public")
make_artifact 0.3.0-rc.1 300 3000
deploy "$public" 0.3.0-rc.1 300 3000 >/dev/null
[ "$before_retired_retry" = "$(snapshot "$public")" ]

mkdir -p "$public/controller/0.1.0" "$public/helm-chart/v0.1.0"
printf 'original controller docs\n' > "$public/controller/0.1.0/index.html"
printf 'original chart docs\n' > "$public/helm-chart/v0.1.0/index.html"
legacy_controller=$(snapshot "$public/controller/0.1.0")
legacy_chart=$(snapshot "$public/helm-chart/v0.1.0")
make_artifact 0.3.0 301 3001
deploy "$public" 0.3.0 301 3001 >/dev/null
[ "$legacy_controller" = "$(snapshot "$public/controller/0.1.0")" ]
[ "$legacy_chart" = "$(snapshot "$public/helm-chart/v0.1.0")" ]
jq -e 'map(.version) == ["0.3.0", "0.2.0", "0.1.0", "dev"]' "$public/docs/versions.json" >/dev/null
[ -s "$public/docs/0.1.0/index.html" ]
[ ! -e "$public/playground/0.1.0" ]

before_retry=$(snapshot "$public")
make_artifact 0.2.0 200 2000
export FAKE_DOWNLOAD_FAIL=1
deploy "$public" 0.2.0 200 2000 >/dev/null
unset FAKE_DOWNLOAD_FAIL
after_retry=$(snapshot "$public")
[ "$before_retry" = "$after_retry" ]
[ "$(readlink "$public/docs/latest")" = 0.3.0 ]
[ "$(jq -r .current "$public/playground/versions.json")" = 0.3.0 ]

cp -a "$public" "$test_root/conflict-public"
jq '.pipeline = "999"' "$test_root/conflict-public/docs/0.2.0/release-identity.json" > "$test_root/conflict.json"
mv "$test_root/conflict.json" "$test_root/conflict-public/docs/0.2.0/release-identity.json"
if deploy "$test_root/conflict-public" 0.2.0 200 2000 >/dev/null 2>&1; then
  echo "conflicting immutable docs retry was accepted" >&2
  exit 1
fi

before_failure=$(snapshot "$public")
make_artifact 0.4.0 400 4000 0000000000000000000000000000000000000000
if deploy "$public" 0.4.0 400 4000 >/dev/null 2>&1; then
  echo "stale playground identity was accepted" >&2
  exit 1
fi
[ "$before_failure" = "$(snapshot "$public")" ]

make_artifact 0.4.0 400 4000
export FAKE_DOWNLOAD_FAIL=1
if deploy "$public" 0.4.0 400 4000 >/dev/null 2>&1; then
  echo "missing playground artifact was accepted" >&2
  exit 1
fi
unset FAKE_DOWNLOAD_FAIL
[ "$before_failure" = "$(snapshot "$public")" ]

export FAKE_JOB_NAME=another-job
if deploy "$public" 0.4.0 400 4000 >/dev/null 2>&1; then
  echo "wrong playground job was accepted" >&2
  exit 1
fi
unset FAKE_JOB_NAME
[ "$before_failure" = "$(snapshot "$public")" ]

prerelease_public="$test_root/prerelease-public"
make_artifact dev 500 5000
deploy "$prerelease_public" dev 500 5000 >/dev/null
make_artifact 1.0.0-alpha.1 501 5001
deploy "$prerelease_public" 1.0.0-alpha.1 501 5001 >/dev/null
make_artifact 1.0.0-rc.1 502 5002
deploy "$prerelease_public" 1.0.0-rc.1 502 5002 >/dev/null
[ "$(jq -r .current "$prerelease_public/playground/versions.json")" = 1.0.0-rc.1 ]
[ ! -e "$prerelease_public/docs/latest" ]

jq -e --arg commit "$source_commit" \
  '.version == "0.3.0" and .commit == $commit and .pipeline == "301" and .job == "3001"' \
  "$public/docs/0.3.0/release-identity.json" >/dev/null
jq -e --arg commit "$source_commit" \
  '.version == "0.3.0" and .commit == $commit and .pipeline == "301" and .job == "3001"' \
  "$public/playground/0.3.0/release-identity.json" >/dev/null

python3 - "$public/playground/0.2.0" "$publisher_root/playground-ui-patches" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

bundle, patches = map(Path, sys.argv[1:])
patches.mkdir()
old = (bundle / 'index.html').read_text()
new = old.replace('</html>', '<!-- UI fix --></html>')
manifest = {
    'release': json.loads((bundle / 'release-identity.json').read_text()),
    'revision': 'fixture-1',
    'source': {'commit': 'b' * 40},
    'release_files': {p.relative_to(bundle).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in bundle.rglob('*') if p.is_file()},
    'files': {'index.html': {'sha256': hashlib.sha256(new.encode()).hexdigest(),
                            'replacements': [{'old': old, 'new': new}]}},
}
(patches / '0.2.0.json').write_text(json.dumps(manifest))
PY
make_artifact 0.2.0 200 2000
deploy "$public" 0.2.0 200 2000 >/dev/null
[ -s "$public/playground/0.2.0/ui-revision.json" ]
patched_release=$(snapshot "$public/playground/0.2.0")
deploy "$public" 0.2.0 200 2000 >/dev/null
[ "$patched_release" = "$(snapshot "$public/playground/0.2.0")" ]
make_artifact dev 700 7000
deploy "$public" dev 700 7000 >/dev/null
[ "$patched_release" = "$(snapshot "$public/playground/0.2.0")" ]
[ "$(jq -r .current "$public/playground/versions.json")" = 0.3.0 ]

original_asset=$(sha256sum < "$public/docs/0.3.0/assets/shared.js")
[ -L "$public/assets/shared.js" ]
make_artifact dev 701 7001
export FAKE_DOC_ASSET=changed
deploy "$public" dev 701 7001 >/dev/null
unset FAKE_DOC_ASSET
[ "$original_asset" = "$(sha256sum < "$public/docs/0.3.0/assets/shared.js")" ]
[ "$original_asset" != "$(sha256sum < "$public/assets/shared.js")" ]
[ "$(sha256sum < "$public/assets/shared.js")" = "$(sha256sum < "$public/docs/dev/assets/shared.js")" ]

echo "Pages provenance, aliases, preservation, retries, and UI corrections passed"
