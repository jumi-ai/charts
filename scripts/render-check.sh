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
render codex -f "$chart/ci/codex-values.yaml"
render postgres -f "$chart/ci/postgres-values.yaml"
render ingress -f "$chart/ci/ingress-values.yaml"
render overlay -f "$chart/ci/overlay-values.yaml"
render digest -f "$chart/ci/gitea-values.yaml" \
  --set image.reviewer.tag=v10.4.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

if helm template jumi "$chart" \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  >"$work/bad.yaml" 2>"$work/bad.err"; then
  echo "expected gitea.allowedOrgs to fail the render" >&2
  exit 1
fi
grep -F "gitea.allowedOrgs is required" "$work/bad.err" >/dev/null

python3 - "$work" <<'PY'
import sys, json
from pathlib import Path

work = Path(sys.argv[1])
banned = (
    "kirmanak.stream",
    "authentik",
    "ghcr.io/kirmanak",
)
for path in work.glob("*.yaml"):
    if path.name == "bad.yaml":
        continue
    text = path.read_text()
    for item in banned:
        if item in text:
            raise SystemExit(f"{path.name} contains {item}")

def docs(name):
    out = []
    for doc in (work / f"{name}.yaml").read_text().split("\n---"):
        doc = doc.strip()
        if not doc or doc.startswith("# Source"):
            # keep source comments out but still parse the rest
            lines = [l for l in doc.splitlines() if not l.strip().startswith("#")]
            doc = "\n".join(lines).strip()
        if doc:
            out.append(doc)
    return out

def has_kind_component(text, kind, component):
    return f"kind: {kind}" in text and f"app.kubernetes.io/component: {component}" in text

gitea = (work / "gitea.yaml").read_text()
if 'value: "disabled"' not in gitea:
    raise SystemExit("gitea render did not set OPENCODE_WELLKNOWN_URL=disabled")
if "ghcr.io/jumi-ai/jumi-reviewer:v10.4.0" not in gitea:
    raise SystemExit("reviewer image tag is not v<appVersion>")
if "ghcr.io/jumi-ai/jumi-worker:v10.4.0" not in gitea:
    raise SystemExit("worker image tag is not v<appVersion>")
if "JUMI_RUNNERS_FILE" in gitea or "extra-secrets" in gitea:
    raise SystemExit("default gitea render leaked overlay config")
# router + control each set JUMI_ROLE once
if gitea.count("name: JUMI_ROLE") != 2:
    raise SystemExit("JUMI_ROLE must be set on router and control only")
if "value: router" not in gitea or "value: control" not in gitea:
    raise SystemExit("JUMI_ROLE router/control missing")
if "GITHUB_APP_PRIVATE_KEY" in gitea:
    raise SystemExit("gitea render leaked a GitHub secret key")
if "kind: Ingress" in gitea:
    raise SystemExit("ingress rendered while disabled")
if "kind: Deployment" in gitea and "app.kubernetes.io/component: engine" in gitea:
    raise SystemExit("standing engine Deployment must not exist")
if "app.kubernetes.io/component: worker" in gitea and "kind: PersistentVolumeClaim" in gitea and "jumi-worker" in gitea:
    raise SystemExit("standing worker PVC must not exist")
if "bun" not in gitea or "src/control.ts" not in gitea:
    raise SystemExit("control must run bun run src/control.ts")
if "src/job.ts" not in gitea:
    raise SystemExit("Job templates must run bun run src/job.ts")
if "kind: ValidatingAdmissionPolicy" not in gitea:
    raise SystemExit("admission policy missing")
if "kind: StatefulSet" not in gitea:
    raise SystemExit("control StatefulSet missing")
# token Secret must not exist without codex
if "kind: Secret" in gitea and "codex-token" in gitea:
    raise SystemExit("token Secret must not render without codex.enabled")
# control ServiceAccount is the only automount-true identity (SA + its pod spec)
if gitea.count("automountServiceAccountToken: true") != 2:
    raise SystemExit("only control ServiceAccount may automount")
