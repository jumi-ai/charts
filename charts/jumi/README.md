# jumi

Helm chart for a self-hosted Jumi control plane.

It installs a router, a control StatefulSet, one-shot Job templates, and optional Postgres.

Chart `0.9.0` is tested against image tag `v11.9.4`. Images are `ghcr.io/jumi-ai/jumi-reviewer` and `ghcr.io/jumi-ai/jumi-worker`.

## What you get

- **router** — Deployment, the only public webhook. Reviewer image, `JUMI_ROLE=router`. Port 3000 is webhooks/`/healthz`/metrics. Port 3001 is the operator board.
- **control** — StatefulSet with 1 replica, `args: [bun, run, src/control.ts]`. Owns the Codex login and dispatches one Kubernetes Job per ledger row. Its ServiceAccount is the only Jumi identity with `automountServiceAccountToken: true`.
- **Job templates** — ConfigMap with `engine.json` (reviewer image) and `worker.json` (worker image). Each is a full `batch/v1` Job: `args: [bun, run, src/job.ts]`, `backoffLimit: 0`, `activeDeadlineSeconds = largestEffectiveTimeoutMs/1000 + 1800`, `ttlSecondsAfterFinished: 3600`, `restartPolicy: Never`. Mounted read-only into control at `/etc/jumi/jobs`.
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
helm install jumi oci://ghcr.io/jumi-ai/charts/jumi --version 0.9.0 \
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

The board also serves an MCP endpoint for operators and agents. Reach it in-cluster at `http://<release>-board:<router.board.port>/mcp` (default port 3001); that is the way to reach it, not the ingress. The board ingress stays behind forward auth (`jumi.ai/auth-proxy-required`), so bearer calls to `/mcp` through that ingress don't work. Exposing `/mcp` through the ingress is out of scope.

Two optional router-only values set its bearer tokens, each an existing Secret plus key (both unset by default, both render only into the router):

- `router.board.mcpTokenSecret` (`{name, key}`) sets `BOARD_MCP_TOKEN` (read token).
- `router.board.mcpKickTokenSecret` (`{name, key}`) sets `BOARD_MCP_KICK_TOKEN` (kick token, a write credential that runs board kicks). It never renders into control, Jobs, or top-level `extraEnv`; use these `router.board.*` keys, not `extraEnv`, so it stays out of control (the pod with Kubernetes API access).

Setting either token requires `router.board.enabled=true`; the render fails otherwise. Jumi disarms the kick tool when the kick token equals the read or peer token.

## Jobs

Engine rows use the reviewer image (`jobs.engine.timeoutMs` default 1800000, requests `100m/512Mi`, limit `4Gi`). Worker rows use the worker image (`jobs.worker.timeoutMs` default 14400000, requests `100m/512Mi`, limit `8Gi`).

Timeouts, maxima and the deadline: each Job role runs one or more run kinds (engine: review; worker: implement, follow-up, conflict). `jobs.engine.timeoutMs` sets the review run timeout (`OPENCODE_TIMEOUT_MS`); `jobs.worker.timeoutMs` sets the implement run timeout. The matching `...TimeoutMaxMs` / `timeoutMaxMs` / `followupTimeoutMs` / `followupTimeoutMaxMs` / `conflictTimeoutMs` / `conflictTimeoutMaxMs` values (`jobs.engine.timeoutMaxMs`, `jobs.worker.timeoutMaxMs`, `jobs.worker.followupTimeoutMs`, `jobs.worker.followupTimeoutMaxMs`, `jobs.worker.conflictTimeoutMs`, `jobs.worker.conflictTimeoutMaxMs`, all unset by default) set the deployer ceilings (`OPENCODE_TIMEOUT_MAX_MS`, `FOLLOWUP_TIMEOUT_MS`, `FOLLOWUP_TIMEOUT_MAX_MS`, `CONFLICT_TIMEOUT_MS`, `CONFLICT_TIMEOUT_MAX_MS`) and the non-implement run timeouts. `jobs.engine.setupTimeoutMaxMs` / `jobs.worker.setupTimeoutMaxMs` (null = app default 10 minutes) set the repository `setup` command ceiling (`SETUP_TIMEOUT_MAX_MS`); setup does not extend the job timeout or queue lease, so raising it also raises that role's deadline and lease. Unset means the app default. A repository's `.jumi.yml` `timeouts` may pick a run timeout up to its deployer maximum; the app then extends the lease to `max(LEASE_MS, effective timeout + 10m)`. The chart derives each role's `activeDeadlineSeconds` (`largestEffectiveTimeoutMs/1000 + 1800`) and `LEASE_MS` (`largestEffectiveTimeoutMs + 600000`) from the largest effective timeout that role can run (including the setup maximum), so the deadline always exceeds the largest effective lease the app can take. Per-repository behaviour (trusted senders, pickup label, `ignore_conflicts_label`, auto-merge label names, per-repo timeouts) lives in each repository's `.jumi.yml`, not in chart values. The render fails if `jobs.extraEnv` or `jobs.<role>.extraEnv` sets any timeout/maximum/`LEASE_MS`/`SETUP_TIMEOUT_MAX_MS` env name directly; use the timeout values above so the deadline stays correct.

