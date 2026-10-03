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
