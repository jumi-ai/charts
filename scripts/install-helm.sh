#!/usr/bin/env bash
# Install the pinned Helm CLI with retries.
#
# The get.helm.sh URL below is the single string the Renovate helm regex
# manager matches, so this version moves with every other Helm reference in
# one Renovate pull. Do not duplicate the URL elsewhere.
set -euo pipefail

for i in 1 2 3 4 5; do
  if curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors \
    -o /tmp/helm.tgz https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz; then
    break
  fi
  echo "helm download attempt $i failed, retrying..." >&2
  sleep 10
  if [ "$i" = 5 ]; then echo "helm download failed after 5 attempts" >&2; exit 1; fi
done
tar -xzf /tmp/helm.tgz -C /tmp
sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
helm version
