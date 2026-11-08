Review notes for this repository. Each section heading is a comma-separated list of path globs; the section applies to diffs that touch a matching path. These are pitfalls to check, not a replacement for the review rubric.

## README.md, charts/jumi/README.md, charts/jumi/templates/NOTES.txt, charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl

- A comment that a field is required looks fine. It is wrong when the same sentence names a private account or explains the chart by what it is not. Compare charts/jumi/values.yaml to charts/jumi/templates/_helpers.tpl fail strings.

## charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/README.md

- wellKnownUrl: disabled looks fine. Empty is wrong because the image then fetches a private endpoint. Compare charts/jumi/values.yaml opencode.wellKnownUrl to the fail in charts/jumi/templates/_helpers.tpl.

## charts/jumi/templates/_helpers.tpl

- A bundled Postgres URL that contains a runtime password expansion looks fine. A URL with a literal placeholder password is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.databaseEnv to the postgres container env.

## charts/jumi/values.yaml, charts/jumi/values.schema.json, charts/jumi/templates/router.yaml, charts/jumi/templates/control.yaml, charts/jumi/templates/_helpers.tpl

- router.replicas: 1 looks fine. Control is fixed at 1 replica (one retained auth volume, one dispatch loop). Router stays at 1 because it is the webhook mailbox. Compare charts/jumi/values.yaml router.replicas to the fail in charts/jumi/templates/_helpers.tpl. Do not re-add engine.replicas/worker.replicas: standing engine/worker Deployments no longer exist.

## charts/jumi/values.yaml, charts/jumi/templates/router.yaml, charts/jumi/templates/ingress.yaml

- Router containerPort 3001 looks fine: it is the operator board. Exposing board port 3001 on the webhook Service or the main Ingress is wrong; the board gets its own Service and optional Ingress behind an auth proxy on a separate host. Compare charts/jumi/templates/router.yaml to charts/jumi/templates/ingress.yaml.
- Router service port 80 or 3000 looks fine. Pointing the forge hook at anything but the router webhook Service is wrong.

## charts/jumi/Chart.yaml, charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/README.md

- An image tag of v plus Chart.appVersion looks fine. A tag that drops the v is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.image to charts/jumi/Chart.yaml appVersion.
- A tag of vX.Y.Z@sha256:... looks fine. A helper that drops the digest is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.image to a render that sets that tag.

## .github/workflows/chart.yml

- A publish job that runs only on a jumi-v* tag, pushes the OCI chart, and opens a GitHub Release looks fine. A publish job on pull_request, or a job that skips the Release, is wrong. Compare the publish if to the gh release create step.
- contents: write on the publish job looks fine. contents: write on the lint job is wrong.
- A kind e2e job that installs with bundled Postgres and Codex on, waits for router/control Ready (with readOnlyRootFilesystem on), dry-run creates engine/worker Jobs as control SA (admit) plus hostPath/envFrom/image/automount/init-envFrom/dataSourceRef/configKeyRef variants (deny), proves another user is not matched, proves control:3010 TCP from the router pod, upgrades with networkPolicy.enabled and re-proves router reachability (Job-labelled deny skipped with a log line when the CNI does not enforce), then helm upgrades and checks the token Secret data survived, looks fine. A job that creates real Jobs without --as/--dry-run, or skips the upgrade data check, is wrong.

## charts/jumi/values.yaml, charts/jumi/templates/_jobs.tpl, charts/jumi/templates/job-templates.yaml, charts/jumi/templates/configmap.yaml

- config.files: {} looks fine. A default runners.json, or JUMI_RUNNERS_FILE on the router or control, is wrong. Compare charts/jumi/values.yaml config.files to the runners env in charts/jumi/templates/_jobs.tpl.
- extraEnvFrom: [] looks fine. A default secret name is wrong. Top-level extraEnvFrom applies to router/control; Jobs use jobs.extraEnvFrom so the admission policy can allowlist them.

## charts/jumi/templates/admission-policy.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/templates/job-templates.yaml

