#!/usr/bin/env bash
# Anti-drift: fetch deploy/contract.md at v{appVersion} and fail when a rendered
# component is missing a required/gitops env key, command, port, runAs or volume.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/jumi"
appVersion="$(awk '/^appVersion:/{gsub(/"/, "", $2); print $2; exit}' "$chart/Chart.yaml")"
contract_url="https://raw.githubusercontent.com/jumi-ai/jumi/v${appVersion}/deploy/contract.md"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$contract_url" "$work/contract.md" <<'PY'
import sys, urllib.request
url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
    f.write(r.read())
PY

render() {
  local name="$1"
  shift
  helm template jumi "$chart" --namespace default "$@" >"$work/$name.yaml"
}

render gitea -f "$chart/ci/gitea-values.yaml"
render github -f "$chart/ci/github-values.yaml"
render codex -f "$chart/ci/codex-values.yaml"
render postgres -f "$chart/ci/postgres-values.yaml"
render ingress -f "$chart/ci/ingress-values.yaml"
render overlay -f "$chart/ci/overlay-values.yaml"
render hooks -f "$chart/ci/hooks-values.yaml"

python3 - "$work" <<'PY'
import json, re, sys
from pathlib import Path

work = Path(sys.argv[1])
contract = (work / "contract.md").read_text()

def section(name):
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

roles = {}
for role in ("reviewer", "worker", "control", "job"):
    sec = section(role)
    roles[role] = {
        "required": items(sec, "required env"),
        "gitops": items(sec, "gitops env"),
        "ports": items(sec, "ports"),
        "runAs": items(sec, "runAs"),
        "command": items(sec, "command"),
        "volumes": items(sec, "volumes"),
    }

# forge-conditional split: GITEA_* vs github keys
GITEA_KEYS = {k for k in roles["reviewer"]["required"] + roles["reviewer"]["gitops"] if k.startswith("GITEA_")}
GITHUB_KEYS = {k for k in roles["reviewer"]["gitops"] + roles["job"]["gitops"] if k.startswith("GITHUB_") or k == "FORGE_URL"}

def load_jobs(text):
    lines = text.splitlines()
    out = {}
    cur = None
    buf = []
    def flush():
        if cur and buf:
            out[cur] = json.loads("\n".join(buf))
    for l in lines:
        s = l.strip()
        if s in ("engine.json: |", "worker.json: |"):
            flush()
            cur = s.split(".")[0]
            buf = []
        elif cur is not None:
            if l.startswith("    "):
                buf.append(l[4:])
            elif l.startswith("  worker.json"):
                flush(); cur = "worker"; buf = []
            elif l.strip() == "---" or l.startswith("apiVersion"):
                flush(); cur = None; buf = []
    flush()
    return out

def split_docs(text):
    docs = []
    for chunk in text.split("\n---"):
        lines = [l for l in chunk.splitlines() if not l.strip().startswith("# Source")]
        body = "\n".join(lines).strip()
        if body.startswith("---"):
            body = body[3:].strip()
        if body:
            docs.append(body)
    return docs

def find(doc_text, kind, component=None, name_suffix=None):
    for doc in split_docs(doc_text):
        if f"kind: {kind}" not in doc:
            continue
        if component and f"app.kubernetes.io/component: {component}" not in doc:
            continue
        if name_suffix and name_suffix not in doc:
            continue
        yield doc

def env_names_from_yaml(doc):
    # crude: find "- name: XXX" under env:
    return set(re.findall(r"-\s*name:\s*([A-Z0-9_]+)", doc))

