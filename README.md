# charts

Helm charts for Jumi. The installable chart is [charts/jumi](charts/jumi). Install steps are in [charts/jumi/README.md](charts/jumi/README.md).

A signed tag `jumi-vX.Y.Z` on `main`, matching `charts/jumi/Chart.yaml` `version`, publishes `oci://ghcr.io/jumi-ai/charts/jumi` and a GitHub Release with the packaged chart. The tag cannot be moved after it is pushed.
