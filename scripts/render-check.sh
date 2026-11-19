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
  helm template jumi "$chart" --namespace default "$@" >"$work/$name.yaml"
}

render gitea -f "$chart/ci/gitea-values.yaml"
render github -f "$chart/ci/github-values.yaml"
render codex -f "$chart/ci/codex-values.yaml"
render postgres -f "$chart/ci/postgres-values.yaml"
render ingress -f "$chart/ci/ingress-values.yaml"
render overlay -f "$chart/ci/overlay-values.yaml"
render hooks -f "$chart/ci/hooks-values.yaml"
render hooks-readonly-off -f "$chart/ci/hooks-values.yaml" \
  --set containerSecurityContext.readOnlyRootFilesystem=false
render digest -f "$chart/ci/gitea-values.yaml" \
  --set image.reviewer.tag=v11.3.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# Split storageClass: one role pinned, the other unset. The chart's own Jobs
# must still pass the chart's own gate (per-role exact rules admit this;
# the generic union rule must stay permissive on presence).
render split-sc -f "$chart/ci/gitea-values.yaml" \
  --set jobs.engine.storageClass=standard
# Auto-merge off plus raised maxima: the deadline must still cover the
# largest effective lease for each role.
render automerge-off -f "$chart/ci/gitea-values.yaml" \
  --set automergeEnabled=false
render raised-max -f "$chart/ci/gitea-values.yaml" \
  --set jobs.engine.timeoutMaxMs=3600000 \
  --set jobs.worker.timeoutMaxMs=21600000 \
  --set jobs.worker.followupTimeoutMaxMs=21600000
render raised-followup -f "$chart/ci/gitea-values.yaml" \
  --set jobs.worker.followupTimeoutMs=20000000
render git-phoenix -f "$chart/ci/gitea-values.yaml" \
  --set git.name=jumi-ci \
  --set git.email=jumi-ci@example \
  --set phoenix.publicHost=phoenix.example
render cache -f "$chart/ci/gitea-values.yaml" \
  --set jobs.worker.cache.enabled=true \
  --set jobs.worker.cache.existingClaim=jumi-cache
render unsandboxed -f "$chart/ci/gitea-values.yaml" \
  --set jobs.engine.allowUnsandboxedReviews=true
render setup-max -f "$chart/ci/gitea-values.yaml" \
  --set jobs.engine.setupTimeoutMaxMs=3600000 \
  --set jobs.worker.setupTimeoutMaxMs=21600000
# Board MCP tokens: router-only, require the board listener.
render board-mcp -f "$chart/ci/gitea-values.yaml" \
  --set router.board.enabled=true \
  --set router.board.mcpTokenSecret.name=board-mcp-secret \
  --set router.board.mcpTokenSecret.key=token \
  --set router.board.mcpKickTokenSecret.name=board-mcp-kick-secret \
  --set router.board.mcpKickTokenSecret.key=kick-token

if helm template jumi "$chart" --namespace default \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  >"$work/bad.yaml" 2>"$work/bad.err"; then
  echo "expected gitea.allowedOrgs to fail the render" >&2
  exit 1
fi
grep -F "gitea.allowedOrgs is required" "$work/bad.err" >/dev/null

# Timeout/maximum env names must not bypass the deadline via extraEnv.
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set-json 'jobs.extraEnv=[{"name":"OPENCODE_TIMEOUT_MAX_MS","value":"21600000"}]' \
  >"$work/bad-timeout.yaml" 2>"$work/bad-timeout.err"; then
  echo "expected jobs.extraEnv OPENCODE_TIMEOUT_MAX_MS to fail the render" >&2
  exit 1
fi
grep -F "jobs.extraEnv must not set OPENCODE_TIMEOUT_MAX_MS" "$work/bad-timeout.err" >/dev/null
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set-json 'jobs.worker.extraEnv=[{"name":"LEASE_MS","value":"1"}]' \
  >"$work/bad-lease.yaml" 2>"$work/bad-lease.err"; then
  echo "expected jobs.worker.extraEnv LEASE_MS to fail the render" >&2
  exit 1
