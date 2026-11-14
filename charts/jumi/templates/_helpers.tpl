{{/*
Expand the name of the chart.
*/}}
{{- define "jumi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "jumi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "jumi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "jumi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jumi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "jumi.labels" -}}
helm.sh/chart: {{ include "jumi.chart" . }}
{{ include "jumi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "jumi.image" -}}
{{- $tag := .tag | default (printf "v%s" .root.Chart.AppVersion) }}
{{- printf "%s:%s" .repository $tag }}
{{- end }}

{{- define "jumi.postgresSecret" -}}
{{- .Values.postgres.auth.existingSecret | default .Values.secret.existingSecret }}
{{- end }}

{{- define "jumi.postgresHost" -}}
{{- printf "%s-postgres" (include "jumi.fullname" .) }}
{{- end }}

{{- define "jumi.controlSA" -}}
{{- printf "%s-control" (include "jumi.fullname" .) }}
{{- end }}

{{- define "jumi.jobSA" -}}
{{- printf "%s-job" (include "jumi.fullname" .) }}
{{- end }}

{{- define "jumi.codexSecretName" -}}
{{- printf "%s-codex-token" (include "jumi.fullname" .) }}
{{- end }}

{{- define "jumi.policyName" -}}
{{- printf "%s-%s-jobs" .Release.Namespace (include "jumi.fullname" .) | trunc 253 | trimSuffix "-" | lower }}
{{- end }}

{{- define "jumi.validate" -}}
{{- if not .Values.secret.existingSecret }}
{{- fail "secret.existingSecret is required." }}
{{- end }}
{{- if not .Values.opencode.wellKnownUrl }}
{{- fail "opencode.wellKnownUrl must be set. Use disabled unless you run your own well-known endpoint." }}
{{- end }}
{{- if eq .Values.forge "gitea" }}
{{- if not .Values.gitea.url }}
{{- fail "gitea.url is required when forge=gitea" }}
{{- end }}
{{- if not .Values.gitea.allowedOrgs }}
{{- fail "gitea.allowedOrgs is required." }}
{{- end }}
{{- else if eq .Values.forge "github" }}
{{- if not .Values.github.url }}
{{- fail "github.url is required when forge=github" }}
{{- end }}
{{- if not .Values.github.appId }}
{{- fail "github.appId is required when forge=github. Create your own GitHub App." }}
{{- end }}
{{- if not .Values.github.allowedOrgs }}
{{- fail "github.allowedOrgs is required when forge=github" }}
{{- end }}
{{- else }}
{{- fail "forge must be gitea or github" }}
{{- end }}
{{- if .Values.ingress.enabled }}
{{- if not .Values.ingress.host }}
{{- fail "ingress.host is required when ingress.enabled" }}
{{- end }}
{{- if and .Values.ingress.tls.enabled (not .Values.ingress.tls.secretName) }}
{{- fail "ingress.tls.secretName is required when ingress.tls.enabled" }}
{{- end }}
{{- end }}
{{- if .Values.router.board.ingress.enabled }}
{{- if not .Values.router.board.enabled }}
{{- fail "router.board.enabled must be true when router.board.ingress.enabled" }}
{{- end }}
{{- if not .Values.router.board.ingress.host }}
{{- fail "router.board.ingress.host is required when router.board.ingress.enabled" }}
{{- end }}
{{- if and .Values.router.board.ingress.tls.enabled (not .Values.router.board.ingress.tls.secretName) }}
{{- fail "router.board.ingress.tls.secretName is required when router.board.ingress.tls.enabled" }}
{{- end }}
{{- end }}
{{- if gt (int .Values.router.replicas) 1 }}
{{- fail "router.replicas must be 1" }}
{{- end }}
{{- if and .Values.control.dispatchEngine (lt (int .Values.control.engineMaxJobs) 1) }}
{{- fail "control.engineMaxJobs must be at least 1 when control.dispatchEngine is true" }}
{{- end }}
{{- if and .Values.control.dispatchWorker (lt (int .Values.control.workerMaxJobs) 1) }}
{{- fail "control.workerMaxJobs must be at least 1 when control.dispatchWorker is true" }}
{{- end }}
{{- $blockedTimeouts := list "OPENCODE_TIMEOUT_MS" "OPENCODE_TIMEOUT_MAX_MS" "FOLLOWUP_TIMEOUT_MS" "FOLLOWUP_TIMEOUT_MAX_MS" "CONFLICT_TIMEOUT_MS" "CONFLICT_TIMEOUT_MAX_MS" "LEASE_MS" }}
{{- range $e := .Values.jobs.extraEnv }}
{{- if has $e.name $blockedTimeouts }}
{{- fail (printf "jobs.extraEnv must not set %s: use jobs.engine/jobs.worker timeout values so activeDeadlineSeconds covers the largest effective lease" $e.name) }}
{{- end }}
{{- end }}
{{- range $e := .Values.jobs.engine.extraEnv }}
{{- if has $e.name $blockedTimeouts }}
{{- fail (printf "jobs.engine.extraEnv must not set %s: use jobs.engine timeout values so activeDeadlineSeconds covers the largest effective lease" $e.name) }}
{{- end }}
{{- end }}
{{- range $e := .Values.jobs.worker.extraEnv }}
{{- if has $e.name $blockedTimeouts }}
{{- fail (printf "jobs.worker.extraEnv must not set %s: use jobs.worker timeout values so activeDeadlineSeconds covers the largest effective lease" $e.name) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "jumi.databaseSecretName" -}}
{{- if .Values.database.existingSecret }}{{ .Values.database.existingSecret }}{{- else }}{{ .Values.secret.existingSecret }}{{- end }}
{{- end }}

{{- define "jumi.databaseSecretKey" -}}
{{- if .Values.database.urlKey }}{{ .Values.database.urlKey }}{{- else }}{{ .Values.secret.databaseUrlKey }}{{- end }}
{{- end }}

{{- define "jumi.databaseEnv" -}}
{{- if .Values.database.existingSecret }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "jumi.databaseSecretName" . }}
      key: {{ include "jumi.databaseSecretKey" . }}
{{- else if .Values.postgres.enabled }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "jumi.postgresSecret" . }}
      key: {{ .Values.postgres.auth.passwordKey }}
