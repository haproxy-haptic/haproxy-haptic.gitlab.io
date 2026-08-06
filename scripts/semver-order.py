#!/usr/bin/env python3

import functools
import re
import sys

pattern = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:alpha|beta|rc)\.[0-9]+))?$")


def parse(version):
    match = pattern.fullmatch(version)
    if not match:
        raise ValueError(version)
    prerelease = match.group(4)
    if prerelease is None:
        pre = None
    else:
        label, number = prerelease.split(".")
        pre = ({"alpha": 0, "beta": 1, "rc": 2}[label], int(number))
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))), pre


def compare(left, right):
    left_core, left_pre = parse(left)
    right_core, right_pre = parse(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        return (left_pre is None) - (right_pre is None)
    return (left_pre > right_pre) - (left_pre < right_pre)


try:
    versions = {line.strip() for line in sys.stdin if line.strip()}
    for value in sorted(versions, key=functools.cmp_to_key(compare), reverse=True):
        print(value)
except ValueError as error:
    print(f"invalid semantic version: {error.args[0]}", file=sys.stderr)
    raise SystemExit(1)
