# jumi

Helm chart for a self-hosted [Jumi](https://github.com/kirmanak/jumi) control plane.

This starts three processes and wires a ledger. It does not grant a model, create a GitHub App, or install Authentik, Phoenix, or a cluster network policy. The homelab charts are not this chart.

Chart `0.1.0` is tested against image tag `v7.2.2`. Those images still live at `ghcr.io/kirmanak/jumi-reviewer` and `ghcr.io/kirmanak/jumi-worker`. That namespace moves when the app repo moves. Do not treat this chart as that cutover.

## What you get

- **router** — the only public webhook. Reviewer image, `JUMI_ROLE=router`. No auth volume.
- **engine** — reviews. Reviewer image, `JUMI_ROLE=engine`. PVC at `/data`.
- **worker** — implement / follow-up / conflict. Worker image. PVC at `/data`.
- Optional bundled Postgres. Otherwise you bring `DATABASE_URL`.
- Optional Ingress to the router only. Engine and worker are not exposed. Port 3001 is not published.

Replicas stay at 1. Engine and worker each have one RWO volume and need their own OpenCode login.

## Secret

The chart does not create forge tokens. Make a Secret first.

Gitea:

```bash
kubectl create secret generic jumi-secrets \
  --from-literal=GITEA_BOT_TOKEN=... \
  --from-literal=GITEA_WEBHOOK_SECRET=... \
  --from-literal=DATABASE_URL=postgres://jumi:password@postgres.example:5432/jumi
```

GitHub (your own App, not anyone else's):

```bash
kubectl create secret generic jumi-secrets \
  --from-file=GITHUB_APP_PRIVATE_KEY=./app.pem \
  --from-literal=GITHUB_WEBHOOK_SECRET=... \
  --from-literal=DATABASE_URL=postgres://jumi:password@postgres.example:5432/jumi
```

Bundled Postgres skips `DATABASE_URL` and reads `postgres-password` from that same Secret. The password must be URL-safe. `@`, `:`, and `/` break the URL the chart builds.

## Install

From a checkout:

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org
```

`gitea.allowedOrgs` is required. If you leave it unset, the image allowlists `kirmanak`.

`opencode.wellKnownUrl` defaults to `disabled`. If you clear it, the image fetches `https://kirmanak.stream`. Set it only if you run your own well-known endpoint.

GitHub instead of Gitea:

```bash
helm install jumi ./charts/jumi \
  --set forge=github \
  --set secret.existingSecret=jumi-secrets \
  --set github.appId=123456 \
  --set github.allowedOrgs=your-org
```

Create the App yourself. Put the PEM in the Secret. This chart does not install a shared App, and a webhook must hit your router, not someone else's factory.

Bundled Postgres:

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org \
  --set postgres.enabled=true
```

Ingress is off unless you set `ingress.enabled`, `ingress.host`, and your own class. No default annotations.

OCI (`oci://ghcr.io/jumi-ai/charts/jumi`) is published only when a `jumi-vX.Y.Z` tag matches `Chart.yaml` `version`. It is not published at chart `0.1.0` until that tag exists.

## Auth volume

Engine and worker mount an empty PVC at `/data` (`HOME`). The chart does not seed it. Copy your OpenCode auth in as uid 10001:

```text
/data/.local/share/opencode/auth.json
```

Until that file exists the pods can start and still not review anything.

## Hook

Point the forge hook at the router only.

- Gitea: `https://<ingress>/webhooks/gitea`
- GitHub: `https://<ingress>/webhooks/github`

Enable the events the app README lists. Do not point the hook at a worker pod.

## Resources

Router is a mailbox (`128Mi` request, `512Mi` limit). Engine and worker request `512Mi` and limit at `8Gi` so a review can burst. That limit is a starting cap, not a measurement from your cluster. Raise it if the engine is OOMKilled.

## License

MIT. See the repository `LICENSE`.
