#!/usr/bin/env bash
# Render the public chart and fail if a homelab default leaks in.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/jumi"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

helm lint "$chart"

render() {
  local name="$1"
  shift
  helm template jumi "$chart" "$@" >"$work/$name.yaml"
}

render gitea -f "$chart/ci/gitea-values.yaml"
render github -f "$chart/ci/github-values.yaml"
render postgres -f "$chart/ci/postgres-values.yaml"
render ingress -f "$chart/ci/ingress-values.yaml"
render overlay -f "$chart/ci/overlay-values.yaml"
render digest -f "$chart/ci/gitea-values.yaml" \
  --set image.reviewer.tag=v7.2.2@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

if helm template jumi "$chart" \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  >"$work/bad.yaml" 2>"$work/bad.err"; then
  echo "expected gitea.allowedOrgs to fail the render" >&2
  exit 1
fi
grep -F "gitea.allowedOrgs is required" "$work/bad.err" >/dev/null

python3 - "$work" <<'PY'
import sys
from pathlib import Path

work = Path(sys.argv[1])
banned = (
    "kirmanak.stream",
    "authentik",
    "PHOENIX_",
    "BOARD_PEER",
    "containerPort: 3001",
    "port: 3001",
)
for path in work.glob("*.yaml"):
    if path.name == "bad.yaml":
        continue
    text = path.read_text()
    for item in banned:
        if item in text:
            raise SystemExit(f"{path.name} contains {item}")

gitea = (work / "gitea.yaml").read_text()
if 'value: "disabled"' not in gitea:
    raise SystemExit("gitea render did not set OPENCODE_WELLKNOWN_URL=disabled")
if "ghcr.io/kirmanak/jumi-reviewer:v7.2.2" not in gitea:
    raise SystemExit("reviewer image tag is not v<appVersion>")
if "ghcr.io/kirmanak/jumi-worker:v7.2.2" not in gitea:
    raise SystemExit("worker image tag is not v<appVersion>")
if "JUMI_RUNNERS_FILE" in gitea or "extra-secrets" in gitea:
    raise SystemExit("default gitea render leaked overlay config")
if gitea.count("name: JUMI_ROLE") != 2:
    raise SystemExit("JUMI_ROLE must be set on router and engine only")
if "GITHUB_APP_PRIVATE_KEY" in gitea:
    raise SystemExit("gitea render leaked a GitHub secret key")
if "kind: Ingress" in gitea:
    raise SystemExit("ingress rendered while disabled")

github = (work / "github.yaml").read_text()
if "GITEA_BOT_TOKEN" in github:
    raise SystemExit("github render leaked a Gitea token key")
if "GITHUB_ALLOWED_ORGS" not in github:
    raise SystemExit("github render missing allowlist")

postgres = (work / "postgres.yaml").read_text()
if "$(POSTGRES_PASSWORD)" not in postgres or "pg_isready" not in postgres:
    raise SystemExit("bundled postgres wiring missing")

ingress = (work / "ingress.yaml").read_text()
if "kind: Ingress" not in ingress or "jumi.example" not in ingress:
    raise SystemExit("ingress render missing host")

overlay = (work / "overlay.yaml").read_text()
if overlay.count("name: JUMI_RUNNERS_FILE") != 2:
    raise SystemExit("JUMI_RUNNERS_FILE must be set on engine and worker only")
if "extra-secrets" not in overlay or "runners.json" not in overlay:
    raise SystemExit("overlay render missing extra secret or runners file")
if 'app.kubernetes.io/component: router' in overlay and "JUMI_RUNNERS_FILE" in overlay.split("app.kubernetes.io/component: engine")[0]:
    raise SystemExit("router must not get JUMI_RUNNERS_FILE")

digest = (work / "digest.yaml").read_text()
pin = "ghcr.io/kirmanak/jumi-reviewer:v7.2.2@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if pin not in digest:
    raise SystemExit("digest pin was dropped")
if "***" in (work / "postgres.yaml").read_text():
    raise SystemExit("bundled postgres URL has a literal placeholder")
print("render-check ok")
PY
