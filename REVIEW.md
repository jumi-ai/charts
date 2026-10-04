Review notes for this repository. Each section heading is a comma-separated list of path globs; the section applies to diffs that touch a matching path. These are pitfalls to check, not a replacement for the review rubric.

## README.md, charts/jumi/README.md, charts/jumi/templates/NOTES.txt, charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl

- A comment that a field is required looks fine. It is wrong when the same sentence names a private account or explains the chart by what it is not. Compare charts/jumi/values.yaml to charts/jumi/templates/_helpers.tpl fail strings.

## charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/README.md

- wellKnownUrl: disabled looks fine. Empty is wrong because the image then fetches a private endpoint. Compare charts/jumi/values.yaml opencode.wellKnownUrl to the fail in charts/jumi/templates/_helpers.tpl.

## charts/jumi/templates/_helpers.tpl

- A bundled Postgres URL that contains a runtime password expansion looks fine. A URL with a literal placeholder password is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.databaseEnv to the postgres container env.

## charts/jumi/values.yaml, charts/jumi/values.schema.json, charts/jumi/templates/deployments.yaml, charts/jumi/templates/_helpers.tpl

- replicas: 1 looks fine. Above 1 is wrong because engine and worker each have one RWO volume. Compare charts/jumi/values.yaml engine.replicas and worker.replicas to the fail in charts/jumi/templates/_helpers.tpl.

## charts/jumi/values.yaml, charts/jumi/templates/service.yaml, charts/jumi/templates/deployments.yaml, charts/jumi/templates/ingress.yaml

- Router service port 80 or 3000 looks fine. A containerPort or service port of 3001 is wrong. Compare charts/jumi/templates/service.yaml to charts/jumi/templates/ingress.yaml.

## charts/jumi/Chart.yaml, charts/jumi/values.yaml, charts/jumi/templates/_helpers.tpl, charts/jumi/README.md

- An image tag of v plus Chart.appVersion looks fine. A tag that drops the v is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.image to charts/jumi/Chart.yaml appVersion.
- A tag of vX.Y.Z@sha256:... looks fine. A helper that drops the digest is wrong. Compare charts/jumi/templates/_helpers.tpl jumi.image to a render that sets that tag.

## .github/workflows/chart.yml

- A publish job that runs only on a jumi-v* tag, pushes the OCI chart, and opens a GitHub Release looks fine. A publish job on pull_request, or a job that skips the Release, is wrong. Compare the publish if to the gh release create step.
- contents: write on the publish job looks fine. contents: write on the lint job is wrong.

## charts/jumi/values.yaml, charts/jumi/templates/deployments.yaml, charts/jumi/templates/configmap.yaml

- config.files: {} looks fine. A default runners.json, or JUMI_RUNNERS_FILE on the router, is wrong. Compare charts/jumi/values.yaml config.files to the runners env in charts/jumi/templates/deployments.yaml.
- extraEnvFrom: [] looks fine. A default secret name is wrong.

## renovate.json, .github/workflows/chart.yml, charts/jumi/values.yaml, charts/jumi/Chart.yaml

- A bump that moves both Helm CLI download URLs in one pull looks fine. A bump that moves one, or a swap to a setup action, is wrong. Compare the two Install Helm steps to the customManagers matchStrings in renovate.json.
- A checkout bump that moves the commit and the version comment together looks fine. A bare tag is wrong.
- An empty image.reviewer.tag and image.worker.tag, and a postgres tag of 18-alpine with no digest, look fine. A bot pull that fills a tag, adds a digest, leaves the 18 line, or bumps appVersion is wrong. Compare charts/jumi/values.yaml to the packageRules in renovate.json.
- config:recommended with automerge off looks fine. config:best-practices, automerge, ignoreTests, a schedule, or dryRun in renovate.json is wrong.
