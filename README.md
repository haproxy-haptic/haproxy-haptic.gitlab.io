# haproxy-haptic.gitlab.io

GitLab Pages site for [HAPTIC](https://gitlab.com/haproxy-haptic/haptic) (HAProxy Template Ingress Controller) documentation, published at [haproxy-haptic.org](https://haproxy-haptic.org).

## Overview

This repository hosts the CI pipeline that builds and publishes versioned MkDocs documentation for the HAPTIC project. The documentation source lives in the [main haptic repo](https://gitlab.com/haproxy-haptic/haptic); this repo is responsible only for building and serving it via GitLab Pages.

## How it works

The pipeline runs in two scenarios:

- **Triggered by the main haptic repo** — the source pipeline supplies the documentation version, exact commit, exact pipeline, and playground job name. The publisher resolves and checks that pipeline's successful job before it changes the Pages artifact.
- **Direct push or merge request** — runs the deterministic publisher tests without changing the live site.

The Pages job restores the artifact for its protected, commit-named publisher tag and preserves every versioned directory. A new publisher tag uses one explicit predecessor ref for its first publication, then the caller pins that tag as its own predecessor. An API pipeline can seed a protected publisher tag from one exact job artifact and SHA-256 digest without publishing new site content. A missing artifact fails the job instead of replacing the site with one version. Stable `latest` and playground `current` select the highest published semantic version, so retrying an older release can't move either alias backward.

Each published documentation and playground directory contains `release-identity.json` with the source version, commit, pipeline, and playground job. Documentation and rendering assets are immutable; an exact retry is a no-op, and a conflicting retry fails.

## Playground UI corrections

Reviewed manifests in `playground-ui-patches/` can correct a released playground's `index.html`. Each manifest pins the original release identity, every original file's SHA-256 digest, the exact replacements, their resulting digest, and the HAPTIC source commit. All affected bundles are validated before any change. Changed rendering assets, unexpected files, symlinks, and unknown prior UI revisions fail publication.

The publisher writes `ui-revision.json` alongside the unchanged `release-identity.json`. The former identifies the corrected browser interface; the latter identifies the original rendering bundle. Normal deployments verify and preserve these corrections.

Pages replaces the complete site artifact on each publication. A corrupted historical bundle therefore blocks publication: accepting it would republish that corruption along with the new version. Correct the corrupted artifact or manifest before retrying; validation failures are not warnings.

To publish a reviewed correction, run an API pipeline on the protected `pages-publisher-<commit>` tag with `PLAYGROUND_UI_HOTFIX_VERSION` set to the existing release version and `PAGES_ARTIFACT_FALLBACK_REF` set to the current publisher tag. The pipeline runs the publisher tests, restores the existing site, applies the correction, and publishes Pages without rebuilding controller artifacts or documentation. After the first publication, use the new tag as its own fallback and update the HAPTIC publisher pins so subsequent deployments use it.

Run the publisher tests with:

```bash
make test
```
