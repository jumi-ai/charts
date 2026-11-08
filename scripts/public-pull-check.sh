#!/usr/bin/env bash
# Verify an anonymous installer can pull the chart manifest from ghcr.io.
# Usage: scripts/public-pull-check.sh <version>
# Exits 0 when the manifest for jumi-ai/charts/jumi:<version> is publicly
# readable. Exits non-zero otherwise.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
version="$1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Anonymous pull token (no credentials). Retry transient failures the same
# way the Helm download steps do; do not treat a 5xx as "private" until
# retries are exhausted.
if ! curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors \
  -o "$work/token.json" \
  "https://ghcr.io/token?scope=repository:jumi-ai/charts/jumi:pull"; then
  echo "public-pull-check: failed to fetch anonymous pull token for jumi-ai/charts/jumi:${version}; the package must be made public in the org's package settings" >&2
  exit 1
fi

token="$(python3 - "$work/token.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)["token"])
PY
)"
if [ -z "$token" ]; then
  echo "public-pull-check: empty anonymous pull token for jumi-ai/charts/jumi:${version}; the package must be made public in the org's package settings" >&2
  exit 1
fi

# -f would hide the status code, so capture it explicitly and report it.
code="$(curl -sS --retry 5 --retry-delay 10 --retry-all-errors \
  -o "$work/manifest.json" -w "%{http_code}" \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/jumi-ai/charts/jumi/manifests/${version}")" || {
  echo "public-pull-check: manifest request failed for jumi-ai/charts/jumi:${version}; the package must be made public in the org's package settings" >&2
  exit 1
}

if [ "$code" = "200" ]; then
  echo "public-pull-check: jumi-ai/charts/jumi:${version} is publicly pullable"
  exit 0
fi

echo "public-pull-check: jumi-ai/charts/jumi:${version} is not publicly pullable (HTTP ${code}); the package must be made public in the org's package settings" >&2
exit 1
