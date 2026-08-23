{{/*
Base name for all objects.
*/}}
{{- define "runai-cluster-installer.name" -}}
{{- default "runai-cluster-installer" .Values.nameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/*
Short hash over everything that should force a new Job: the chart version, the
values passed to the runai-cluster chart, the cluster identity, the name of the
Secret holding sensitive values, and the manual runCounter. Changing any of them
yields new Job and ConfigMap names, which is what makes a re-run happen.
*/}}
{{- define "runai-cluster-installer.hash" -}}
{{- printf "%s|%s|%s|%s|%s|%s|%v"
      .Values.chart.version
      .Values.clusterValues
      .Values.cluster.name
      (.Values.cluster.uid | default "")
      (.Values.secretValues.existingSecret | default "")
      (.Values.setOverrides | toYaml)
      .Values.runCounter
    | sha256sum | trunc 8 -}}
{{- end -}}

{{/*
Version rendered for use in object names (dots are not valid there).
*/}}
{{- define "runai-cluster-installer.versionSlug" -}}
{{- .Values.chart.version | replace "." "-" | replace "+" "-" | replace "~" "" -}}
{{- end -}}

{{- define "runai-cluster-installer.jobName" -}}
{{- printf "%s-%s-%s" (include "runai-cluster-installer.name" .) (include "runai-cluster-installer.versionSlug" .) (include "runai-cluster-installer.hash" .) -}}
{{- end -}}

{{- define "runai-cluster-installer.valuesConfigMapName" -}}
{{- printf "%s-values-%s" (include "runai-cluster-installer.name" .) (include "runai-cluster-installer.hash" .) -}}
{{- end -}}

{{- define "runai-cluster-installer.labels" -}}
app.kubernetes.io/name: {{ include "runai-cluster-installer.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
runai-installer/target-release: {{ .Values.cluster.releaseName }}
runai-installer/chart-version: {{ .Values.chart.version | quote }}
{{- end -}}

{{/*
The cluster URL. Empty means "same URL as the control plane", which is the
wizard's default answer for a single-cluster install.
*/}}
{{- define "runai-cluster-installer.clusterUrl" -}}
{{- .Values.cluster.url | default .Values.controlPlane.url -}}
{{- end -}}
