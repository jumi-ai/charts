{{/* Engine one-shot Job as YAML (converted to JSON by the ConfigMap template). */}}
{{- define "jumi.engineJobYaml" -}}
{{- $root := . }}
{{- $cfg := $root.Values.jobs.engine }}
{{- $deadline := add (div $cfg.timeoutMs 1000) 1800 }}
{{- $lease := add $cfg.timeoutMs 600000 }}
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app.kubernetes.io/name: {{ include "jumi.name" $root }}
    app.kubernetes.io/instance: {{ $root.Release.Name }}
    app.kubernetes.io/component: engine
    {{- with $cfg.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $cfg.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: {{ $deadline }}
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "jumi.name" $root }}
        app.kubernetes.io/instance: {{ $root.Release.Name }}
        app.kubernetes.io/component: engine
        {{- with $cfg.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $cfg.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "jumi.jobSA" $root }}
      automountServiceAccountToken: false
      enableServiceLinks: false
      {{- if not (kindIs "invalid" $cfg.hostUsers) }}
      hostUsers: {{ $cfg.hostUsers }}
      {{- end }}
      restartPolicy: Never
      terminationGracePeriodSeconds: 120
      securityContext:
        {{- include "jumi.podSecurityContext" $root | nindent 8 }}
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $cfg.initContainers }}
      initContainers:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: jumi
          image: {{ include "jumi.image" (dict "root" $root "repository" $root.Values.image.reviewer.repository "tag" $root.Values.image.reviewer.tag) }}
          imagePullPolicy: {{ $root.Values.image.reviewer.pullPolicy }}
          args:
            - bun
            - run
            - src/job.ts
          securityContext:
            {{- include "jumi.containerSecurityContext" $root | nindent 12 }}
          env:
            - name: JUMI_JOB_ID
              value: control-fills-in
            {{- include "jumi.databaseEnv" $root | nindent 12 }}
            {{- include "jumi.jobForgeEnv" (dict "root" $root "cfg" $cfg) | nindent 12 }}
            - name: OPENCODE_TIMEOUT_MS
              value: {{ printf "%.0f" (float64 $cfg.timeoutMs) | quote }}
            - name: LEASE_MS
              value: {{ printf "%.0f" (float64 $lease) | quote }}
            - name: HOME
              value: /home/jumi
            - name: WORKDIR
              value: /work
            {{- if $cfg.runnersFile }}
            - name: JUMI_RUNNERS_FILE
              value: {{ printf "/config/%s" $cfg.runnersFile | quote }}
            {{- end }}
            {{- if $root.Values.codex.enabled }}
            - name: CODEX_AUTH_FILE
              value: /codex/auth.json
            {{- end }}
            {{- with $root.Values.jobs.extraEnv }}
            {{ toYaml . | nindent 12 }}
            {{- end }}
            {{- with $cfg.extraEnv }}
            {{ toYaml . | nindent 12 }}
            {{- end }}
          {{- $envFrom := concat $root.Values.jobs.extraEnvFrom $cfg.extraEnvFrom }}
          {{- with $envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml $cfg.resources | nindent 12 }}
          volumeMounts:
            - name: home
              mountPath: /home/jumi
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            {{- if $cfg.runnersFile }}
            - name: config
              mountPath: /config
              readOnly: true
            {{- end }}
            {{- if $root.Values.codex.enabled }}
            - name: codex
              mountPath: /codex
              readOnly: true
            {{- end }}
            {{- range $root.Values.jobs.extraConfigMaps }}
            - name: {{ printf "extra-%s" .name }}
              mountPath: {{ .mountPath }}
              readOnly: true
            {{- end }}
            {{- range $cfg.extraConfigMaps }}
            - name: {{ printf "extra-%s" .name }}
              mountPath: {{ .mountPath }}
              readOnly: true
            {{- end }}
      volumes:
        - name: home
          ephemeral:
            volumeClaimTemplate:
              {{- if or $cfg.volumeClaimLabels $cfg.volumeClaimAnnotations }}
              metadata:
                {{- with $cfg.volumeClaimLabels }}
                labels:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
                {{- with $cfg.volumeClaimAnnotations }}
                annotations:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
              {{- end }}
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: {{ $cfg.homeSize | quote }}
                {{- with $cfg.storageClass }}
                storageClassName: {{ . | quote }}
                {{- end }}
        - name: work
          ephemeral:
            volumeClaimTemplate:
              {{- if or $cfg.volumeClaimLabels $cfg.volumeClaimAnnotations }}
              metadata:
                {{- with $cfg.volumeClaimLabels }}
                labels:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
                {{- with $cfg.volumeClaimAnnotations }}
                annotations:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
              {{- end }}
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: {{ $cfg.workSize | quote }}
                {{- with $cfg.storageClass }}
                storageClassName: {{ . | quote }}
                {{- end }}
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
        {{- if $cfg.runnersFile }}
        - name: config
          configMap:
            name: {{ include "jumi.fullname" $root }}-config
        {{- end }}
        {{- if $root.Values.codex.enabled }}
        - name: codex
          secret:
            secretName: {{ include "jumi.codexSecretName" $root }}
        {{- end }}
        {{- range $root.Values.jobs.extraConfigMaps }}
        - name: {{ printf "extra-%s" .name | quote }}
          configMap:
            name: {{ .name | quote }}
        {{- end }}
        {{- range $cfg.extraConfigMaps }}
        - name: {{ printf "extra-%s" .name | quote }}
          configMap:
            name: {{ .name | quote }}
        {{- end }}
{{- end }}