fi
grep -F "jobs.worker.extraEnv must not set LEASE_MS" "$work/bad-lease.err" >/dev/null
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set-json 'jobs.engine.extraEnv=[{"name":"SETUP_TIMEOUT_MAX_MS","value":"1"}]' \
  >"$work/bad-setup.yaml" 2>"$work/bad-setup.err"; then
  echo "expected jobs.engine.extraEnv SETUP_TIMEOUT_MAX_MS to fail the render" >&2
  exit 1
fi
grep -F "jobs.engine.extraEnv must not set SETUP_TIMEOUT_MAX_MS" "$work/bad-setup.err" >/dev/null
# Board MCP tokens require the board listener.
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set router.board.mcpTokenSecret.name=board-mcp-secret \
  --set router.board.mcpTokenSecret.key=token \
  >"$work/bad-board-mcp.yaml" 2>"$work/bad-board-mcp.err"; then
  echo "expected router.board.mcpTokenSecret without board to fail the render" >&2
  exit 1
fi
grep -F "router.board.enabled must be true when router.board.mcpTokenSecret is set" "$work/bad-board-mcp.err" >/dev/null
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set router.board.mcpKickTokenSecret.name=board-mcp-kick-secret \
  --set router.board.mcpKickTokenSecret.key=kick-token \
  >"$work/bad-board-mcp-kick.yaml" 2>"$work/bad-board-mcp-kick.err"; then
  echo "expected router.board.mcpKickTokenSecret without board to fail the render" >&2
  exit 1
fi
grep -F "router.board.enabled must be true when router.board.mcpKickTokenSecret is set" "$work/bad-board-mcp-kick.err" >/dev/null
# The kick token is router-only: top-level extraEnv must not set it.
if helm template jumi "$chart" --namespace default \
  -f "$chart/ci/gitea-values.yaml" \
  --set-json 'extraEnv=[{"name":"BOARD_MCP_KICK_TOKEN","value":"x"}]' \
  >"$work/bad-board-mcp-extra.yaml" 2>"$work/bad-board-mcp-extra.err"; then
  echo "expected extraEnv BOARD_MCP_KICK_TOKEN to fail the render" >&2
  exit 1
fi
grep -F "extraEnv must not set BOARD_MCP_KICK_TOKEN" "$work/bad-board-mcp-extra.err" >/dev/null

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
if "ghcr.io/jumi-ai/jumi-reviewer:v11.3.1" not in gitea:
    raise SystemExit("reviewer image tag is not v<appVersion>")
if "ghcr.io/jumi-ai/jumi-worker:v11.3.1" not in gitea:
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
# BOARD_PEER_URL is a peer factory board URL (port 3001), never control:3010; unset by default
for _name in ("gitea", "github", "codex", "postgres", "ingress", "overlay", "hooks"):
    _text = (work / f"{_name}.yaml").read_text()
    if "BOARD_PEER_URL" in _text:
        raise SystemExit(f"{_name}: BOARD_PEER_URL must be unset by default (use extraEnv)")

def has_control_service(text):
    for doc in text.split("\n---"):
        if "kind: Service" not in doc:
            continue
        for line in doc.splitlines():
            s = line.strip()
            if s == "name: control":
                # port 3010 only, selector is this release control pod
                if "port: 3010" not in doc:
                    raise SystemExit("control Service must expose port 3010")
                # ensure no http/3000 port in the fixed control Service doc
                if "port: 3000" in doc:
                    raise SystemExit("control Service must expose port 3010 only")
                if "app.kubernetes.io/component: control" not in doc:
                    raise SystemExit("control Service must select control pods")
                return True
    return False

for _name in ("gitea", "github", "postgres", "ingress", "overlay"):
    if has_control_service((work / f"{_name}.yaml").read_text()):
        raise SystemExit(f"{_name}: control Service must exist only with codex.enabled")
for _name in ("codex", "hooks"):
    if not has_control_service((work / f"{_name}.yaml").read_text()):
        raise SystemExit(f"{_name}: control Service missing (codex.enabled)")

# admission policy holes: dataSourceRef and init envFrom must be checked
if "dataSourceRef" not in gitea:
    raise SystemExit("policy must reject dataSourceRef")
if "initContainer envFrom secretRef" not in gitea:
    raise SystemExit("policy must check initContainer envFrom secretRef")
