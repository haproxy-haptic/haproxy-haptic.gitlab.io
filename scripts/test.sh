#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash -n scripts/*.sh
bash scripts/test-deploy-docs.sh
bash scripts/test-restore-pages-artifact.sh
python3 -B -m unittest discover -s scripts -p 'test_playground_ui_patches.py'