- name: DATABASE_URL
  value: {{ printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:5432/%s" .Values.postgres.auth.username (include "jumi.postgresHost" .) .Values.postgres.auth.database | quote }}
{{- else }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "jumi.databaseSecretName" . }}
      key: {{ include "jumi.databaseSecretKey" . }}
{{- end }}
{{- end }}

{{- define "jumi.automergeEnv" -}}
- name: JUMI_AUTOMERGE_ENABLED
  value: {{ .Values.automergeEnabled | toString | quote }}
{{- end }}

{{- define "jumi.forgeEnv" -}}
{{- if eq .Values.forge "gitea" }}
- name: FORGE
  value: gitea
- name: GITEA_URL
  value: {{ .Values.gitea.url | quote }}
- name: GITEA_ALLOWED_ORGS
  value: {{ .Values.gitea.allowedOrgs | quote }}
{{- if .Values.gitea.allowedRepos }}
- name: GITEA_ALLOWED_REPOS
  value: {{ .Values.gitea.allowedRepos | quote }}
{{- end }}
- name: BOT_USERNAME
  value: {{ .Values.gitea.botUsername | quote }}
- name: GITEA_BOT_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secret.existingSecret }}
      key: {{ .Values.secret.giteaTokenKey }}
- name: GITEA_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secret.existingSecret }}
      key: {{ .Values.secret.giteaWebhookKey }}
{{- else }}
- name: FORGE
  value: github
- name: FORGE_URL
  value: {{ .Values.github.url | quote }}
- name: GITHUB_APP_ID
  value: {{ .Values.github.appId | toString | quote }}
{{- if .Values.github.installationId }}
- name: GITHUB_APP_INSTALLATION_ID
  value: {{ .Values.github.installationId | toString | quote }}
{{- end }}
- name: GITHUB_ALLOWED_ORGS
  value: {{ .Values.github.allowedOrgs | quote }}
{{- if .Values.github.allowedRepos }}
- name: GITHUB_ALLOWED_REPOS
  value: {{ .Values.github.allowedRepos | quote }}
{{- end }}
- name: BOT_USERNAME
  value: {{ .Values.github.botUsername | quote }}
- name: GITHUB_APP_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secret.existingSecret }}
      key: {{ .Values.secret.githubPrivateKeyKey }}
- name: GITHUB_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secret.existingSecret }}
      key: {{ .Values.secret.githubWebhookKey }}
{{- end }}
- name: OPENCODE_WELLKNOWN_URL
  value: {{ .Values.opencode.wellKnownUrl | quote }}
{{- if .Values.opencode.model }}
- name: OPENCODE_MODEL
  value: {{ .Values.opencode.model | quote }}
{{- end }}
{{- end }}

