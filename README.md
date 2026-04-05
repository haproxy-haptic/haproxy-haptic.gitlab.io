# haproxy-haptic.gitlab.io

GitLab Pages site for [HAPTIC](https://gitlab.com/haproxy-haptic/haptic) (HAProxy Template Ingress Controller) documentation, published at [haproxy-haptic.org](https://haproxy-haptic.org).

## Overview

This repository hosts the CI pipeline that builds and publishes versioned MkDocs documentation for the HAPTIC project. The documentation source lives in the [main haptic repo](https://gitlab.com/haproxy-haptic/haptic); this repo is responsible only for building and serving it via GitLab Pages.

## How it works

The pipeline runs in two scenarios:

- **Triggered by the main haptic repo** — when a release is tagged or docs are updated, the haptic pipeline triggers this one with a `DOC_VERSION` variable (e.g. `v1.2.0`). The pipeline clones the haptic repo at that tag, builds the MkDocs site, and publishes it under a versioned path.
- **Direct push to `main`** — builds `dev` docs from the latest haptic `main` branch.

Existing published versions are preserved across builds by restoring the previous Pages artifact before each new build.
