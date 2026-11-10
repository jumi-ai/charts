# jumi

Helm chart for a self-hosted Jumi control plane.

It installs a router, a control StatefulSet, one-shot Job templates, and optional Postgres.

Chart `0.3.0` is tested against image tag `v10.5.1`. Images are `ghcr.io/jumi-ai/jumi-reviewer` and `ghcr.io/jumi-ai/jumi-worker`.

## What you get

- **router** — Deployment, the only public webhook. Reviewer image, `JUMI_ROLE=router`. Port 3000 is webhooks/`/healthz`/metrics. Port 3001 is the operator board.
- **control** — StatefulSet with 1 replica, `args: [bun, run, src/control.ts]`. Owns the Codex login and dispatches one Kubernetes Job per ledger row. Its ServiceAccount is the only Jumi identity with `automountServiceAccountToken: true`.
- **Job templates** — ConfigMap with `engine.json` (reviewer image) and `worker.json` (worker image). Each is a full `batch/v1` Job: `args: [bun, run, src/job.ts]`, `backoffLimit: 0`, `activeDeadlineSeconds = timeoutMs/1000 + 1800`, `ttlSecondsAfterFinished: 3600`, `restartPolicy: Never`. Mounted read-only into control at `/etc/jumi/jobs`.
- **Admission policy** — `ValidatingAdmissionPolicy` + Binding that only matches Job CREATE/UPDATE as the control ServiceAccount and checks images, service account, security context, volumes, env allowlists, and role labels. Without it, Job create can read every Secret in the namespace.
- Optional bundled Postgres. Otherwise you bring `DATABASE_URL`.

## Secret

Make a Secret first.

Gitea:

```bash
kubectl create secret generic jumi-secrets \
  --from-literal=GITEA_BOT_TOKEN=... \
  --from-literal=GITEA_WEBHOOK_SECRET=... \
  --from-literal=DATABASE_URL=postgres://jumi:password@postgres.example:5432/jumi
```

GitHub (your own App):

```bash
kubectl create secret generic jumi-secrets \
  --from-file=GITHUB_APP_PRIVATE_KEY=./app.pem \
  --from-literal=GITHUB_WEBHOOK_SECRET=... \
  --from-literal=DATABASE_URL=postgres://jumi:password@postgres.example:5432/jumi
```

Bundled Postgres skips `DATABASE_URL` and reads `postgres-password` from that same Secret. The password must be URL-safe. `@`, `:`, and `/` break the URL the chart builds.

## Install

From the packaged chart:

```bash
helm install jumi oci://ghcr.io/jumi-ai/charts/jumi --version 0.3.0 \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org
```

That package is published when a push to `main` bumps `charts/jumi/Chart.yaml` `version` (no hand-cut tag; merging to `main` publishes).

From a checkout:

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org
```

`gitea.url` and `gitea.allowedOrgs` are required.

Leave `opencode.wellKnownUrl` at `disabled` unless you run your own endpoint.

Pin an image with `image.reviewer.tag` or `image.worker.tag` set to `vX.Y.Z@sha256:...`. Empty uses `v` plus `Chart.appVersion`. That pin is the tested default, not a ceiling: set a tag to run a newer Jumi than the chart pins.

Bring Postgres by putting `DATABASE_URL` in the Secret. `postgres.enabled` starts a bundled database instead. Router, control, and Jobs all use it.

GitHub instead of Gitea:

```bash
helm install jumi ./charts/jumi \
  --set forge=github \
  --set secret.existingSecret=jumi-secrets \
  --set github.appId=123456 \
  --set github.allowedOrgs=your-org
```

`github.appId` and `github.allowedOrgs` are required. Create the App yourself. Put the PEM in the Secret.

Bundled Postgres:

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org \
  --set postgres.enabled=true
```

Set `ingress.enabled`, `ingress.host`, and `ingress.className` to publish the router (port 3000).

## Codex

