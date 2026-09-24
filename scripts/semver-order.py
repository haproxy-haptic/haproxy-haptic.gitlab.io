#!/usr/bin/env python3

import functools
import sys

from site_versions import compare, parse


try:
    versions = {line.strip() for line in sys.stdin if line.strip()}
    for version in versions:
        parse(version)
    for value in sorted(versions, key=functools.cmp_to_key(compare), reverse=True):
        print(value)
except ValueError as error:
    print(f"invalid semantic version: {error.args[0]}", file=sys.stderr)
    raise SystemExit(1)
