#!/usr/bin/env bash
# Fixture proof for the contract-keys classification gate.
# Exercises the real parser in scripts/contract_keys.py (the same module
# scripts/contract-check.sh imports): the gate must fail on an unclassified
# contract key and pass once that key is classified.
# No network or helm: minimal fixture contract + keys files.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$root/charts/jumi/ci/contract-keys-fixture"

python3 - "$fixture" "$root/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from pathlib import Path
from contract_keys import check_classification

fixture = Path(sys.argv[1])
contract = (fixture / "contract.md").read_text()

try:
    check_classification(contract, (fixture / "keys-without.yaml").read_text())
except SystemExit as e:
    if "FAKE_NEW_KEY" not in str(e) or "unclassified" not in str(e):
        raise SystemExit(f"fixture without classification failed for the wrong reason: {e}")
    print(f"fixture fail case ok: unclassified -> {e}")
else:
    raise SystemExit("fixture without classification should report FAKE_NEW_KEY as unclassified")

union, classified = check_classification(contract, (fixture / "keys-with.yaml").read_text())
missing = sorted(set(union) - set(classified))
if missing:
    raise SystemExit(f"fixture with classification should pass, still missing: {missing}")
print("fixture pass case ok: all contract keys classified")
PY
echo "contract-keys fixture test ok"
