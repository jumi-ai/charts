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
{{- if gt (int .Values.router.replicas) 1 }}
{{- fail "router.replicas must be 1" }}
{{- end }}
{{- if or (gt (int .Values.engine.replicas) 1) (gt (int .Values.worker.replicas) 1) }}
{{- fail "engine.replicas and worker.replicas must be 1 (one RWO auth volume, one login per pod)" }}
{{- end }}
{{- end }}

{{- define "jumi.databaseEnv" -}}
{{- if .Values.postgres.enabled }}
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
      name: {{ .Values.secret.existingSecret }}
      key: {{ .Values.secret.databaseUrlKey }}
{{- end }}
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
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "jumi.podSecurityContext" -}}
{{- toYaml .Values.podSecurityContext }}
{{- end }}

{{- define "jumi.containerSecurityContext" -}}
{{- toYaml .Values.containerSecurityContext }}
{{- end }}
