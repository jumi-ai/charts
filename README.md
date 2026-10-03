# charts

Helm charts for [Jumi](https://github.com/kirmanak/jumi).

The installable chart is [charts/jumi](charts/jumi). It is a new chart. It is not the homelab GitOps chart, and it does not move the app repo.

Install and limits: [charts/jumi/README.md](charts/jumi/README.md).

OCI publish is the `chart` workflow on a `jumi-v*` tag that matches `charts/jumi/Chart.yaml` `version`. A chart-only commit does not build images. Image builds stay in the app repo.
