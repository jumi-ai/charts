# charts

Helm charts for Jumi. The installable chart is [charts/jumi](charts/jumi). Install steps are in [charts/jumi/README.md](charts/jumi/README.md). Chart `0.4.0` tracks Jumi `v10.10.1` (router, control, one-shot Jobs per ledger row).

Existing deployments use `database.existingSecret`, per-role `jobs.engine/worker.forgeTokenSecret`, `initContainers`, claim/pod metadata (see `charts/jumi/ci/hooks-values.yaml` and the chart README). Codex on renders a fixed `control:3010` Service; only one Codex-enabled release fits in a namespace.

A push to `main` that bumps `charts/jumi/Chart.yaml` `version` publishes `oci://ghcr.io/jumi-ai/charts/jumi` and a GitHub Release with the packaged chart (no hand-cut tag; do not tag by hand).
