#!/usr/bin/env bash
# Fixture proof for the contract-keys classification gate.
# Shows the gate failing on an unclassified contract key and passing once classified.
# No network or helm: uses minimal fixture contract + keys files.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$root/charts/jumi/ci/contract-keys-fixture"

python3 - "$fixture" <<'PY'
import re, sys
from pathlib import Path
fixture = Path(sys.argv[1])
contract = (fixture / "contract.md").read_text()

def section(name):
    m = re.search(rf"^### {re.escape(name)}\s*$([\s\S]*?)(?=^### |\n## |\Z)", contract, re.M)
    if not m:
        raise SystemExit(f"fixture contract section {name} not found")
    return m.group(1)

def items(sec, heading):
    m = re.search(rf"^#### {re.escape(heading)}\s*$([\s\S]*?)(?=^#### |\Z)", sec, re.M)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("- `"):
            out.append(line.split("`")[1])
    return [o for o in out if o]

union = set()
for role in ("reviewer", "worker", "control", "job"):
    sec = section(role)
    union |= set(items(sec, "required env")) | set(items(sec, "gitops env")) | set(items(sec, "optional env"))

def classified_keys(path):
    text = Path(path).read_text()
    return set(re.findall(r"^  ([A-Z0-9_]+):\s*$", text, re.M))

without = classified_keys(fixture / "keys-without.yaml")
with_keys = classified_keys(fixture / "keys-with.yaml")

missing_without = sorted(union - without)
if "FAKE_NEW_KEY" not in missing_without:
    raise SystemExit("fixture without classification should report FAKE_NEW_KEY as unclassified")
print(f"fixture fail case ok: unclassified -> {', '.join(missing_without)}")

missing_with = sorted(union - with_keys)
if missing_with:
    raise SystemExit(f"fixture with classification should pass, still missing: {missing_with}")
print("fixture pass case ok: all contract keys classified")
PY
echo "contract-keys fixture test ok"