if "configMapKeyRef" not in gitea or "configMapRef" not in gitea:
    raise SystemExit("policy must check ConfigMap refs")

hooks = (work / "hooks.yaml").read_text()
for _secret in ("engine-forge-secret", "worker-forge-secret", "db-secret", "engine-init-secret", "worker-init-secret"):
    if _secret not in hooks:
        raise SystemExit(f"hooks render missing {_secret} (allowlist must include it)")
# ConfigMap env refs (jobs.extraEnv/extraEnvFrom + per-role) must be allowlisted:
# each name renders in Job JSON and 4x in the policy ConfigMap validations.
for _cm in ("shared-cm", "shared-cm-from", "engine-cm", "engine-cm-from", "worker-cm", "worker-cm-from"):
    if hooks.count(_cm) < 3:
        raise SystemExit(f"hooks render missing {_cm} (ConfigMap allowlist must include it)")
# containerSecurityContext toggle must reach Jobs, not just router/control.
off = (work / "hooks-readonly-off.yaml").read_text()
if '"readOnlyRootFilesystem": false' not in off and 'readOnlyRootFilesystem: false' not in off:
    raise SystemExit("hooks-readonly-off render missing readOnlyRootFilesystem: false")
# Jobs render as JSON inside the ConfigMap, router/control as YAML: require both styles.
if '"readOnlyRootFilesystem": false' not in off:
    raise SystemExit("hooks-readonly-off Jobs must render containerSecurityContext toggle (JSON)")
if 'readOnlyRootFilesystem: false' not in off:
    raise SystemExit("hooks-readonly-off router/control must render containerSecurityContext toggle (YAML)")
# hooks pod/claim metadata
for _needle in ("example.com/owner", "example.com/note", "example.com/backup"):
    if _needle not in hooks:
        raise SystemExit(f"hooks render missing pod/claim metadata {_needle}")
if "volumeClaimLabels" in hooks or "volumeClaimAnnotations" in hooks:
    pass
# router/control hostUsers + per-component envFrom (hooks-values sets them)
if hooks.count("hostUsers: false") < 2:
    raise SystemExit("hooks render must set hostUsers: false on router and control")
if "router-only-secret" not in hooks:
    raise SystemExit("hooks render missing router-only extraEnvFrom")
if "ROUTER_ONLY_TOKEN" not in hooks:
    raise SystemExit("hooks render missing router-only extraEnv")
def _split_docs(text):
    return [d for d in text.split("\n---") if d.strip()]
_router_docs = [d for d in _split_docs(hooks) if "kind: Deployment" in d and "app.kubernetes.io/component: router" in d]
_control_docs = [d for d in _split_docs(hooks) if "kind: StatefulSet" in d]
if not _router_docs or not _control_docs:
    raise SystemExit("hooks render missing router Deployment or control StatefulSet")
if "router-only-secret" not in _router_docs[0]:
    raise SystemExit("router Deployment must carry the router-only extraEnvFrom")
for _doc in _control_docs:
    if "router-only-secret" in _doc:
        raise SystemExit("router-only extraEnvFrom must be absent from control")
    if "ROUTER_ONLY_TOKEN" in _doc:
        raise SystemExit("router-only extraEnv must be absent from control")
if "hostUsers: false" not in _router_docs[0]:
    raise SystemExit("router Deployment must render hostUsers: false")
if "hostUsers: false" not in _control_docs[0]:
    raise SystemExit("control StatefulSet must render hostUsers: false")
# hooks must render initContainers as-is with chart images (JSON inside ConfigMap)
if hooks.count('"name": "init"') < 2 and hooks.count("FROM_INIT") < 2:
    raise SystemExit("hooks render must include both initContainers")
# readOnlyRootFilesystem in router, control and Jobs (YAML + JSON styles)
if hooks.count("readOnlyRootFilesystem") < 6:
    raise SystemExit("hooks render must set readOnlyRootFilesystem on router, control, waits and Jobs")
if "mountPath: /tmp" not in hooks and '"mountPath": "/tmp"' not in hooks:
    raise SystemExit("hooks render missing /tmp mount for read-only fs")

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

