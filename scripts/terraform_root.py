#!/usr/bin/env python3
"""Resolve an allowlisted Terraform stack name to its root directory."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOTS = {
    "foundation": Path("envs/staging/foundation"),
    "platform": Path("envs/staging/platform"),
    "hml": Path("envs/hml"),
    "production": Path("envs/production"),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stack", choices=ROOTS)
    stack = parser.parse_args().stack
    root = ROOTS[stack]
    if not root.is_dir():
        print(f"::error::Terraform root does not exist: {root}", file=sys.stderr)
        return 1
    print(root.as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
