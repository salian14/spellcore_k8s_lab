{{/*
Common pieces of every component Application. Each template under this
directory is one Application; the wave it sits in and anything unusual about
it is commented there, the shared shape is here.

Sync waves are what replace the Ansible role's "install in dependency order
with --wait": Argo CD syncs the wave-0 Applications, waits for them to report
Healthy, then moves to wave 1, and so on. That only works because the
k8s_argocd role re-enables Argo CD's health check for Application resources
(removed from the defaults in 1.8) -- without it every Application is
"Healthy" the moment it exists and the waves collapse into one.

The object store this stack flushes to is NOT one of these Applications: it is
a platform service, and gitops/bootstrap syncs the whole platform stack before
this one. Anything this stack merely consumes belongs there, not here.
*/}}

{{- define "observability.metadata" -}}
{{- /* .root = the chart context, .name, .wave */ -}}
name: {{ .name }}
namespace: {{ .root.Values.argocdNamespace }}
labels:
  app.kubernetes.io/part-of: observability
annotations:
  argocd.argoproj.io/sync-wave: {{ .wave | quote }}
# Deleting the Application deletes what it created rather than orphaning it.
finalizers:
  - resources-finalizer.argocd.argoproj.io
{{- end }}

{{- define "observability.destination" -}}
server: https://kubernetes.default.svc
namespace: {{ .Values.namespace }}
{{- end }}

{{- define "observability.syncPolicy" -}}
{{- /* .root = the chart context, .syncOptions = extra sync options (list) */ -}}
automated:
  # prune removes objects whose manifests left the repo; selfHeal reverts
  # kubectl edits made behind Argo CD's back. Together they make the repo the
  # only way to change the stack, which is the point of GitOps.
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=true
{{- range .syncOptions }}
  - {{ . }}
{{- end }}
retry:
  {{- toYaml .root.Values.retry | nindent 2 }}
{{- end }}

{{/*
A Helm-chart component: chart from its upstream repository, values file from
this repository. Multi-source is what makes that combination possible -- a
single-source Application can read values only from inside the chart.
.chart is one entry of .Values.charts; the values file is named after the
Application.
*/}}
{{- define "observability.helmApplication" -}}
{{- /* .root, .name, .wave, .chart */ -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  {{- include "observability.metadata" (dict "root" .root "name" .name "wave" .wave) | nindent 2 }}
spec:
  project: {{ .root.Values.project }}
  sources:
    - repoURL: {{ .chart.repoURL }}
      chart: {{ .chart.name }}
      targetRevision: {{ .chart.version | quote }}
      helm:
        # Argo CD would otherwise use the Application name, which happens to
        # match -- but the release name is what every object name in the
        # chart derives from (prometheus-server, ...), so it is pinned.
        releaseName: {{ .name }}
        valueFiles:
          - $values/gitops/observability/values/{{ .name }}.yaml
    - repoURL: {{ .root.Values.repoURL }}
      targetRevision: {{ .root.Values.targetRevision }}
      ref: values
  destination:
    {{- include "observability.destination" .root | nindent 4 }}
  syncPolicy:
    {{- include "observability.syncPolicy" (dict "root" .root "syncOptions" list) | nindent 4 }}
{{- end }}

{{/*
A plain-manifest component: a directory (or kustomization) in this repository.
*/}}
{{- define "observability.directoryApplication" -}}
{{- /* .root, .name, .wave, .path, .syncOptions (optional list) */ -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  {{- include "observability.metadata" (dict "root" .root "name" .name "wave" .wave) | nindent 2 }}
spec:
  project: {{ .root.Values.project }}
  source:
    repoURL: {{ .root.Values.repoURL }}
    targetRevision: {{ .root.Values.targetRevision }}
    path: {{ .path }}
  destination:
    {{- include "observability.destination" .root | nindent 4 }}
  syncPolicy:
    {{- include "observability.syncPolicy" (dict "root" .root "syncOptions" (.syncOptions | default list)) | nindent 4 }}
{{- end }}