Auto-merge: `automergeEnabled` (default `true`, matching the app default) renders `JUMI_AUTOMERGE_ENABLED` into the router and both Job templates. It is the deployer's global kill switch; repositories opt in through `.jumi.yml` and issue/PR labels override per PR. There is no `JUMI_AUTOMERGE_REPOS` value: it is deprecated.

- `jobs.engine/worker.storageClass`, `homeSize` (default 10Gi), `workSize` (default 8Gi), `tmpSize` (default 4Gi) size the generic ephemeral `home`/`work`/`tmp` volumes. `/tmp` is disk-backed so agent tools, uv caches and venvs do not exhaust a tmpfs.
- `jobs.worker.cache` (off by default) mounts a deployer-supplied persistent claim at `/cache` with `JUMI_CACHE_DIR=/cache` (`cache.enabled=true` + `cache.existingClaim=<pvc>`). The point is persistence across Jobs, so a per-Job ephemeral claim does not help; use a `ReadWriteMany` claim when several worker Jobs run at once. Caches live under `<JUMI_CACHE_DIR>/<owner>/<repo>/`. Engine Jobs stay as they are (the contract lists no `JUMI_CACHE_DIR` for the reviewer role).
- Git identity: `git.name` / `git.email` (both empty by default) render `JUMI_GIT_NAME` / `JUMI_GIT_EMAIL` into the router and both Job templates. Empty means Jumi's own defaults (`jumi` / `jumi@localhost`); set both to sign work with a real committer identity.
- Phoenix: `phoenix.publicHost` (empty by default = no public-host check) renders `PHOENIX_PUBLIC_HOST` into the router and both Job templates.
- Review sandbox: engine Jobs need a node kernel with Landlock ABI >= 6, otherwise reviews fail closed (`review spawn refused: Landlock sandbox unavailable ...`). `jobs.engine.allowUnsandboxedReviews` (default `false`) renders `JUMI_ALLOW_UNSANDBOXED_REVIEWS=1` into the router and engine Jobs. It is a rollout escape hatch, not a setting to keep on.
- `JUMI_SEARXNG_URL` (optional `http(s)` base URL of a deployer-run SearXNG instance) needs no chart value; `jobs.extraEnv` is enough.
- `MAX_FILES_MAX` / `MAX_PATCH_BYTES_MAX` (review budget ceilings) need no chart value; `jobs.extraEnv` is enough.
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

## Contract keys

Every env key in `deploy/contract.md` at the pinned `appVersion` is classified in `charts/jumi/contract-keys.yaml`:

- `value` renders from a chart value (see the values above).
- `extraEnv` is deliberately left to `extraEnv` / `router.extraEnv` / `control.extraEnv` / `jobs.extraEnv`. Set it there; no chart value will be added.
- `internal` is set by the entrypoint, Kubernetes or the chart itself; do not set it.

`contract-check.sh` fails when the contract has a key that is not classified, when a `value` key does not render, and when this list drifts from `contract-keys.yaml`.

