#!/usr/bin/env python3
"""Shared contract-keys classification gate.

Single source of truth for parsing the env sections of deploy/contract.md
and charts/jumi/contract-keys.yaml. Imported by the inline Python in
scripts/contract-check.sh (the CI gate) and by
scripts/contract-keys-fixture-test.sh (the fail-then-pass fixture proof),
so the fixture exercises the real parser instead of duplicating it.
"""
from __future__ import annotations

import re

ROLES = ("reviewer", "worker", "control", "job")
ENV_HEADINGS = ("required env", "gitops env", "optional env")
VALID_KINDS = ("value", "extraEnv", "internal")


def section(contract, name):
    # ### <name> ... up to next ### or ## at same/higher level
    m = re.search(rf"^### {re.escape(name)}\s*$([\s\S]*?)(?=^### |\n## |\Z)", contract, re.M)
    if not m:
        raise SystemExit(f"contract section {name} not found")
    return m.group(1)


def items(sec, heading):
    m = re.search(rf"^#### {re.escape(heading)}\s*$([\s\S]*?)(?=^#### |\Z)", sec, re.M)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("- `") and line.endswith("`"):
            out.append(line[3:-1])
        elif line.startswith("- `"):
            out.append(line.split("`")[1])
        elif line.startswith("- "):
            out.append(line[2:].strip().strip("`"))
    # ports are bare numbers like "- `3000`" already handled; also "- 3000"
    return [o for o in out if o]


def contract_union(contract):
    """Every env key named in the required/gitops/optional sections."""
    union = set()
    for role in ROLES:
        sec = section(contract, role)
        for heading in ENV_HEADINGS:
            union |= set(items(sec, heading))
    return union


def parse_classified(keys_text):
    """Minimal stdlib parse: top-level `  KEY:` entries plus their kind/via/components/note lines."""
    classified = {}
    cur = None
    cur_block = []

    def parse_block(lines):
        meta = {"kind": None, "via": None, "components": None, "note": None}
        for l in lines:
            s = l.strip()
            if s.startswith("kind:"):
                meta["kind"] = s.split(":", 1)[1].strip()
            elif s.startswith("via:"):
                meta["via"] = s.split(":", 1)[1].strip()
            elif s.startswith("components:"):
                meta["components"] = s.split(":", 1)[1].strip()
            elif s.startswith("note:"):
                meta["note"] = s.split(":", 1)[1].strip()
        return meta

    for line in keys_text.splitlines():
        m = re.match(r"^  ([A-Z0-9_]+):\s*$", line)
        if m:
            if cur:
                classified[cur] = parse_block(cur_block)
            cur = m.group(1)
            cur_block = []
        elif cur is not None:
            if re.match(r"^[A-Za-z_]", line) and not line.startswith(" ") and not line.startswith("#"):
                classified[cur] = parse_block(cur_block)
                cur = None
                cur_block = []
            else:
                cur_block.append(line)
    if cur:
        classified[cur] = parse_block(cur_block)
    return classified


def check_classification(contract_text, keys_text):
    """Fail (SystemExit) on unclassified keys, unknown kinds, or missing via/components."""
    union = contract_union(contract_text)
    classified = parse_classified(keys_text)

    unclassified = sorted(union - set(classified))
    if unclassified:
        raise SystemExit(
            "unclassified contract key(s): " + ", ".join(unclassified)
            + " — add each to charts/jumi/contract-keys.yaml (value/extraEnv/internal)"
        )

    for key in sorted(classified):
        meta = classified[key]
        if meta["kind"] not in VALID_KINDS:
            raise SystemExit(f"{key}: unknown kind {meta['kind']!r} (want value/extraEnv/internal)")
        if meta["kind"] == "value" and not meta["via"]:
            raise SystemExit(f"{key}: value kind needs a `via:` chart value")
        if meta["kind"] == "extraEnv" and not meta["components"]:
            raise SystemExit(f"{key}: extraEnv kind must name component(s)")
    return union, classified