Off by default (the GitHub factory runs without it).

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org \
  --set codex.enabled=true
```

On: control gets a retained 1Gi RWO claim at `/data` (the real Codex grant, never seeded), port 3010 reachable only from the router Service, and a chart-owned token Secret with no data that control fills with a token-only `auth.json`. Jobs mount it and set `CODEX_AUTH_FILE`. `helm upgrade` keeps data written after install because the manifest carries no `data` keys.

On also renders a Service named exactly `control` (port 3010 only, selecting this release's control pod) for the board's Codex device login, which dials the fixed host `control:3010`. Only one Codex-enabled release fits in a namespace.

Off: no claim, no port 3010, no `control` Service, no Secret, and the control Role grants nothing on Secrets.

`BOARD_PEER_URL` is unset by default. It is the URL of a peer factory's board (`/api/board` on port 3001), not control. Installers that peer factories set it via `router.extraEnv` / `router.extraEnvFrom` (router-only). Top-level `extraEnv` / `extraEnvFrom` render into both router and control, so a router-only token must use the `router.*` keys to keep it out of control (the pod with Kubernetes API access).

## Board

Router port 3001 is the operator board. Enable it with `router.board.enabled=true`, but expose it only behind an auth proxy on a separate host, never on the webhook host:

```bash
helm install jumi ./charts/jumi ... \
  --set router.board.enabled=true \
  --set router.board.ingress.enabled=true \
  --set router.board.ingress.host=board.example \
  --set router.board.ingress.className=nginx
```

## Jobs

Engine rows use the reviewer image (`jobs.engine.timeoutMs` default 1800000, requests `100m/512Mi`, limit `4Gi`). Worker rows use the worker image (`jobs.worker.timeoutMs` default 14400000, requests `100m/512Mi`, limit `8Gi`).

- `jobs.engine/worker.storageClass`, `homeSize` (default 10Gi), `workSize` (default 8Gi), `tmpSize` (default 4Gi) size the generic ephemeral `home`/`work`/`tmp` volumes. `/tmp` is disk-backed so agent tools, uv caches and venvs do not exhaust a tmpfs.
- Each Job also mounts a 1Mi memory `emptyDir` at `/run/jumi-secrets` with `JUMI_SECRETS_DIR=/run/jumi-secrets`, so the entrypoint's scrubbed secrets file stays off disk.
- `jobs.extraEnv` / `jobs.extraEnvFrom` (plus per-role `jobs.engine/ worker.extraEnv` / `extraEnvFrom`) add env to both Jobs. Referenced Secrets and ConfigMaps are auto-allowlisted in the admission policy.
- `jobs.extraConfigMaps` (plus per-role) mounts extra ConfigMaps into Jobs: `{name, mountPath}`. Names are auto-allowlisted.
- `config.files` holds runner files. Set `jobs.engine.runnersFile` / `jobs.worker.runnersFile` to a key in `config.files` to set `JUMI_RUNNERS_FILE` for that role.
- `jobs.engine/worker.hostUsers` is unset by default; the policy checks it only when set.
- `jobs.engine/worker.podLabels` / `podAnnotations` label the Job pods.
- `jobs.engine/worker.forgeTokenSecret` as `{name, key}` (default empty = `secret.existingSecret` + `secret.giteaTokenKey`, or `secret.githubPrivateKeyKey` when `forge: github`). Lets reviewer and worker use different bot tokens without duplicate env entries. Named Secrets are auto-allowlisted.
- `jobs.engine/worker.initContainers` (list, rendered as-is). Images must be the reviewer or worker repository or the policy denies the Job. The policy checks their image, security context, `env`/`envFrom` `secretKeyRef`/`configMapKeyRef` against the same allowlists.
- `jobs.engine/worker.volumeClaimLabels` / `volumeClaimAnnotations` are applied to the `home`, `work` and `tmp` ephemeral claim templates' `metadata` (e.g. a backup-exclude label).
- `router.podLabels` / `router.podAnnotations` and `control.podLabels` / `control.podAnnotations` label the router Deployment and control StatefulSet pods.
- `router.hostUsers` / `control.hostUsers` are unset by default; rendered into each pod spec when set (same semantics as `jobs.<role>.hostUsers`). When `control.hostUsers: false`, the storage behind control's retained claim must support idmapped mounts.
- `router.extraEnv` / `router.extraEnvFrom` add env to the router only; `control.extraEnv` / `control.extraEnvFrom` add env to control only. Top-level `extraEnv` / `extraEnvFrom` still render into both, so existing values keep working. Use the `router.*` keys for a router-only token (e.g. a board-peer token).
- `containerSecurityContext.readOnlyRootFilesystem: true` (default) applies to router, control, Postgres-wait init containers and both Job templates. Every writable path is a volume (Job `/tmp` is a disk-backed claim, `/run/jumi-secrets` is a memory `emptyDir`, plus `/data`, `/home/jumi`, `/work`).

## Database

Router, control and both Job templates use `DATABASE_URL` from `secret.existingSecret` + `secret.databaseUrlKey` by default (or the bundled Postgres password wiring when `postgres.enabled`). Set `database.existingSecret` + `database.urlKey` (default empty = today's behaviour) to use a separate Secret, e.g. a CNPG app Secret. The named Secret is auto-allowlisted.

## Network policy

Off by default. `networkPolicy.enabled=true` (plain `networking.k8s.io/v1` only) allows control port 3010 ingress from the router only (matching the `control` Service's pods), denies all ingress to Jobs, and opens router port 3000 to the ingress controller and Prometheus.

## Hook

Point the forge hook at the router only.

- Gitea: `https://<ingress>/webhooks/gitea`
- GitHub: `https://<ingress>/webhooks/github`

