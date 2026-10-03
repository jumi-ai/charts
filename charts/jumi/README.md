# jumi

Helm chart for a self-hosted Jumi control plane.

It installs a router, an engine, a worker, and optional Postgres. Ingress is off unless enabled, and then only to the router.

Chart `0.1.0` is tested against image tag `v7.2.2`. Images are `ghcr.io/kirmanak/jumi-reviewer` and `ghcr.io/kirmanak/jumi-worker`.

## What you get

- **router** — the only public webhook. Reviewer image, `JUMI_ROLE=router`. The router does not mount /data.
- **engine** — reviews. Reviewer image, `JUMI_ROLE=engine`. PVC at `/data`.
- **worker** — implement / follow-up / conflict. Worker image. PVC at `/data`.
- Optional bundled Postgres. Otherwise you bring `DATABASE_URL`.
- Ingress is off unless enabled, and then only to the router.

Replicas stay at 1. Engine and worker each have one RWO volume and need their own OpenCode login.

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

From a checkout:

```bash
helm install jumi ./charts/jumi \
  --set secret.existingSecret=jumi-secrets \
  --set gitea.url=https://gitea.example \
  --set gitea.allowedOrgs=your-org
```

`gitea.url` and `gitea.allowedOrgs` are required.

Leave `opencode.wellKnownUrl` at `disabled` unless you run your own endpoint.

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

Ingress is off unless you set `ingress.enabled`, `ingress.host`, and your own class. Set ingress.className yourself.

## Auth volume

Engine and worker mount an empty PVC at `/data` (`HOME`). You copy auth.json onto the PVC. Copy your OpenCode auth in as uid 10001:

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