<!-- contract-keys:extraEnv:start -->
- `BOARD_PEER_TOKEN` (router): peer factory board token. Router-only; use `router.extraEnv` / `router.extraEnvFrom`.
- `BOARD_PEER_URL` (router): peer factory board URL (port 3001). Set via `router.extraEnv` when peering factories.
- `CODEX_REFRESH_TOKEN_URL_OVERRIDE` (control): Codex refresh URL override. Set via `control.extraEnv` when testing.
- `CONTROL_JOB_NAMESPACE` (control): Job namespace override. Set via `control.extraEnv` when needed.
- `CONTROL_K8S_API_URL` (control): Kubernetes API override. Set via `control.extraEnv` when needed.
- `CONTROL_K8S_CA_FILE` (control): Kubernetes CA override. Set via `control.extraEnv` when needed.
- `CONTROL_K8S_TOKEN_FILE` (control): service-account token override. Set via `control.extraEnv` when needed.
- `CONTROL_POLL_MS` (control): control poll interval. Set via `control.extraEnv` when tuning.
- `FOLLOWUP_IGNORE_LOGINS` (router, engine, worker): login ignore list. Set via `jobs.extraEnv` / top-level `extraEnv` when needed.
- `GITEA_WEBHOOK_AUTH_TOKEN` (router): Gitea webhook auth token (long-lived). Router-only; chart runs no `worker_server`.
- `GRADLE_SEED_HOME` (engine, worker): read-only Gradle seed. Set via `jobs.extraEnv` when warming caches.
- `IGNORE_CONFLICTS_LABEL` (router): conflict label (long-lived). Router-only; chart runs no `worker_server`.
- `JUMI_AUTOMERGE_REPOS` (router, engine, worker): deprecated. No chart value; use `automergeEnabled` plus per-repo `.jumi.yml`.
- `JUMI_CHECKPOINT_ENABLED` (engine, worker): worker checkpoint toggle. Set via `jobs.extraEnv` when needed.
- `JUMI_CHECKPOINT_INTERVAL_MS` (engine, worker): checkpoint interval. Set via `jobs.extraEnv` when needed.
- `JUMI_CHECKPOINT_MAX_AGE_MS` (engine, worker): checkpoint max age. Set via `jobs.extraEnv` when needed.
- `JUMI_FORGE_IDENTITY` (router, engine, worker): optional forge identity. Set via `jobs.extraEnv` / top-level `extraEnv` when needed.
- `JUMI_HARNESS_MODE` (router, engine, worker): harness mode (`legacy` or `pi`, default `legacy`). Set via `jobs.extraEnv` / top-level `extraEnv` when testing Pi.
- `JUMI_PI_ALLOWED_ROUTES` (router, engine, worker): Pi route allowlist (CSV of profile names, unset means all Pi routes off). Set via `jobs.extraEnv` / top-level `extraEnv` when needed.
- `JUMI_PI_PROFILES_FILE` (router, engine, worker): Pi profile catalog file (JSON object of named profiles; required with `JUMI_HARNESS_MODE=pi`, never read in legacy mode). Set via `jobs.extraEnv` / top-level `extraEnv` when needed.
- `JUMI_SEARXNG_URL` (router, engine, worker): optional `http(s)` SearXNG base URL. Set via `jobs.extraEnv`; needs no chart value.
- `JUMI_VERIFY_ATTEMPTS_MAX` (engine, worker): verify attempts max. Set via `jobs.extraEnv` when needed.
- `JUMI_VERIFY_ENABLED` (engine, worker): verify toggle. Set via `jobs.extraEnv` when needed.
- `JUMI_VERIFY_TIMEOUT_MAX_MS` (engine, worker): verify timeout ceiling. Set via `jobs.extraEnv` when needed.
- `MAX_CONFLICT_ROUNDS` (engine, worker): worker conflict rounds cap. Set via `jobs.extraEnv` when needed.
- `MAX_FILES` (router): review file cap (reviewer). Set via `router.extraEnv` when needed.
- `MAX_FILES_MAX` (router): review file ceiling (reviewer). Set via `router.extraEnv`; no chart value.
- `MAX_FOLLOWUP_ROUNDS` (router, engine, worker): follow-up rounds cap. Set via `jobs.extraEnv` when needed.
- `MAX_INCOMPLETE_RETRIES` (router, engine, worker): incomplete-run retries cap. Set via `jobs.extraEnv` when needed.
- `MAX_JOB_ATTEMPTS` (router, engine, worker): job attempts cap. Set via `jobs.extraEnv` when needed.
- `MAX_OUTPUT_BYTES` (router, engine, worker): output bytes cap. Set via `jobs.extraEnv` when needed.
- `MAX_PATCH_BYTES` (router): patch bytes cap (reviewer). Set via `router.extraEnv` when needed.
- `MAX_PATCH_BYTES_MAX` (router): patch bytes ceiling (reviewer). Set via `router.extraEnv`; no chart value.
- `MAX_WEBHOOK_BYTES` (router): webhook bytes cap (long-lived). Router-only; chart runs no `worker_server`.
- `OPENCODE_CONFIG` (router, engine, worker): OpenCode config override. Set via `jobs.extraEnv` when needed.
- `OPENCODE_FALLBACK_MODEL` (router, engine, worker): OpenCode fallback model. Set via `jobs.extraEnv` when needed.
- `OPENCODE_FALLBACK_VARIANT` (router, engine, worker): OpenCode fallback variant. Set via `jobs.extraEnv` when needed.
- `OPENCODE_VARIANT` (router, engine, worker): OpenCode variant. Set via `jobs.extraEnv` when needed.
- `OPENCODE_WELLKNOWN_KEY` (router, engine, worker): well-known key. Set via `jobs.extraEnv` when needed.
- `OPENCODE_WELLKNOWN_TOKEN` (router, engine, worker): well-known token. Set via `jobs.extraEnv` when needed.
- `PHOENIX_OTLP_ENDPOINT` (router, engine, worker): Phoenix OTLP endpoint (in-cluster base URL). Set via `jobs.extraEnv` when tracing.
- `QUEUE_CONCURRENCY` (router): queue concurrency (long-lived). Router-only; chart runs no `worker_server`.
- `REVIEW_BLOCKING_QUESTION_AUTHORS` (router, engine, worker): review blocking authors list. Set via `jobs.extraEnv` when needed.
- `TRUSTED_SENDER_LOGINS` (router, engine, worker): trusted sender logins. Per-repo `.jumi.yml` covers this; `jobs.extraEnv` when needed.
<!-- contract-keys:extraEnv:end -->

