# haproxy-haptic.gitlab.io

GitLab Pages site for [HAPTIC](https://gitlab.com/haproxy-haptic/haptic) (HAProxy Template Ingress Controller) documentation, published at [haproxy-haptic.org](https://haproxy-haptic.org).

## Overview

This repository hosts the CI pipeline that builds and publishes versioned MkDocs documentation for the HAPTIC project. The documentation source lives in the [main haptic repo](https://gitlab.com/haproxy-haptic/haptic); this repo is responsible only for building and serving it via GitLab Pages.

## How it works

The pipeline runs in two scenarios:

- **Triggered by the main haptic repo** — the source pipeline supplies the documentation version, exact commit, exact pipeline, and playground job name. The publisher resolves and checks that pipeline's successful job before it changes the Pages artifact.
- **Direct push or merge request** — runs the deterministic publisher tests without changing the live site.

The Pages job restores the artifact for its protected, commit-named publisher tag and preserves every versioned directory. A new publisher tag uses one explicit predecessor ref for its first publication, then the caller pins that tag as its own predecessor. The initial migration used one exact job artifact and SHA-256 digest to seed the first tag. A missing artifact fails the job instead of replacing the site with one version. Stable `latest` and playground `current` select the highest published semantic version, so retrying an older release can't move either alias backward.

Each published documentation and playground directory contains `release-identity.json` with the source version, commit, pipeline, and playground job. Release directories are immutable; an exact retry is a no-op, and a conflicting retry fails.

Run the publisher tests with:

```bash
make test
```