{{/* Worker one-shot Job as YAML (converted to JSON by the ConfigMap template). */}}
{{- define "jumi.workerJobYaml" -}}
{{- $root := . }}
{{- $cfg := $root.Values.jobs.worker }}
{{- $deadline := add (div $cfg.timeoutMs 1000) 1800 }}
{{- $lease := add $cfg.timeoutMs 600000 }}
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app.kubernetes.io/name: {{ include "jumi.name" $root }}
    app.kubernetes.io/instance: {{ $root.Release.Name }}
    app.kubernetes.io/component: worker
    {{- with $cfg.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $cfg.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: {{ $deadline }}
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "jumi.name" $root }}
        app.kubernetes.io/instance: {{ $root.Release.Name }}
        app.kubernetes.io/component: worker
        {{- with $cfg.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $cfg.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "jumi.jobSA" $root }}
      automountServiceAccountToken: false
      enableServiceLinks: false
      {{- if not (kindIs "invalid" $cfg.hostUsers) }}
      hostUsers: {{ $cfg.hostUsers }}
      {{- end }}
      restartPolicy: Never
      terminationGracePeriodSeconds: 120
      securityContext:
        {{- include "jumi.podSecurityContext" $root | nindent 8 }}
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $cfg.initContainers }}
      initContainers:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: jumi
          image: {{ include "jumi.image" (dict "root" $root "repository" $root.Values.image.worker.repository "tag" $root.Values.image.worker.tag) }}
          imagePullPolicy: {{ $root.Values.image.worker.pullPolicy }}
          args:
            - bun
            - run
            - src/job.ts
          securityContext:
            {{- include "jumi.containerSecurityContext" $root | nindent 12 }}
          env:
            - name: JUMI_JOB_ID
              value: control-fills-in
            {{- include "jumi.databaseEnv" $root | nindent 12 }}
            {{- include "jumi.jobForgeEnv" (dict "root" $root "cfg" $cfg) | nindent 12 }}
            - name: OPENCODE_TIMEOUT_MS
              value: {{ printf "%.0f" (float64 $cfg.timeoutMs) | quote }}
            - name: LEASE_MS
              value: {{ printf "%.0f" (float64 $lease) | quote }}
            - name: HOME
              value: /home/jumi
            - name: WORKDIR
              value: /work
            {{- if $cfg.runnersFile }}
            - name: JUMI_RUNNERS_FILE
              value: {{ printf "/config/%s" $cfg.runnersFile | quote }}
            {{- end }}
            {{- if $root.Values.codex.enabled }}
            - name: CODEX_AUTH_FILE
              value: /codex/auth.json
            {{- end }}
            {{- with $root.Values.jobs.extraEnv }}
            {{ toYaml . | nindent 12 }}
            {{- end }}
            {{- with $cfg.extraEnv }}
            {{ toYaml . | nindent 12 }}
            {{- end }}
          {{- $envFrom := concat $root.Values.jobs.extraEnvFrom $cfg.extraEnvFrom }}
          {{- with $envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml $cfg.resources | nindent 12 }}
          volumeMounts:
            - name: home
              mountPath: /home/jumi
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            {{- if $cfg.runnersFile }}
            - name: config
              mountPath: /config
              readOnly: true
            {{- end }}
            {{- if $root.Values.codex.enabled }}
            - name: codex
              mountPath: /codex
              readOnly: true
            {{- end }}
            {{- range $root.Values.jobs.extraConfigMaps }}
            - name: {{ printf "extra-%s" .name }}
              mountPath: {{ .mountPath }}
              readOnly: true
            {{- end }}
            {{- range $cfg.extraConfigMaps }}
            - name: {{ printf "extra-%s" .name }}
              mountPath: {{ .mountPath }}
              readOnly: true
            {{- end }}
      volumes:
        - name: home
          ephemeral:
            volumeClaimTemplate:
              {{- if or $cfg.volumeClaimLabels $cfg.volumeClaimAnnotations }}
              metadata:
                {{- with $cfg.volumeClaimLabels }}
                labels:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
                {{- with $cfg.volumeClaimAnnotations }}
                annotations:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
              {{- end }}
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: {{ $cfg.homeSize | quote }}
                {{- with $cfg.storageClass }}
                storageClassName: {{ . | quote }}
                {{- end }}
        - name: work
          ephemeral:
            volumeClaimTemplate:
              {{- if or $cfg.volumeClaimLabels $cfg.volumeClaimAnnotations }}
              metadata:
                {{- with $cfg.volumeClaimLabels }}
                labels:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
                {{- with $cfg.volumeClaimAnnotations }}
                annotations:
                  {{- toYaml . | nindent 18 }}
                {{- end }}
              {{- end }}
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: {{ $cfg.workSize | quote }}
                {{- with $cfg.storageClass }}
                storageClassName: {{ . | quote }}
                {{- end }}
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
        {{- if $cfg.runnersFile }}
        - name: config
          configMap:
            name: {{ include "jumi.fullname" $root }}-config
        {{- end }}
        {{- if $root.Values.codex.enabled }}
        - name: codex
          secret:
            secretName: {{ include "jumi.codexSecretName" $root }}
        {{- end }}
        {{- range $root.Values.jobs.extraConfigMaps }}
        - name: {{ printf "extra-%s" .name | quote }}
          configMap:
            name: {{ .name | quote }}
        {{- end }}
        {{- range $cfg.extraConfigMaps }}
        - name: {{ printf "extra-%s" .name | quote }}
          configMap:
            name: {{ .name | quote }}
        {{- end }}
{{- end }}
