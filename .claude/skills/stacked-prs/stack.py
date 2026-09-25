#!/usr/bin/env python3
# Copyright (c) Mysten Labs, Inc.
# SPDX-License-Identifier: Apache-2.0
"""Split one branch's changes into a two-layer pull-request stack.

Layers, bottom to top:
  code  everything that builds, runs, or is executed: Move sources, tests and
        manifests, Rust, TypeScript, Python, scripts, lockfiles, fixtures.
  docs  prose and configuration nothing compiles: Markdown, package docs,
        predeploy registers and evidence, agent context (.claude/, CLAUDE.md,
        AGENTS.md) and GitHub configuration (.github/).

Subcommands:
  plan    print each changed file under its layer
  apply   stage one layer's changes (adds, edits, deletes, modes) onto HEAD
  verify  check that HEAD's tree equals the source's tree

Renames are split into a delete and an add so each side is classified by its own
path. Pass --code PATTERN (repeatable) to force matching docs-layer paths into
the code layer, for a doc or config file the code layer cannot pass CI without.
"""

import argparse
import fnmatch
import subprocess
import sys

# First match wins; anything unmatched is code. fnmatch's `*` also matches `/`.
DOCS_PATTERNS = [
    "*.md",
    ".claude/*",
    ".github/*",
    "packages/*/docs/*",
    "packages/*/predeploy/*",
]


def git(*args, stdin=None, capture=True):
    result = subprocess.run(
        ["git", *args],
        input=stdin,
        capture_output=capture,
        check=False,
    )
    if result.returncode != 0:
        err = result.stderr.decode() if capture and result.stderr else ""
        sys.exit(f"git {' '.join(args)} failed: {err.strip()}")
    return result.stdout


def changed_paths(base, source):
    out = git("diff", "--name-only", "--no-renames", "-z", f"{base}...{source}")
    return [p for p in out.decode().split("\0") if p]


def layer_of(path, code_overrides):
    if any(fnmatch.fnmatch(path, pat) for pat in code_overrides):
        return "code"
    if any(fnmatch.fnmatch(path, pat) for pat in DOCS_PATTERNS):
        return "docs"
    return "code"


def split(base, source, code_overrides):
    layers = {"code": [], "docs": []}
    for path in changed_paths(base, source):
        layers[layer_of(path, code_overrides)].append(path)
    return layers


def cmd_plan(args):
    layers = split(args.base, args.source, args.code)
    for name in ("code", "docs"):
        paths = layers[name]
        print(f"{name} ({len(paths)} files)")
        for path in paths:
            print(f"  {path}")
    empty = [name for name in ("code", "docs") if not layers[name]]
    if empty:
        print(f"single layer ({', '.join(empty)} is empty): open one pull request, no stack")


def cmd_apply(args):
    paths = split(args.base, args.source, args.code)[args.layer]
    if not paths:
        print(f"{args.layer} layer is empty; nothing to apply")
        return
    root = git("rev-parse", "--show-toplevel").decode().strip()
    # The merge base, not the base tip, is what the source's diff is taken against.
    merge_base = git("merge-base", args.base, args.source).decode().strip()
    patch = git("-C", root, "diff", "--binary", "--no-renames", merge_base, args.source, "--", *paths)
    # --3way stages the result and falls back to a three-way merge, leaving conflict
    # markers to resolve, if the base has moved on since the source branched.
    git("-C", root, "apply", "--3way", "--whitespace=nowarn", stdin=patch)
    print(f"staged {len(paths)} {args.layer}-layer files; commit them")


def cmd_verify(args):
    diff = [p for p in git("diff", "--name-only", "-z", args.source, "HEAD").decode().split("\0") if p]
    if diff:
        print("HEAD differs from the source in:")
        for path in diff:
            print(f"  {path}")
        sys.exit(1)
    print("OK: the stack's top tree equals the source tree")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "apply", "verify"):
        p = sub.add_parser(name)
        if name == "apply":
            p.add_argument("layer", choices=["code", "docs"])
        if name != "verify":
            p.add_argument("--base", default="origin/main")
            p.add_argument("--code", action="append", default=[], metavar="PATTERN")
        p.add_argument("--source", required=True, help="branch or commit holding the full change")
    args = parser.parse_args()
    {"plan": cmd_plan, "apply": cmd_apply, "verify": cmd_verify}[args.command](args)


if __name__ == "__main__":
    main()