def check_render(name):
    text = (work / f"{name}.yaml").read_text()
    forge = "github" if "value: github" in text or "FORGE\n  value: github" in text else "gitea"
    # detect forge via values is easier: read FORGE env value occurrences
    m = re.search(r"- name: FORGE\s*\n\s*value:\s*(\w+)", text)
    if m:
        forge = m.group(1)
    codex = "codex-token" in text and "kind: Secret" in text

    # ---- router (Deployment) vs reviewer ----
    router_docs = list(find(text, "Deployment", "router"))
    if len(router_docs) != 1:
        raise SystemExit(f"{name}: router Deployment not found")
    router = router_docs[0]
    r_env = env_names_from_yaml(router)
    for key in roles["reviewer"]["required"]:
        if forge == "github" and key.startswith("GITEA_"):
            continue
        if key == "JUMI_SECRETS_FILE":
            continue  # written by entrypoint, not GitOps
        if key not in r_env:
            raise SystemExit(f"{name}/router: missing reviewer required env {key}")
    for key in roles["reviewer"]["gitops"]:
        if forge == "gitea" and (key.startswith("GITHUB_") or key == "FORGE_URL"):
            continue
        if forge == "github" and key.startswith("GITEA_"):
            continue
        if key not in r_env:
            raise SystemExit(f"{name}/router: missing reviewer gitops env {key}")
    if "src/server.ts" not in router:
        raise SystemExit(f"{name}/router: wrong command (want bun run src/server.ts)")
    if "containerPort: 3000" not in router or "containerPort: 3001" not in router:
        raise SystemExit(f"{name}/router: must expose ports 3000 and 3001")
    if "runAsUser: 10001" not in router or "runAsGroup: 10001" not in router:
        raise SystemExit(f"{name}/router: wrong runAs (want 10001:10001)")
    for vol in roles["reviewer"]["volumes"]:
        if f"mountPath: {vol}" not in router:
            raise SystemExit(f"{name}/router: missing volume mount {vol}")

    # ---- control (StatefulSet) vs control ----
    ctl_docs = list(find(text, "StatefulSet", "control"))
    if len(ctl_docs) != 1:
        raise SystemExit(f"{name}: control StatefulSet not found")
    ctl = ctl_docs[0]
    c_env = env_names_from_yaml(ctl)
    for key in roles["control"]["required"]:
        if key not in c_env:
            raise SystemExit(f"{name}/control: missing control required env {key}")
    for key in roles["control"]["gitops"]:
        if key in ("CONTROL_SECRET_NAME", "CONTROL_SECRET_NAMESPACE") and not codex:
            continue
        if key not in c_env:
            raise SystemExit(f"{name}/control: missing control gitops env {key}")
    if "src/control.ts" not in ctl:
        raise SystemExit(f"{name}/control: wrong command (want bun run src/control.ts)")
    if "containerPort: 3000" not in ctl:
        raise SystemExit(f"{name}/control: must expose port 3000")
    if codex and "containerPort: 3010" not in ctl:
        raise SystemExit(f"{name}/control: codex on must expose port 3010")
    if "runAsUser: 10001" not in ctl:
        raise SystemExit(f"{name}/control: wrong runAs")
    for vol in roles["control"]["volumes"]:
        if f"mountPath: {vol}" not in ctl:
            raise SystemExit(f"{name}/control: missing volume mount {vol}")

    # ---- jobs vs job ----
    jobs = load_jobs(text)
    for role, image_part in (("engine", "jumi-reviewer"), ("worker", "jumi-worker")):
        if role not in jobs:
            raise SystemExit(f"{name}: {role} Job template missing")
        job = jobs[role]
        spec = job["spec"]["template"]["spec"]
        c = spec["containers"][0]
        env = {e["name"] for e in c.get("env", [])}
        for key in roles["job"]["required"]:
            if forge == "github" and key.startswith("GITEA_"):
                continue
            if key == "JUMI_SECRETS_FILE":
                continue
            if key not in env:
                raise SystemExit(f"{name}/{role} job: missing job required env {key}")
        for key in roles["job"]["gitops"]:
            if forge == "gitea" and (key.startswith("GITHUB_") or key == "FORGE_URL"):
                continue
            if key not in env:
                raise SystemExit(f"{name}/{role} job: missing job gitops env {key}")
        if c.get("args") != ["bun", "run", "src/job.ts"]:
            raise SystemExit(f"{name}/{role} job: wrong command (want bun run src/job.ts)")
        if c.get("ports"):
            raise SystemExit(f"{name}/{role} job: must serve no HTTP (no ports)")
        sc = spec.get("securityContext", {})
        if sc.get("runAsUser") != 10001 or sc.get("runAsGroup") != 10001:
            raise SystemExit(f"{name}/{role} job: wrong runAs")
        mounts = {m["mountPath"] for m in c.get("volumeMounts", [])}
        for vol in roles["job"]["volumes"]:
            # /gradle-seed is mounted only when GRADLE_SEED_HOME is set; without it the job runs cold.
            if vol == "/gradle-seed" and "GRADLE_SEED_HOME" not in env:
                continue
            if vol not in mounts:
                raise SystemExit(f"{name}/{role} job: missing volume mount {vol}")
        if image_part not in c.get("image", ""):
            raise SystemExit(f"{name}/{role} job: wrong image target")
        if codex and "CODEX_AUTH_FILE" not in env:
            raise SystemExit(f"{name}/{role} job: codex on must set CODEX_AUTH_FILE")
        if not codex and "CODEX_AUTH_FILE" in env:
            raise SystemExit(f"{name}/{role} job: CODEX_AUTH_FILE without codex")

for name in ("gitea", "github", "codex", "postgres", "ingress", "overlay", "hooks"):
    check_render(name)
print("contract-check ok")
PY