{{- define "jumi.podSecurityContext" -}}
{{- toYaml .Values.podSecurityContext }}
{{- end }}

{{/*
Largest effective run timeout (ms) a Job role can run.
Engine runs review; worker runs implement, follow-up and conflict.
Unset means the app default: only set values can raise the ceiling, so the
deadline only needs to cover the largest set value (timeoutMs always set).
*/}}
{{- define "jumi.engineEffectiveTimeoutMs" -}}
{{- $cfg := .Values.jobs.engine -}}
{{- $effective := $cfg.timeoutMs -}}
{{- if not (kindIs "invalid" $cfg.timeoutMaxMs) }}{{ $effective = max $effective $cfg.timeoutMaxMs }}{{ end -}}
{{- printf "%.0f" (float64 $effective) -}}
{{- end }}

{{- define "jumi.workerEffectiveTimeoutMs" -}}
{{- $cfg := .Values.jobs.worker -}}
{{- $effective := $cfg.timeoutMs -}}
{{- if not (kindIs "invalid" $cfg.timeoutMaxMs) }}{{ $effective = max $effective $cfg.timeoutMaxMs }}{{ end -}}
{{- if not (kindIs "invalid" $cfg.followupTimeoutMs) }}{{ $effective = max $effective $cfg.followupTimeoutMs }}{{ end -}}
{{- if not (kindIs "invalid" $cfg.followupTimeoutMaxMs) }}{{ $effective = max $effective $cfg.followupTimeoutMaxMs }}{{ end -}}
{{- if not (kindIs "invalid" $cfg.conflictTimeoutMs) }}{{ $effective = max $effective $cfg.conflictTimeoutMs }}{{ end -}}
{{- if not (kindIs "invalid" $cfg.conflictTimeoutMaxMs) }}{{ $effective = max $effective $cfg.conflictTimeoutMaxMs }}{{ end -}}
{{- printf "%.0f" (float64 $effective) -}}
{{- end }}

{{- define "jumi.containerSecurityContext" -}}
{{- toYaml .Values.containerSecurityContext }}
{{- end }}

{{/*
All Secret names a Job template may reference. Derived from rendered values:
existingSecret, database override, bundled-postgres Secret,
jobs.extraEnvFrom secretRefs, secretKeyRefs in jobs.extraEnv,
per-role forgeTokenSecret, initContainers env/envFrom secretRefs,
and the Codex token Secret when enabled.
*/}}
{{- define "jumi.jobSecretNames" -}}
{{- $names := list .Values.secret.existingSecret }}
{{- if .Values.postgres.enabled }}
{{- $names = append $names (include "jumi.postgresSecret" .) }}
{{- end }}
{{- if .Values.database.existingSecret }}
{{- $names = append $names .Values.database.existingSecret }}
{{- end }}
{{- range .Values.jobs.extraEnvFrom }}
{{- with .secretRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .Values.jobs.extraEnv }}
{{- with .valueFrom }}{{ with .secretKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- range list .Values.jobs.engine .Values.jobs.worker }}
{{- with .forgeTokenSecret }}
{{- with .name }}{{ $names = append $names . }}{{ end }}
{{- end }}
{{- range .extraEnvFrom }}
{{- with .secretRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .extraEnv }}
{{- with .valueFrom }}{{ with .secretKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- range .initContainers }}
{{- range .envFrom }}
{{- with .secretRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .env }}
{{- with .valueFrom }}{{ with .secretKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- end }}
{{- end }}
{{- if .Values.codex.enabled }}
{{- $names = append $names (include "jumi.codexSecretName" .) }}
{{- end }}
{{- $names | uniq | toJson }}
{{- end }}

