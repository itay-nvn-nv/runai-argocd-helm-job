{{/*
Base name for all objects.
*/}}
{{- define "runai-installer.name" -}}
{{- default "runai-installer" .Values.nameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/*
Short hash over everything that should force a new Job: the chart version, the
values passed to the Run:ai chart, the name of the Secret holding sensitive
values, and the manual runCounter. Changing any of them yields new Job and
ConfigMap names, which is what makes a re-run happen.

The contents of secretValues.existingSecret are deliberately not hashed. The
chart never reads the Secret, so rotating it requires bumping runCounter.
*/}}
{{- define "runai-installer.hash" -}}
{{- printf "%s|%s|%s|%v" .Values.chart.version .Values.controlPlaneValues (.Values.secretValues.existingSecret | default "") .Values.runCounter | sha256sum | trunc 8 -}}
{{- end -}}

{{/*
Version rendered for use in object names (dots are not valid there).
*/}}
{{- define "runai-installer.versionSlug" -}}
{{- .Values.chart.version | replace "." "-" | replace "+" "-" | replace "~" "" -}}
{{- end -}}

{{- define "runai-installer.jobName" -}}
{{- printf "%s-%s-%s" (include "runai-installer.name" .) (include "runai-installer.versionSlug" .) (include "runai-installer.hash" .) -}}
{{- end -}}

{{- define "runai-installer.valuesConfigMapName" -}}
{{- printf "%s-values-%s" (include "runai-installer.name" .) (include "runai-installer.hash" .) -}}
{{- end -}}

{{- define "runai-installer.labels" -}}
app.kubernetes.io/name: {{ include "runai-installer.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
runai-installer/target-release: {{ .Values.release.name }}
runai-installer/chart-version: {{ .Values.chart.version | quote }}
{{- end -}}