Enable the events the app README lists.

## Upgrade from 0.2.0

- New values: `jobs.engine.tmpSize` / `jobs.worker.tmpSize` (default `4Gi`). Job `/tmp` moved from a 256Mi memory `emptyDir` to a disk-backed ephemeral claim using the role's `storageClass` and claim labels/annotations.
- Jobs now mount a 1Mi memory `emptyDir` at `/run/jumi-secrets` with `JUMI_SECRETS_DIR` set there. No value to tune.
- Chart `0.3.0` pins Jumi `v10.5.1`. `image.reviewer.tag` / `image.worker.tag` still override the default, so a newer Jumi can run without waiting for a chart release. Jumi `GRADLE_SEED_HOME` (v10.5.0, optional) needs no chart value; use `jobs.extraEnv` / per-role `extraEnv` when needed.

## Upgrade from 0.1.0

Breaking values. The standing engine/worker Deployments and their PVCs are gone, replaced by control + one Job per ledger row.

- Images moved from `ghcr.io/kirmanak/*` to `ghcr.io/jumi-ai/*`.
- Removed: `engine.*`, `worker.*` (replicas, persistence, resources), `database.*`.
- `extraEnvFrom` no longer applies to Jobs; use `jobs.extraEnvFrom`. `config.files` `runners.json` no longer auto-applies; set `jobs.engine/worker.runnersFile`.
- New required concept: `codex.enabled` (default false), `control.*`, `jobs.*`, admission policy (needs Kubernetes >= 1.30).
- Back up any auth under the old engine/worker PVCs, uninstall 0.1.0 (which deletes those PVCs), then install 0.2.0. With Codex on, the new control claim starts empty; copy the real Codex grant in as uid 10001, never a copied `auth.json`.

## Resources

Router is a mailbox (`128Mi` request, `512Mi` limit). Control defaults to `128Mi/512Mi`. Engine Jobs request `512Mi` and limit at `4Gi`; worker Jobs request `512Mi` and limit at `8Gi` so a run can burst.

## License

MIT. See the repository `LICENSE`.
