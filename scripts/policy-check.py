#!/usr/bin/env python3
"""Admission-policy check: deny table with exact-message asserts + coverage guard.

Each deny case is a (name, mutation of the rendered Job, exact policy
``message`` it must be denied with). Container-level cases are declared once
and the init-container twin is generated automatically, for both engine and
worker roles.

Usage:
  scripts/policy-check.py --guard
      Fail when a ``- message:`` in charts/jumi/templates/admission-policy.yaml
      has no case in the table. Runs in the lint job (no cluster needed).

  scripts/policy-check.py --engine /tmp/engine.json --worker /tmp/worker.json \\
      --namespace jumi-ci [--control-sa jumi-control] [--admit-only]
      Server-side dry-run the base Jobs as the control ServiceAccount (must be
      admitted), then dry-run every deny variant and require denial with the
      exact ``denied request: <message>`` text. Also verifies a different user
      is not matched by the policy.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "charts/jumi/templates/admission-policy.yaml"

# Exact policy messages (must match templates/admission-policy.yaml verbatim,
# except the two volumeClaimLabel rules which append a concrete key).
IMAGE = "image repository must match allowlist with tag or digest"
INIT_IMAGE = "init image must use a chart image"
SA = "job serviceAccountName is not the chart job account"
AUTOMOUNT = "automountServiceAccountToken must be false"
HOST = "hostNetwork hostPID hostIPC must be false"
PODSC = "pod must run as 10001 with RuntimeDefault seccomp"
CSC = "containers must use the restricted security context"
INITCSC = "initContainers must use the restricted security context"
VOLUMES = "volumes must be emptyDir, ephemeral, or an allowlisted Secret or ConfigMap"
ENV_SECRET = "env secretKeyRef must reference an allowlisted Secret"
INIT_ENV_SECRET = "initContainer env secretKeyRef must reference an allowlisted Secret"
ENVFROM_SECRET = "envFrom secretRef must reference an allowlisted Secret"
INIT_ENVFROM_SECRET = "initContainer envFrom secretRef must reference an allowlisted Secret"
ENV_CM = "env configMapKeyRef must reference an allowlisted ConfigMap"
INIT_ENV_CM = "initContainer env configMapKeyRef must reference an allowlisted ConfigMap"
ENVFROM_CM = "envFrom configMapRef must reference an allowlisted ConfigMap"
INIT_ENVFROM_CM = "initContainer envFrom configMapRef must reference an allowlisted ConfigMap"
JOB_LABELS = "job must carry the chart role labels"
POD_LABELS = "job pods must carry the chart role labels"
ENG_PODLABELS = "engine job pods must only carry allowlisted labels"
WORK_PODLABELS = "worker job pods must only carry allowlisted labels"
ENG_SC = "engine claims must use the engine storage class"
WORK_SC = "worker claims must use the worker storage class"
ENG_CLAIMLABEL_PREFIX = "engine claims must carry volumeClaimLabel "
WORK_CLAIMLABEL_PREFIX = "worker claims must carry volumeClaimLabel "
ENG_HOSTUSERS = "engine Jobs must set hostUsers consistently"
WORK_HOSTUSERS = "worker Jobs must set hostUsers consistently"


def _pod(job):
    return job["spec"]["template"]["spec"]


def _main(job):
    return _pod(job)["containers"][0]


def _ensure_init(job):
    """Return the first init container, synthesising a valid one if absent."""
    pod = _pod(job)
    inits = pod.get("initContainers")
    if inits:
        return inits[0]
    main = _main(job)
    synth = {
        "name": "policy-check-init",
        "image": main["image"],
        "securityContext": copy.deepcopy(main.get("securityContext", {})),
        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
    }
    pod["initContainers"] = [synth]
    return synth


# --- container-level mutations (declared once; init twin auto-generated) ---
def _m_image(c):
    c["image"] = "ghcr.io/evil/other:latest"


def _m_sc(c):
    sc = c.setdefault("securityContext", {})
    sc["allowPrivilegeEscalation"] = True


def _m_env_secret(c):
    c.setdefault("env", []).append(
        {"name": "BAD_SECRET", "valueFrom": {"secretKeyRef": {"name": "not-allowlisted", "key": "k"}}}
    )


def _m_envfrom_secret(c):
    c.setdefault("envFrom", []).append({"secretRef": {"name": "not-allowlisted"}})


def _m_env_cm(c):
    c.setdefault("env", []).append(
        {"name": "BAD_CM", "valueFrom": {"configMapKeyRef": {"name": "not-allowlisted", "key": "k"}}}
    )


def _m_envfrom_cm(c):
    c.setdefault("envFrom", []).append({"configMapRef": {"name": "not-allowlisted"}})


CONTAINER_CASES = [
    # (name, main message, init message, mutate(container))
    ("image", IMAGE, INIT_IMAGE, _m_image),
    ("sc", CSC, INITCSC, _m_sc),
    ("env-secret", ENV_SECRET, INIT_ENV_SECRET, _m_env_secret),
    ("envfrom-secret", ENVFROM_SECRET, INIT_ENVFROM_SECRET, _m_envfrom_secret),
    ("env-cm", ENV_CM, INIT_ENV_CM, _m_env_cm),
    ("envfrom-cm", ENVFROM_CM, INIT_ENVFROM_CM, _m_envfrom_cm),
]


# --- pod/job-level mutations ---
def _m_sa(job):
    _pod(job)["serviceAccountName"] = "default"


def _m_automount(job):
    _pod(job)["automountServiceAccountToken"] = True


def _m_host(job):
    _pod(job)["hostNetwork"] = True


def _m_podsc(job):
    _pod(job).setdefault("securityContext", {})["runAsUser"] = 0


def _m_hostpath(job):
    pod = _pod(job)
    pod.setdefault("volumes", []).append({"name": "bad", "hostPath": {"path": "/"}})
    _main(job).setdefault("volumeMounts", []).append({"name": "bad", "mountPath": "/bad"})


def _m_datasourceref(job):
    pod = _pod(job)
    pod.setdefault("volumes", []).append(
        {
            "name": "bad-ds",
            "ephemeral": {
                "volumeClaimTemplate": {
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "resources": {"requests": {"storage": "1Gi"}},
                        "dataSourceRef": {"kind": "PersistentVolumeClaim", "name": "some-pvc"},
                    }
                }
            },
        }
    )
    _main(job).setdefault("volumeMounts", []).append({"name": "bad-ds", "mountPath": "/bad-ds"})


def _m_accessmodes(job):
    for vol in _pod(job).get("volumes", []):
        claim = ((vol.get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("spec")
        if claim is not None and "accessModes" in claim:
            claim["accessModes"] = ["ReadWriteOnce", "ReadWriteMany"]
            return
    raise RuntimeError("no ephemeral claim to widen accessModes on")


def _m_job_labels(job):
    job.setdefault("metadata", {}).setdefault("labels", {})["app.kubernetes.io/component"] = "other"


def _m_pod_labels(job):
    tmpl = job["spec"]["template"].setdefault("metadata", {}).setdefault("labels", {})
    tmpl["app.kubernetes.io/component"] = "other"


def _m_podlabel_allowlist(job):
    tmpl = job["spec"]["template"].setdefault("metadata", {}).setdefault("labels", {})
    tmpl["cnpg.io/cluster"] = "evil"


def _m_nosc(job):
    found = False
    for vol in _pod(job).get("volumes", []):
        claim = ((vol.get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("spec")
        if claim is not None and "storageClassName" in claim:
            del claim["storageClassName"]
            found = True
    if not found:
        raise RuntimeError("no storageClassName to remove (policy has no storage-class rule here)")


def _claim_label_key(job):
    for vol in _pod(job).get("volumes", []):
        meta = ((vol.get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("metadata") or {}
        labels = meta.get("labels") or {}
        if labels:
            return sorted(labels)[0]
    raise RuntimeError("no claim labels on base job (policy has no claimLabel rule here)")


def _m_claimlabel(job):
    key = _claim_label_key(job)
    for vol in _pod(job).get("volumes", []):
        meta = ((vol.get("ephemeral") or {}).get("volumeClaimTemplate") or {}).get("metadata") or {}
        (meta.get("labels") or {}).pop(key, None)


def _m_hostusers(job):
    pod = _pod(job)
    if "hostUsers" not in pod:
        raise RuntimeError("no hostUsers on base job (policy has no hostUsers rule here)")
    pod["hostUsers"] = True


def _m_worker_pvc_other(job):
    pod = _pod(job)
    pod.setdefault("volumes", []).append(
        {"name": "bad-cache", "persistentVolumeClaim": {"claimName": "other-claim"}}
    )
    _main(job).setdefault("volumeMounts", []).append({"name": "bad-cache", "mountPath": "/bad-cache"})


def _m_engine_cache(job):
    pod = _pod(job)
    pod.setdefault("volumes", []).append(
        {"name": "cache", "persistentVolumeClaim": {"claimName": "jumi-cache"}}
    )
    _main(job).setdefault("volumeMounts", []).append({"name": "cache", "mountPath": "/cache"})


# (name, message-or-per-role-dict-or-"claimlabel", mutate(job), roles)
POD_CASES = [
    ("sa", SA, _m_sa, ("engine", "worker")),
    ("automount", AUTOMOUNT, _m_automount, ("engine", "worker")),
    ("host", HOST, _m_host, ("engine", "worker")),
    ("podsc", PODSC, _m_podsc, ("engine", "worker")),
    ("hostpath", VOLUMES, _m_hostpath, ("engine", "worker")),
    ("datasourceref", VOLUMES, _m_datasourceref, ("engine", "worker")),
    ("accessmodes", VOLUMES, _m_accessmodes, ("engine", "worker")),
    ("job-labels", JOB_LABELS, _m_job_labels, ("engine", "worker")),
    ("pod-labels", POD_LABELS, _m_pod_labels, ("engine", "worker")),
    ("podlabel-allowlist", {"engine": ENG_PODLABELS, "worker": WORK_PODLABELS}, _m_podlabel_allowlist, ("engine", "worker")),
    ("nosc", {"engine": ENG_SC, "worker": WORK_SC}, _m_nosc, ("engine", "worker")),
    ("claimlabel", "claimlabel", _m_claimlabel, ("engine", "worker")),
    ("hostusers", {"engine": ENG_HOSTUSERS, "worker": WORK_HOSTUSERS}, _m_hostusers, ("engine", "worker")),
    ("pvc-other", VOLUMES, _m_worker_pvc_other, ("worker",)),
    ("engine-cache", VOLUMES, _m_engine_cache, ("engine",)),
]


def expected_messages_for_guard():
    """All exact messages the table expects (claimlabel uses a representative key)."""
    out = set()
    for _name, msg, _init_msg, _fn in CONTAINER_CASES:
        out.add(msg)
        out.add(_init_msg)
    for _name, msg, _fn, roles in POD_CASES:
        if msg == "claimlabel":
            for role in roles:
                prefix = ENG_CLAIMLABEL_PREFIX if role == "engine" else WORK_CLAIMLABEL_PREFIX
                out.add(prefix + "example.com/backup")
        elif isinstance(msg, dict):
            for role in roles:
                out.add(msg[role])
        else:
            out.add(msg)
    return out


def template_messages():
    msgs = []
    for line in TEMPLATE.read_text().splitlines():
        m = re.match(r"\s*-\s*message:\s*(.+?)\s*$", line)
        if m:
            msgs.append(m.group(1))
    return msgs


def run_guard():
    tmpl = template_messages()
    if not tmpl:
        print(f"no - message: entries found in {TEMPLATE}", file=sys.stderr)
        return 1
    expected = expected_messages_for_guard()
    missing = []
    for msg in tmpl:
        if "{{" in msg:
            prefix = msg.split("{{")[0].strip()
            if not any(e.startswith(prefix) for e in expected):
                missing.append(msg)
        elif msg not in expected:
            missing.append(msg)
    if missing:
        print("policy-check guard: template messages with no deny case:", file=sys.stderr)
        for msg in missing:
            print(f"  - {msg}", file=sys.stderr)
        return 1
    print(f"policy-check guard ok: {len(tmpl)} template messages covered by {len(expected)} case messages")
    return 0


def _kubectl_create(namespace, job, as_user, dry_run=True):
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(job, f)
        path = f.name
    cmd = ["kubectl", "-n", namespace, "create", "-f", path, f"--as={as_user}"]
    if dry_run:
        cmd += ["--dry-run=server", "-o", "name"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    finally:
        Path(path).unlink(missing_ok=True)
    return proc


def check_admit(namespace, job, as_user):
    proc = _kubectl_create(namespace, job, as_user)
    if proc.returncode != 0:
        print(f"admit failed for {job['metadata'].get('name')} as {as_user}:", file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        return False
    return True


def check_deny(namespace, job, as_user, expected_message):
    proc = _kubectl_create(namespace, job, as_user)
    needle = f"denied request: {expected_message}"
    if proc.returncode == 0:
        print(f"policy admitted {job['metadata'].get('name')} for {as_user}, want denial: {expected_message}", file=sys.stderr)
        return False
    if needle not in (proc.stderr or ""):
        print(f"wrong denial for {job['metadata'].get('name')}: want exact {needle!r}", file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        return False
    return True


def build_variants(base, role):
    """Yield (case_name, mutated_job, expected_message). Skips inapplicable dynamic cases."""
    base = copy.deepcopy(base)
    # container-level: main + auto init twin
    for name, msg, init_msg, fn in CONTAINER_CASES:
        v = copy.deepcopy(base)
        v["metadata"]["name"] = f"e2e-{role}-{name}"
        fn(_main(v))
        yield (f"{role}-{name}", v, msg)
        vi = copy.deepcopy(base)
        vi["metadata"]["name"] = f"e2e-{role}-{name}-init"
        fn(_ensure_init(vi))
        yield (f"{role}-{name}-init", vi, init_msg)
    for name, msg, fn, roles in POD_CASES:
        if role not in roles:
            continue
        if msg == "claimlabel":
            try:
                key = _claim_label_key(base)
            except RuntimeError as e:
                print(f"skip {role}-{name}: {e}")
                continue
            prefix = ENG_CLAIMLABEL_PREFIX if role == "engine" else WORK_CLAIMLABEL_PREFIX
            v = copy.deepcopy(base)
            v["metadata"]["name"] = f"e2e-{role}-{name}"
            try:
                fn(v)
            except RuntimeError as e:
                print(f"skip {role}-{name}: {e}")
                continue
            yield (f"{role}-{name}", v, prefix + key)
            continue
        expected = msg[role] if isinstance(msg, dict) else msg
        v = copy.deepcopy(base)
        v["metadata"]["name"] = f"e2e-{role}-{name}"
        try:
            fn(v)
        except RuntimeError as e:
            print(f"skip {role}-{name}: {e}")
            continue
        yield (f"{role}-{name}", v, expected)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--guard", action="store_true")
    ap.add_argument("--engine", default="/tmp/engine.json")
    ap.add_argument("--worker", default="/tmp/worker.json")
    ap.add_argument("--namespace", default="jumi-ci")
    ap.add_argument("--control-sa", default="jumi-control")
    ap.add_argument("--other-sa", default="jumi-job")
    ap.add_argument("--admit-only", action="store_true")
    args = ap.parse_args(argv)

    if args.guard:
        return run_guard()

    engine = json.loads(Path(args.engine).read_text())
    worker = json.loads(Path(args.worker).read_text())
    bases = {"engine": engine, "worker": worker}
    as_control = f"system:serviceaccount:{args.namespace}:{args.control_sa}"
    as_other = f"system:serviceaccount:{args.namespace}:{args.other_sa}"

    ok = True
    for role, base in bases.items():
        admitted = copy.deepcopy(base)
        admitted["metadata"]["name"] = f"e2e-{role}-ok"
        print(f"admit {role} as {as_control} ...")
        if not check_admit(args.namespace, admitted, as_control):
            ok = False

    if not args.admit_only:
        for role, base in bases.items():
            for case_name, variant, expected in build_variants(base, role):
                print(f"deny {case_name}: want {expected!r} ...")
                if not check_deny(args.namespace, variant, as_control, expected):
                    ok = False
        # same commands as a different user are not matched by the policy
        other = copy.deepcopy(engine)
        other["metadata"]["name"] = "e2e-engine-ok"
        proc = _kubectl_create(args.namespace, other, as_other)
        if proc.returncode == 0:
            print(f"unexpected admit for other SA {as_other} (RBAC should deny)", file=sys.stderr)
            ok = False
        elif "ValidatingAdmissionPolicy" in (proc.stderr or ""):
            print("policy matched a different user", file=sys.stderr)
            print(proc.stderr, file=sys.stderr)
            ok = False
        else:
            print(f"other-user check ok (RBAC denied, no policy match)")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