for name in ("gitea", "github", "codex", "overlay", "postgres", "ingress", "hooks"):
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
        if env.get("JUMI_SECRETS_DIR") != "/run/jumi-secrets":
            raise SystemExit(f"{name}/{role}: JUMI_SECRETS_DIR must be /run/jumi-secrets")
        if "/run/jumi-secrets" not in mounts:
            raise SystemExit(f"{name}/{role}: /run/jumi-secrets mount missing")
        vols = {v["name"]: v for v in spec["template"]["spec"].get("volumes", [])}
        if "secrets" not in vols:
            raise SystemExit(f"{name}/{role}: secrets volume missing")
        sec = vols["secrets"].get("emptyDir", {})
        if sec.get("medium") != "Memory" or sec.get("sizeLimit") != "1Mi":
            raise SystemExit(f"{name}/{role}: secrets volume must be 1Mi memory emptyDir")
        if "tmp" not in vols:
            raise SystemExit(f"{name}/{role}: tmp volume missing")
        tmp = vols["tmp"]
        if "emptyDir" in tmp:
            raise SystemExit(f"{name}/{role}: tmp must not be memory-backed emptyDir")
        claim = ((tmp.get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("spec") or {}
        if "ReadWriteOnce" not in (claim.get("accessModes") or []):
            raise SystemExit(f"{name}/{role}: tmp claim must be ReadWriteOnce")
        if (claim.get("resources") or {}).get("requests", {}).get("storage") != "4Gi":
            raise SystemExit(f"{name}/{role}: tmp claim storage must be 4Gi")
        if "dataSource" in claim or "dataSourceRef" in claim:
            raise SystemExit(f"{name}/{role}: tmp claim must not carry dataSource")
    # tmp claim carries the same labels/annotations as home/work (hooks render proves it)
    hooks_jobs = load_jobs("hooks")
    for role in ("engine", "worker"):
        vols = {v["name"]: v for v in hooks_jobs[role]["spec"]["template"]["spec"].get("volumes", [])}
        for claim_name in ("home", "work", "tmp"):
            meta = ((vols[claim_name].get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("metadata") or {}
            if (meta.get("labels") or {}).get("example.com/backup") != "false":
                raise SystemExit(f"hooks/{role}: {claim_name} claim missing volumeClaimLabels")
            if (meta.get("annotations") or {}).get("example.com/note") != f"{role}-hook":
                raise SystemExit(f"hooks/{role}: {claim_name} claim missing volumeClaimAnnotations")
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
pin = "ghcr.io/jumi-ai/jumi-reviewer:v11.3.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if pin not in digest:
    raise SystemExit("digest pin was dropped")
# Split storageClass regression: engine pinned, worker unset.
# The chart's own gate must admit the chart's own Jobs.
split = (work / "split-sc.yaml").read_text()
if "engine claims must use the engine storage class" not in split:
    raise SystemExit("split-sc: per-role engine storageClass rule missing")
if "worker claims must use the worker storage class" not in split:
    raise SystemExit("split-sc: per-role worker storageClass rule missing")
if "(!has(v.ephemeral.volumeClaimTemplate.spec.storageClassName) ||" not in split:
    raise SystemExit("split-sc: generic volumes rule must allow a missing class (per-role rules enforce exactness)")
split_jobs = load_jobs("split-sc")
eng_claims = [v["ephemeral"]["volumeClaimTemplate"]["spec"]
              for v in split_jobs["engine"]["spec"]["template"]["spec"]["volumes"]
              if "ephemeral" in v]
wor_claims = [v["ephemeral"]["volumeClaimTemplate"]["spec"]
              for v in split_jobs["worker"]["spec"]["template"]["spec"]["volumes"]
              if "ephemeral" in v]
if not eng_claims or any(c.get("storageClassName") != "standard" for c in eng_claims):
    raise SystemExit("split-sc: engine Jobs must render storageClassName=standard on every claim")
if any("storageClassName" in c for c in wor_claims):
    raise SystemExit("split-sc: worker Jobs must render no storageClassName when unset")
if '"standard"' not in split:
    raise SystemExit("split-sc: policy union must still list the configured class")
if "***" in (work / "postgres.yaml").read_text():
    raise SystemExit("bundled postgres URL has a literal placeholder")
# Auto-merge: default renders true (or absent), off renders false in router + Jobs.
gitea_docs = docs("gitea")
router_doc = next(d for d in gitea_docs if has_kind_component(d, "Deployment", "router"))
if "JUMI_AUTOMERGE_ENABLED" in router_doc:
    if '"true"' not in router_doc and "'true'" not in router_doc and "true" not in router_doc:
        raise SystemExit("gitea router JUMI_AUTOMERGE_ENABLED must be true by default")
    if "value: \"false\"" in router_doc or "value: 'false'" in router_doc:
        raise SystemExit("gitea router JUMI_AUTOMERGE_ENABLED must not be false by default")
gitea_jobs = load_jobs("gitea")
for role in ("engine", "worker"):
    env = {e["name"]: e.get("value") for e in gitea_jobs[role]["spec"]["template"]["spec"]["containers"][0]["env"]}
    if "JUMI_AUTOMERGE_ENABLED" in env and env["JUMI_AUTOMERGE_ENABLED"] != "true":
        raise SystemExit(f"gitea/{role}: JUMI_AUTOMERGE_ENABLED must be true or absent by default")
off_text = (work / "automerge-off.yaml").read_text()
if off_text.count("JUMI_AUTOMERGE_ENABLED") < 3:
    raise SystemExit("automerge-off must render JUMI_AUTOMERGE_ENABLED into router and both Job templates")
off_docs = docs("automerge-off")
off_router = next(d for d in off_docs if has_kind_component(d, "Deployment", "router"))
if '"false"' not in off_router and "'false'" not in off_router and "value: false" not in off_router:
    raise SystemExit("automerge-off router must set JUMI_AUTOMERGE_ENABLED=false")
off_jobs = load_jobs("automerge-off")
for role in ("engine", "worker"):
    env = {e["name"]: e.get("value") for e in off_jobs[role]["spec"]["template"]["spec"]["containers"][0]["env"]}
    if env.get("JUMI_AUTOMERGE_ENABLED") != "false":
        raise SystemExit(f"automerge-off/{role}: JUMI_AUTOMERGE_ENABLED must be false")
# Raised maxima: each Job deadline must exceed its largest effective lease.
raised = load_jobs("raised-max")
eng = raised["engine"]
wor = raised["worker"]
if eng["spec"].get("activeDeadlineSeconds") != 5400:
    raise SystemExit(f"raised-max: engine deadline must be 3600000/1000+1800=5400, got {eng['spec'].get('activeDeadlineSeconds')}")
if wor["spec"].get("activeDeadlineSeconds") != 23400:
    raise SystemExit(f"raised-max: worker deadline must be 21600000/1000+1800=23400, got {wor['spec'].get('activeDeadlineSeconds')}")
for role, job in raised.items():
    env = {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0]["env"]}
    lease = int(env["LEASE_MS"])
    if job["spec"]["activeDeadlineSeconds"] * 1000 <= lease:
        raise SystemExit(f"raised-max/{role}: deadline must exceed largest effective lease")
    # ceiling envs must render
    if role == "engine" and env.get("OPENCODE_TIMEOUT_MAX_MS") != "3600000":
        raise SystemExit("raised-max/engine: OPENCODE_TIMEOUT_MAX_MS missing")
    if role == "worker" and env.get("OPENCODE_TIMEOUT_MAX_MS") != "21600000":
        raise SystemExit("raised-max/worker: OPENCODE_TIMEOUT_MAX_MS missing")
    if role == "worker" and env.get("FOLLOWUP_TIMEOUT_MAX_MS") != "21600000":
        raise SystemExit("raised-max/worker: FOLLOWUP_TIMEOUT_MAX_MS missing")
raised_fu = load_jobs("raised-followup")
fu = raised_fu["worker"]
if fu["spec"].get("activeDeadlineSeconds") != 21800:
    raise SystemExit(f"raised-followup: worker deadline must be 20000000/1000+1800=21800, got {fu['spec'].get('activeDeadlineSeconds')}")
fu_env = {e["name"]: e.get("value") for e in fu["spec"]["template"]["spec"]["containers"][0]["env"]}
if fu_env.get("FOLLOWUP_TIMEOUT_MS") != "20000000":
    raise SystemExit("raised-followup/worker: FOLLOWUP_TIMEOUT_MS missing")
if fu["spec"]["activeDeadlineSeconds"] * 1000 <= int(fu_env["LEASE_MS"]):
    raise SystemExit("raised-followup/worker: deadline must exceed largest effective lease")
# Default render carries none of the new deploy keys.
for _key in ("JUMI_GIT_NAME", "JUMI_GIT_EMAIL", "PHOENIX_PUBLIC_HOST", "JUMI_CACHE_DIR", "JUMI_ALLOW_UNSANDBOXED_REVIEWS", "SETUP_TIMEOUT_MAX_MS", "BOARD_MCP_TOKEN", "BOARD_MCP_KICK_TOKEN"):
    if _key in gitea:
        raise SystemExit(f"default gitea render must not set {_key}")
if '"mountPath": "/cache"' in gitea or "mountPath: /cache" in gitea:
    raise SystemExit("default gitea render must not mount /cache")
# git.* / phoenix.publicHost set -> env present on router and both Job templates.
git_text = (work / "git-phoenix.yaml").read_text()
for _key, _val in (("JUMI_GIT_NAME", "jumi-ci"), ("JUMI_GIT_EMAIL", "jumi-ci@example"), ("PHOENIX_PUBLIC_HOST", "phoenix.example")):
    if git_text.count(_key) < 3:
        raise SystemExit(f"git-phoenix must render {_key} into router and both Job templates, got {git_text.count(_key)}")
    if _val not in git_text:
        raise SystemExit(f"git-phoenix missing value {_val} for {_key}")
git_docs = docs("git-phoenix")
git_router = next(d for d in git_docs if has_kind_component(d, "Deployment", "router"))
for _key in ("JUMI_GIT_NAME", "JUMI_GIT_EMAIL", "PHOENIX_PUBLIC_HOST"):
    if _key not in git_router:
        raise SystemExit(f"git-phoenix router missing {_key}")
git_jobs = load_jobs("git-phoenix")
for _role in ("engine", "worker"):
    _env = {e["name"]: e.get("value") for e in git_jobs[_role]["spec"]["template"]["spec"]["containers"][0]["env"]}
    for _key in ("JUMI_GIT_NAME", "JUMI_GIT_EMAIL", "PHOENIX_PUBLIC_HOST"):
        if _key not in _env:
            raise SystemExit(f"git-phoenix/{_role}: {_key} missing")
# worker cache enabled -> worker Job mounts the named claim with JUMI_CACHE_DIR, engine does not, policy names the claim.
cache_jobs = load_jobs("cache")
_cache_worker = cache_jobs["worker"]
_cache_wenv = {e["name"]: e.get("value") for e in _cache_worker["spec"]["template"]["spec"]["containers"][0]["env"]}
if _cache_wenv.get("JUMI_CACHE_DIR") != "/cache":
    raise SystemExit("cache/worker: JUMI_CACHE_DIR must be /cache")
_wmounts = {m["mountPath"]: m["name"] for m in _cache_worker["spec"]["template"]["spec"]["containers"][0].get("volumeMounts", [])}
if _wmounts.get("/cache") != "cache":
    raise SystemExit("cache/worker: /cache mount missing")
_wvols = {v["name"]: v for v in _cache_worker["spec"]["template"]["spec"].get("volumes", [])}
if "cache" not in _wvols or (_wvols["cache"].get("persistentVolumeClaim") or {}).get("claimName") != "jumi-cache":
    raise SystemExit("cache/worker: cache volume must be persistentVolumeClaim jumi-cache")
_cache_engine = cache_jobs["engine"]
_cache_eenv = {e["name"]: e.get("value") for e in _cache_engine["spec"]["template"]["spec"]["containers"][0]["env"]}
if "JUMI_CACHE_DIR" in _cache_eenv:
    raise SystemExit("cache/engine: must not set JUMI_CACHE_DIR")
_emounts = {m["mountPath"] for m in _cache_engine["spec"]["template"]["spec"]["containers"][0].get("volumeMounts", [])}
if "/cache" in _emounts:
    raise SystemExit("cache/engine: must not mount /cache")
cache_text = (work / "cache.yaml").read_text()
if '"jumi-cache"' not in cache_text and "'jumi-cache'" not in cache_text and "jumi-cache" not in cache_text:
    raise SystemExit("cache: admission policy must name the cache claim")
# allowUnsandboxedReviews=true -> JUMI_ALLOW_UNSANDBOXED_REVIEWS=1 on engine Jobs (and router).
unsandboxed_jobs = load_jobs("unsandboxed")
_uenv = {e["name"]: e.get("value") for e in unsandboxed_jobs["engine"]["spec"]["template"]["spec"]["containers"][0]["env"]}
if _uenv.get("JUMI_ALLOW_UNSANDBOXED_REVIEWS") != "1":
    raise SystemExit("unsandboxed/engine: JUMI_ALLOW_UNSANDBOXED_REVIEWS must be 1")
unsandboxed_text = (work / "unsandboxed.yaml").read_text()
unsandboxed_docs = docs("unsandboxed")
unsandboxed_router = next(d for d in unsandboxed_docs if has_kind_component(d, "Deployment", "router"))
if "JUMI_ALLOW_UNSANDBOXED_REVIEWS" not in unsandboxed_router:
    raise SystemExit("unsandboxed router missing JUMI_ALLOW_UNSANDBOXED_REVIEWS")
if "JUMI_ALLOW_UNSANDBOXED_REVIEWS" in gitea:
    raise SystemExit("default gitea render must not set JUMI_ALLOW_UNSANDBOXED_REVIEWS")
# raised setupTimeoutMaxMs raises activeDeadlineSeconds and LEASE_MS for that role.
setup = load_jobs("setup-max")
seng = setup["engine"]
swor = setup["worker"]
if seng["spec"].get("activeDeadlineSeconds") != 5400:
    raise SystemExit(f"setup-max: engine deadline must be 3600000/1000+1800=5400, got {seng['spec'].get('activeDeadlineSeconds')}")
if swor["spec"].get("activeDeadlineSeconds") != 23400:
    raise SystemExit(f"setup-max: worker deadline must be 21600000/1000+1800=23400, got {swor['spec'].get('activeDeadlineSeconds')}")
for _role, _job in setup.items():
    _env = {e["name"]: e.get("value") for e in _job["spec"]["template"]["spec"]["containers"][0]["env"]}
    if _env.get("SETUP_TIMEOUT_MAX_MS") not in ("3600000", "21600000"):
        raise SystemExit(f"setup-max/{_role}: SETUP_TIMEOUT_MAX_MS missing")
    if _job["spec"]["activeDeadlineSeconds"] * 1000 <= int(_env["LEASE_MS"]):
        raise SystemExit(f"setup-max/{_role}: deadline must exceed largest effective lease")
# Board MCP tokens render only into the router Deployment.
_mcp_text = (work / "board-mcp.yaml").read_text()
_mcp_docs = docs("board-mcp")
_mcp_router = next(d for d in _mcp_docs if has_kind_component(d, "Deployment", "router"))
_mcp_control = [d for d in _mcp_docs if has_kind_component(d, "StatefulSet", "control")]
for _key, _secret, _skey in (("BOARD_MCP_TOKEN", "board-mcp-secret", "token"), ("BOARD_MCP_KICK_TOKEN", "board-mcp-kick-secret", "kick-token")):
    if _key not in _mcp_router or _secret not in _mcp_router or _skey not in _mcp_router:
        raise SystemExit(f"board-mcp router missing {_key} secretKeyRef {_secret}/{_skey}")
    for _doc in _mcp_control:
        if _key in _doc:
            raise SystemExit(f"board-mcp/{_key} must be absent from control")
_mcp_jobs = load_jobs("board-mcp")
for _role in ("engine", "worker"):
    _env = {e["name"] for e in _mcp_jobs[_role]["spec"]["template"]["spec"]["containers"][0]["env"]}
    for _key in ("BOARD_MCP_TOKEN", "BOARD_MCP_KICK_TOKEN"):
        if _key in _env:
            raise SystemExit(f"board-mcp/{_role}: {_key} must be absent from Job templates")
print("render-check ok")
PY