- An allowlist that mentions image repos, Secret names, ConfigMap names, and storage classes looks fine. A second hand-kept list is wrong: every allowlist entry must be templated from the rendered values (jobSecretNames/jobConfigMapNames/jobStorageClasses), so any Secret or ConfigMap a Job references is allowlisted automatically and nothing else is. Compare charts/jumi/templates/admission-policy.yaml to charts/jumi/templates/_helpers.tpl.
- Cluster-scoped ValidatingAdmissionPolicy/Binding names that include the release namespace and fullname look fine. A fixed name is wrong: two installs would collide.
- A token Secret manifest with no data looks fine. A data or stringData key is wrong: helm upgrade would overwrite data written after install.
- An ephemeral volume without dataSourceRef looks fine. A dataSourceRef is wrong: cloning control's /data or the bundled Postgres claim must be denied. Compare charts/jumi/templates/admission-policy.yaml volumes to the dataSourceRef check.
- A containers-only envFrom secretRef check looks fine on its own. Missing initContainers envFrom, or missing configMapRef/configMapKeyRef on either container list, is wrong: a compromised control could read any Secret/ConfigMap. Compare charts/jumi/templates/admission-policy.yaml to the initContainer and ConfigMap validations.

## charts/jumi/values.yaml, charts/jumi/values.schema.json, charts/jumi/templates/control.yaml, charts/jumi/templates/router.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/templates/_jobs.tpl, charts/jumi/README.md

- A Service named exactly `control` (port 3010 only, selecting this release's control pod) rendered only with codex.enabled looks fine. A missing control Service with Codex on, or any control Service with Codex off, is wrong: the board dials fixed host control:3010 and only one Codex-enabled release fits in a namespace. Compare charts/jumi/templates/control.yaml to charts/jumi/README.md.
- `BOARD_PEER_URL` unset by default looks fine. Wiring it to `http://<fullname>-control:3010` is wrong: it is a peer factory's board URL (port 3001), set via extraEnv/extraEnvFrom when peering factories. Compare charts/jumi/templates/router.yaml to charts/jumi/README.md.
- Per-role `jobs.engine/worker.forgeTokenSecret` (`{name, key}`, default empty = secret.existingSecret + gitea/github key) looks fine. Duplicate env entries or a missing allowlist entry are wrong. Compare charts/jumi/templates/_helpers.tpl jobForgeEnv/jobSecretNames to charts/jumi/values.yaml.
- `database.existingSecret` + `database.urlKey` (default empty = bundled Postgres or secret.existingSecret + databaseUrlKey) for router, control and Jobs looks fine. A hard-coded Secret name is wrong. Compare charts/jumi/templates/_helpers.tpl databaseEnv to charts/jumi/README.md.
- `jobs.<role>.initContainers` rendered as-is with reviewer/worker images looks fine. Any other image is wrong (policy denies it). Compare charts/jumi/templates/_jobs.tpl to charts/jumi/values.yaml.
- `jobs.<role>.volumeClaimLabels/Annotations` on home/work claim templates, and `router/control.podLabels/Annotations` on pod templates, look fine. Dropping them in the template is wrong. Compare charts/jumi/templates/_jobs.tpl and control/router.yaml to charts/jumi/values.yaml.
- `readOnlyRootFilesystem: true` in containerSecurityContext for router, control, Postgres-wait inits and Job templates (with /tmp, /data, /home/jumi, /work volumes) looks fine. A writable root is wrong unless the path and toggle are documented in JUMI_PR.md.

## renovate.json, .github/workflows/chart.yml, charts/jumi/values.yaml, charts/jumi/Chart.yaml

- A bump that moves both Helm CLI download URLs in one pull looks fine. A bump that moves one, or a swap to a setup action, is wrong. Compare the two Install Helm steps to the customManagers matchStrings in renovate.json.
- A Helm CLI bump that stays on v3 looks fine. A bump of those URLs to v4 is wrong, because pull CI only lints and the publish job's helm package, helm registry login, and helm push would first run on a signed tag. Compare the download URLs to the helm allowedVersions in the packageRules in renovate.json.
- A checkout bump that moves the commit and the version comment together looks fine. A bare tag is wrong.
- An empty image.reviewer.tag and image.worker.tag, and a postgres tag of 18-alpine with no digest, look fine. A bot pull that fills a tag, adds a digest, leaves the 18 line, or bumps appVersion is wrong. Compare charts/jumi/values.yaml to the packageRules in renovate.json.
- config:recommended with automerge off looks fine. config:best-practices, automerge, ignoreTests, a schedule, or dryRun in renovate.json is wrong.

## charts/jumi/Chart.yaml, charts/jumi/values.yaml, charts/jumi/README.md, scripts/contract-check.sh

- Chart 0.2.0 with appVersion 10.4.0 and kubeVersion >= 1.30 looks fine (ValidatingAdmissionPolicy v1 needs 1.30). An appVersion bump by a bot is wrong: it stays a human PR that scripts/contract-check.sh must pass.
- An upgrade section from 0.1.0 that names removed engine/worker Deployments, PVCs, values, and the kirmanak to jumi-ai image move looks fine. A silent breaking change is wrong.
