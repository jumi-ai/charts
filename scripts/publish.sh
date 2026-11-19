#!/usr/bin/env bash
# Publish the jumi Helm chart to an OCI registry and cut a GitHub Release.
#
# Usage: scripts/publish.sh [--registry OCI_URL] [--dry-run]
#
# The registry defaults to oci://ghcr.io/jumi-ai/charts. With --dry-run,
# helm package, helm registry login, helm push and the OCI existence check
# all run for real, but the git tag push and `gh release create` are
# skipped; the tag and release that would be created are printed instead.
#
# Behaviour:
# - publish only when the jumi-v<version> git tag does not exist yet (a
#   jumi-v* tag push instead verifies the tag matches Chart.yaml);
# - when the OCI tag already exists, skip the push without failing and
#   never overwrite it.
set -euo pipefail

REGISTRY="oci://ghcr.io/jumi-ai/charts"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --registry=*)
      REGISTRY="${1#--registry=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "publish.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/jumi"
version="$(awk '/^version:/{print $2; exit}' "$chart/Chart.yaml")"
tag="jumi-v${version}"

if [[ "${GITHUB_REF:-}" == refs/tags/jumi-v* ]]; then
  pushed="${GITHUB_REF#refs/tags/jumi-v}"
  if [ "$pushed" != "$version" ]; then
    echo "publish.sh: tag jumi-v${pushed} does not match Chart.yaml version ${version}" >&2
    exit 1
  fi
  echo "publish.sh: tag push for ${version} (publishes unless the OCI tag already exists)"
elif git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "publish.sh: tag ${tag} already exists, nothing to publish"
  exit 0
else
  echo "publish.sh: publishing ${version} to ${REGISTRY}"
fi

# A localhost registry serves plain HTTP; keep HTTPS everywhere else.
plain_http=()
case "$REGISTRY" in
  *localhost* | *127.0.0.1*)
    plain_http=(--plain-http)
    ;;
esac

chart_ref="${REGISTRY}/jumi"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if helm pull "$chart_ref" --version "$version" --destination "$work" "${plain_http[@]}" >/dev/null 2>&1; then
  echo "publish.sh: OCI tag ${version} already exists at ${chart_ref}, skipping push (not overwriting)"
  skip_push=1
else
  skip_push=0
fi

helm package "$chart" --destination "$work"
tgz="$work/jumi-${version}.tgz"

if [ "$skip_push" = 0 ]; then
  registry_host="${REGISTRY#oci://}"
  registry_host="${registry_host%%/*}"
  registry_user="${HELM_REGISTRY_USER:-local}"
  printf '%s' "${GH_TOKEN:?publish.sh: GH_TOKEN must be set to push}" \
    | helm registry login "$registry_host" -u "$registry_user" --password-stdin "${plain_http[@]}"
  helm push "$tgz" "$REGISTRY" "${plain_http[@]}"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "publish.sh: dry-run: would create tag ${tag} and release ${tag} with jumi-${version}.tgz"
  exit 0
fi

if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  git tag "$tag"
  git push origin "$tag"
fi
if gh release view "$tag" >/dev/null 2>&1; then
  echo "publish.sh: release ${tag} already exists"
else
  notes="$(printf "Helm chart jumi %s.\n\n\`\`\`bash\nhelm install jumi %s/jumi --version %s\n\`\`\`\n" "$version" "$REGISTRY" "$version")"
  gh release create "$tag" "$tgz" \
    --title "jumi ${version}" \
    --notes "$notes"
fi