## Database

Router, control and both Job templates use `DATABASE_URL` from `secret.existingSecret` + `secret.databaseUrlKey` by default (or the bundled Postgres password wiring when `postgres.enabled`). Set `database.existingSecret` + `database.urlKey` (default empty = today's behaviour) to use a separate Secret, e.g. a CNPG app Secret. The named Secret is auto-allowlisted.

## Network policy

Off by default. `networkPolicy.enabled=true` (plain `networking.k8s.io/v1` only) allows control port 3010 ingress from the router only (matching the `control` Service's pods), denies all ingress to Jobs, and opens router port 3000 to the ingress controller and Prometheus.

## Hook

Point the forge hook at the router only.

- Gitea: `https://<ingress>/webhooks/gitea`
- GitHub: `https://<ingress>/webhooks/github`

Enable the events the app README lists.

## Upgrade from 0.8.0

- Chart `0.9.0` pins Jumi `v11.9.4`. `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- No breaking changes in the `v11.6.3` → `v11.9.4` range.
- New optional GitOps (no value changes required, `extraEnv` is enough): Jumi `v11.8.0` adds `JUMI_FORGE_IDENTITY` (optional forge identity for reviewer, worker, and one-shot Jobs); Jumi `v11.7.0` adds `JUMI_PI_PROFILES_FILE` (deployment-owned Pi profile catalog file, JSON object of named profiles, for reviewer, worker, and one-shot Jobs; unset with `JUMI_HARNESS_MODE=pi` fails process start, never read in legacy mode). Both render via `jobs.extraEnv` (Jobs) plus top-level `extraEnv` (router); no chart value will be added.

## Upgrade from 0.7.0

- Chart `0.8.0` pins Jumi `v11.6.3`. `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- No breaking changes in the `v11.5.8` → `v11.6.3` range.
- New optional GitOps (no value changes required, `extraEnv` is enough): Jumi `v11.6.0` adds `JUMI_VERIFY_ENABLED` (verify toggle), `JUMI_VERIFY_TIMEOUT_MAX_MS` (verify timeout ceiling), and `JUMI_VERIFY_ATTEMPTS_MAX` (verify attempts max) for worker and one-shot Jobs. They render via `jobs.extraEnv`; no chart value will be added.

## Upgrade from 0.6.0

- Chart `0.7.0` pins Jumi `v11.5.8`. `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- No breaking changes in the `v11.3.1` → `v11.5.8` range.
- New optional GitOps (no value changes required, `extraEnv` is enough): Jumi `v11.4.0` adds `JUMI_HARNESS_MODE` (deployment-only `legacy` or `pi` for reviewer, worker, and one-shot Jobs; unset or empty is `legacy`); Jumi `v11.5.0` adds `JUMI_PI_ALLOWED_ROUTES` (deployment-owned Pi route allowlist, CSV of profile names, for reviewer, worker, and one-shot Jobs; unset or blank means all Pi routes stay off). Both render via `jobs.extraEnv` (Jobs) plus top-level `extraEnv` (router); no chart value will be added.
- Unknown values keys now fail the install: a mistyped key is rejected by the schema instead of being silently ignored.

## Upgrade from 0.5.0

- Chart `0.6.0` pins Jumi `v11.3.1` (includes the Codex `config.toml` bootstrap fix for review-MCP `http_headers`, Jumi v11.1.22). `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- No value changes required. On `FORGE=github`, also subscribe the GitHub App to the **Issue dependencies** event (Jumi v11.2.13 #670) so a removed "blocked by" link wakes the blocked issue. See the app README for the event list.
- New optional router-only values: `router.board.mcpTokenSecret` and `router.board.mcpKickTokenSecret` (`{name, key}`, both empty by default) set `BOARD_MCP_TOKEN` / `BOARD_MCP_KICK_TOKEN` from an existing Secret, rendered only into the router. Setting either requires `router.board.enabled=true`. The kick token is a write credential; keep it in these keys, never in top-level `extraEnv`.

## Upgrade from 0.4.0

- Chart `0.5.0` pins Jumi `v11.1.15`. `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- Breaking (v11.0.0): homelab defaults moved into deployment config. New values, all unset by default: `git.name` / `git.email` (`JUMI_GIT_NAME` default `jumi`, `JUMI_GIT_EMAIL` default `jumi@localhost`) into the router and both Job templates; `phoenix.publicHost` (`PHOENIX_PUBLIC_HOST`, unset = no public-host check) into the router and both Job templates. Installers who want a real committer identity must set `git.name` / `git.email`. `opencode.wellKnownUrl` still renders explicitly (default `disabled`); unset now means disabled upstream instead of defaulting to `https://kirmanak.stream`.
- New values: `jobs.worker.cache` (`enabled: false` + `existingClaim: ""`) mounts the named persistent claim at `/cache` with `JUMI_CACHE_DIR=/cache` on worker Jobs only; the admission policy admits exactly that claim on worker Jobs and nothing when the cache is off.
- New value: `jobs.engine.allowUnsandboxedReviews` (default `false`) renders `JUMI_ALLOW_UNSANDBOXED_REVIEWS=1` into the router and engine Jobs. Nodes need Landlock ABI >= 6 for engine Jobs; the escape hatch is for rollout only.
- New values: `jobs.engine.setupTimeoutMaxMs` / `jobs.worker.setupTimeoutMaxMs` (null = app default 10 minutes) render `SETUP_TIMEOUT_MAX_MS` and feed the role's `activeDeadlineSeconds` / `LEASE_MS` derivation. `SETUP_TIMEOUT_MAX_MS` in any `extraEnv` now fails the render.
- Docs only, `extraEnv` is enough: `JUMI_SEARXNG_URL`, `MAX_FILES_MAX` / `MAX_PATCH_BYTES_MAX`.
- Jumi `JUMI_GIT_*`, `PHOENIX_PUBLIC_HOST`, `JUMI_CACHE_DIR`, `JUMI_ALLOW_UNSANDBOXED_REVIEWS`, `SETUP_TIMEOUT_MAX_MS` need no per-repository setting; `.jumi.yml` `setup` / `review_budget` ceilings combine with the deployer maxima above.

## Upgrade from 0.3.0

- Chart `0.4.0` pins Jumi `v10.10.1`. `image.reviewer.tag` / `image.worker.tag` still override the default. Merging the version bump publishes (the existing publish-on-version-bump job); do not tag by hand.
- New value: `automergeEnabled` (default `true`). Renders `JUMI_AUTOMERGE_ENABLED` into the router and both Job templates. No `JUMI_AUTOMERGE_REPOS`: deprecated, repositories opt in through `.jumi.yml`.
- New values: `jobs.engine.timeoutMaxMs`, `jobs.worker.timeoutMaxMs`, `jobs.worker.followupTimeoutMs`, `jobs.worker.followupTimeoutMaxMs`, `jobs.worker.conflictTimeoutMs`, `jobs.worker.conflictTimeoutMaxMs` (all unset by default = app default). Each role's `activeDeadlineSeconds` and `LEASE_MS` now derive from the largest effective timeout that role can run. The render fails if `jobs.extraEnv` / `jobs.<role>.extraEnv` sets a timeout/maximum/`LEASE_MS` env name; use the values above.
- Already running but unpublished on `main` after 0.3.0 (no version bump, so not yet published): `router.hostUsers` / `control.hostUsers` (null default, same semantics as `jobs.<role>.hostUsers`); `router.extraEnv` / `router.extraEnvFrom` and `control.extraEnv` / `control.extraEnvFrom` (top-level `extraEnv` / `extraEnvFrom` still render into both); tighter Job admission (pod-template labels restricted to chart keys plus role `podLabels` plus controller labels, ephemeral claims require `accessModes == ["ReadWriteOnce"]`, per-role exact `storageClassName`, each configured `volumeClaimLabels` entry).
- Jumi `JUMI_CHECKPOINT_*` (v10.6.0, optional with app defaults) needs no chart value; `jobs.extraEnv` is enough. `.jumi.yml` settings (trusted senders, pickup label, `ignore_conflicts_label`, auto-merge label names, per-repo timeouts) stay in each repository, not in chart values.

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
