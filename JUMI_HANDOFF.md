# Handoff (issue-16 merge resolution round)

## What happened
- Resolved conflicted `.github/workflows/chart.yml` (only path in JUMI_CONFLICT.md).
- Merge commit `be3ea3d` (parents: `3332e39` issue head + `d0e762c` main).
- Kept both sides: issue-16 publish block (main-push version-bump gating,
  tag fallback, `skip_push` OCI-exists guard, idempotent `git tag` + `gh release`
  create) + main's `Verify anonymous pull` step calling
  `scripts/public-pull-check.sh`. No visibility PATCH anywhere.

## Key files and why
- `.github/workflows/chart.yml` — resolved publish job; `publish-check`
  dry-run on PRs; `Verify anonymous pull` after release.
- `scripts/public-pull-check.sh` — from main (#15); anonymous GHCR manifest
  pull check; also used by lint regression step.
- `charts/jumi/templates/_jobs.tpl`, `charts/jumi/values.yaml`,
  `charts/jumi/Chart.yaml` (0.3.0 / app 10.5.1) — issue-16 work, untouched
  this round; intact per `git diff d0e762c..HEAD --stat`.
- `REVIEW.md` — main's one-line visibility note kept.

## Commands that passed
- `grep -rn '<<<<<<<|=======|>>>>>>>' .github/workflows/chart.yml` → no markers
- `python3 -c "yaml.safe_load(open('.github/workflows/chart.yml'))"` → ok
- `bash scripts/render-check.sh` → render-check ok
- `bash scripts/contract-check.sh` → contract-check ok
- `helm lint charts/jumi` → 1 linted, 0 failed
- `grep -n "visibility|PATCH" .github/workflows/chart.yml` → no visibility step

## Left / risky
- Kind e2e never ran here (no cluster); first real CI run should confirm the
  publish job's `helm pull` OCI-exists check and `Verify anonymous pull` step
  against the real `0.3.0` tag state.
- Nothing else changed; no markers remain. Done.