# policy names are cluster-scoped (namespace + fullname)
if "default-jumi-jobs" not in gitea:
    raise SystemExit("policy names must include release namespace and fullname")
if "system:serviceaccount:default:jumi-control" not in gitea:
    raise SystemExit("policy must match only the control ServiceAccount user")

github = (work / "github.yaml").read_text()
if "GITEA_BOT_TOKEN" in github:
    raise SystemExit("github render leaked a Gitea token key")
if "GITHUB_ALLOWED_ORGS" not in github:
    raise SystemExit("github render missing allowlist")
if "GITHUB_APP_PRIVATE_KEY" not in github:
    raise SystemExit("github render missing private key")

codex = (work / "codex.yaml").read_text()
if "kind: Secret" not in codex or "codex-token" not in codex:
    raise SystemExit("codex render missing token Secret")
# token Secret manifest must carry no data so upgrade keeps data written after install
for doc in codex.split("\n---"):
    if "kind: Secret" in doc and "codex-token" in doc:
        keys = [l.strip() for l in doc.splitlines() if l.strip() and not l.strip().startswith("#")]
        if any(l.startswith("data:") or l.startswith("stringData:") for l in keys):
            raise SystemExit("token Secret manifest must not contain data")
if "containerPort: 3010" not in codex:
    raise SystemExit("codex render must expose control port 3010")
if "CODEX_AUTH_FILE" not in codex:
    raise SystemExit("codex render must set CODEX_AUTH_FILE in Jobs")
if '"resourceNames"' not in codex and "resourceNames" not in codex:
    raise SystemExit("codex Role must restrict secrets by resourceNames")
if "BOARD_PEER_URL" not in codex:
    raise SystemExit("codex render should wire the board peer URL")

postgres = (work / "postgres.yaml").read_text()
if "$(POSTGRES_PASSWORD)" not in postgres or "pg_isready" not in postgres:
    raise SystemExit("bundled postgres wiring missing")

ingress = (work / "ingress.yaml").read_text()
if "kind: Ingress" not in ingress or "jumi.example" not in ingress:
    raise SystemExit("ingress render missing host")

overlay = (work / "overlay.yaml").read_text()
# runners land in both Job templates, never on router/control env lists outside jobs
if overlay.count("JUMI_RUNNERS_FILE") < 2:
    raise SystemExit("overlay must set JUMI_RUNNERS_FILE in both Job templates")
if "extra-secrets" not in overlay or "runners.json" not in overlay:
    raise SystemExit("overlay render missing extra secret or runners file")
# allowlists are derived: overlay policy must mention the extra secret + config
if '"extra-secrets"' not in overlay and "extra-secrets" not in overlay:
    raise SystemExit("policy must allowlist the overlay secret")
if overlay.count("extra-secrets") < 3:
    raise SystemExit("policy allowlist must include the overlay secret")
# gitea policy must not mention overlay-only names
if "extra-secrets" in gitea:
    raise SystemExit("default policy leaked overlay secret")

def load_jobs(name):
    text = (work / f"{name}.yaml").read_text()
    jobs = {}
    for doc in text.split("engine.json: |"):
        pass
    # crude extraction: find JSON blocks by indentation
    lines = text.splitlines()
    out = {}
    cur = None
    buf = []
    def flush():
        if cur and buf:
            out[cur] = json.loads("\n".join(buf))
    for i, l in enumerate(lines):
        s = l.strip()
        if s in ("engine.json: |", "worker.json: |"):
            flush()
            cur = s.split(".")[0]
            buf = []
        elif cur is not None:
            if l.startswith("    ") and buf is not None:
                buf.append(l[4:])
            elif l.startswith("  ") or l.startswith("---") or l.startswith("apiVersion"):
                # end of block when dedented to configmap level or next doc
                if l.startswith("  worker.json"):
                    flush()
                    cur = "worker"
                    buf = []
                elif l.strip() == "---" or l.startswith("apiVersion"):
                    flush()
                    cur = None
                    buf = []
    flush()
    return out