{{/*
All ConfigMap names a Job template may reference. Derived from rendered values:
the chart config ConfigMap when a runners file is set, plus jobs extraConfigMaps,
plus configMapKeyRef/configMapRef in jobs.extraEnv/extraEnvFrom, per-role
extraEnv/extraEnvFrom, and initContainers env/envFrom configMap refs.
*/}}
{{- define "jumi.jobConfigMapNames" -}}
{{- $names := list }}
{{- if or .Values.jobs.engine.runnersFile .Values.jobs.worker.runnersFile }}
{{- $names = append $names (printf "%s-config" (include "jumi.fullname" .)) }}
{{- end }}
{{- range .Values.jobs.extraConfigMaps }}{{ $names = append $names .name }}{{ end }}
{{- range .Values.jobs.extraEnvFrom }}
{{- with .configMapRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .Values.jobs.extraEnv }}
{{- with .valueFrom }}{{ with .configMapKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- range list .Values.jobs.engine .Values.jobs.worker }}
{{- range .extraConfigMaps }}{{ $names = append $names .name }}{{ end }}
{{- range .extraEnvFrom }}
{{- with .configMapRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .extraEnv }}
{{- with .valueFrom }}{{ with .configMapKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- range .initContainers }}
{{- range .envFrom }}
{{- with .configMapRef }}{{ $names = append $names .name }}{{ end }}
{{- end }}
{{- range .env }}
{{- with .valueFrom }}{{ with .configMapKeyRef }}{{ $names = append $names .name }}{{ end }}{{ end }}
{{- end }}
{{- end }}
{{- end }}
{{- $names | uniq | toJson }}
{{- end }}

{{- define "jumi.jobStorageClasses" -}}
{{- $names := list }}
{{- with .Values.jobs.engine.storageClass }}{{ $names = append $names . }}{{ end }}
{{- with .Values.jobs.worker.storageClass }}{{ $names = append $names . }}{{ end }}
{{- $names | uniq | toJson }}
{{- end }}

{{/*
Per-role forge token Secret name/key. Empty forgeTokenSecret = default.
*/}}
{{- define "jumi.jobForgeSecretName" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- if and $cfg.forgeTokenSecret $cfg.forgeTokenSecret.name }}{{ $cfg.forgeTokenSecret.name }}{{- else }}{{ $root.Values.secret.existingSecret }}{{- end }}
{{- end }}

{{- define "jumi.jobForgeSecretKey" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- if and $cfg.forgeTokenSecret $cfg.forgeTokenSecret.key }}{{ $cfg.forgeTokenSecret.key }}{{- else if eq $root.Values.forge "gitea" }}{{ $root.Values.secret.giteaTokenKey }}{{- else }}{{ $root.Values.secret.githubPrivateKeyKey }}{{- end }}
{{- end }}

{{/*
Forge env for one-shot Jobs. No webhook secrets: Jobs serve no HTTP.
Expects {root, cfg} so engine/worker can use different bot tokens
without duplicate env entries.
*/}}
{{- define "jumi.jobForgeEnv" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- if eq $root.Values.forge "gitea" }}
- name: FORGE
  value: gitea
- name: GITEA_URL
  value: {{ $root.Values.gitea.url | quote }}
- name: GITEA_ALLOWED_ORGS
  value: {{ $root.Values.gitea.allowedOrgs | quote }}
{{- if $root.Values.gitea.allowedRepos }}
- name: GITEA_ALLOWED_REPOS
  value: {{ $root.Values.gitea.allowedRepos | quote }}
{{- end }}
- name: BOT_USERNAME
  value: {{ $root.Values.gitea.botUsername | quote }}
- name: GITEA_BOT_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "jumi.jobForgeSecretName" (dict "root" $root "cfg" $cfg) }}
      key: {{ include "jumi.jobForgeSecretKey" (dict "root" $root "cfg" $cfg) }}
{{- else }}
- name: FORGE
  value: github
- name: FORGE_URL
  value: {{ $root.Values.github.url | quote }}
- name: GITHUB_APP_ID
  value: {{ $root.Values.github.appId | toString | quote }}
{{- if $root.Values.github.installationId }}
- name: GITHUB_APP_INSTALLATION_ID
  value: {{ $root.Values.github.installationId | toString | quote }}
{{- end }}
- name: GITHUB_ALLOWED_ORGS
  value: {{ $root.Values.github.allowedOrgs | quote }}
{{- if $root.Values.github.allowedRepos }}
- name: GITHUB_ALLOWED_REPOS
  value: {{ $root.Values.github.allowedRepos | quote }}
{{- end }}
- name: BOT_USERNAME
  value: {{ $root.Values.github.botUsername | quote }}
- name: GITHUB_APP_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "jumi.jobForgeSecretName" (dict "root" $root "cfg" $cfg) }}
      key: {{ include "jumi.jobForgeSecretKey" (dict "root" $root "cfg" $cfg) }}
{{- end }}
- name: OPENCODE_WELLKNOWN_URL
  value: {{ $root.Values.opencode.wellKnownUrl | quote }}
{{- if $root.Values.opencode.model }}
- name: OPENCODE_MODEL
  value: {{ $root.Values.opencode.model | quote }}
{{- end }}
{{- end }}