for name in ("gitea", "github", "codex", "overlay", "postgres", "ingress"):
    jobs = load_jobs(name)
    if "engine" not in jobs or "worker" not in jobs:
        raise SystemExit(f"{name}: Job templates missing engine/worker")
    for role, job in jobs.items():
        spec = job["spec"]
        if spec.get("backoffLimit") != 0:
            raise SystemExit(f"{name}/{role}: backoffLimit must be 0")
        if spec["template"]["spec"].get("restartPolicy") != "Never":
            raise SystemExit(f"{name}/{role}: restartPolicy must be Never")
        if spec.get("ttlSecondsAfterFinished") != 3600:
            raise SystemExit(f"{name}/{role}: ttlSecondsAfterFinished must be 3600")
        if spec["template"]["spec"].get("serviceAccountName") != "jumi-job":
            raise SystemExit(f"{name}/{role}: wrong job serviceAccount")
        if spec["template"]["spec"].get("automountServiceAccountToken") is not False:
            raise SystemExit(f"{name}/{role}: automount must be false")
        if spec["template"]["spec"].get("terminationGracePeriodSeconds") != 120:
            raise SystemExit(f"{name}/{role}: terminationGracePeriodSeconds must be 120")
        c = spec["template"]["spec"]["containers"][0]
        if c.get("args") != ["bun", "run", "src/job.ts"]:
            raise SystemExit(f"{name}/{role}: wrong job command")
        env = {e["name"]: e.get("value") for e in c.get("env", [])}
        if env.get("JUMI_JOB_ID") is None:
            raise SystemExit(f"{name}/{role}: JUMI_JOB_ID missing")
        if "OPENCODE_TIMEOUT_MS" not in env or "LEASE_MS" not in env:
            raise SystemExit(f"{name}/{role}: timeout/lease env missing")
        if env.get("WORKDIR") != "/work":
            raise SystemExit(f"{name}/{role}: WORKDIR must be /work")
        mounts = {m["mountPath"] for m in c.get("volumeMounts", [])}
        if "/work" not in mounts or "/tmp" not in mounts:
            raise SystemExit(f"{name}/{role}: /work and /tmp mounts missing")
    eng = jobs["engine"]
    wor = jobs["worker"]
    if eng["spec"].get("activeDeadlineSeconds") != 3600:
        raise SystemExit(f"{name}: engine deadline must be 1800000/1000+1800=3600")
    if wor["spec"].get("activeDeadlineSeconds") != 16200:
        raise SystemExit(f"{name}: worker deadline must be 14400000/1000+1800=16200")
    eng_env = {e["name"]: e.get("value") for e in eng["spec"]["template"]["spec"]["containers"][0]["env"]}
    wor_env = {e["name"]: e.get("value") for e in wor["spec"]["template"]["spec"]["containers"][0]["env"]}
    if eng_env.get("OPENCODE_TIMEOUT_MS") != "1800000" or eng_env.get("LEASE_MS") != "2400000":
        raise SystemExit(f"{name}: engine timeout/lease mismatch")
    if wor_env.get("OPENCODE_TIMEOUT_MS") != "14400000" or wor_env.get("LEASE_MS") != "15000000":
        raise SystemExit(f"{name}: worker timeout/lease mismatch")
    if "ghcr.io/jumi-ai/jumi-reviewer" not in eng["spec"]["template"]["spec"]["containers"][0]["image"]:
        raise SystemExit(f"{name}: engine must use reviewer image")
    if "ghcr.io/jumi-ai/jumi-worker" not in wor["spec"]["template"]["spec"]["containers"][0]["image"]:
        raise SystemExit(f"{name}: worker must use worker image")

digest = (work / "digest.yaml").read_text()
pin = "ghcr.io/jumi-ai/jumi-reviewer:v10.4.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if pin not in digest:
    raise SystemExit("digest pin was dropped")
if "***" in (work / "postgres.yaml").read_text():
    raise SystemExit("bundled postgres URL has a literal placeholder")
print("render-check ok")
PY
