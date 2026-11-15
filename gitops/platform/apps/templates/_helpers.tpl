{{/*
Common pieces of every platform Application. Same shape as the observability
stack's helpers (gitops/observability/apps/templates/_helpers.tpl) -- Helm has
no way to share a template between two charts short of a library chart, and
two copies of thirty lines is cheaper than that.

Sync waves order the Applications: Argo CD syncs wave 0, waits for it to
report Healthy, then wave 1. That works only because the k8s_argocd role
re-enables Argo CD's health check for Application resources.
*/}}

{{- define "platform.metadata" -}}
{{- /* .root = the chart context, .name, .wave */ -}}
name: {{ .name }}
namespace: {{ .root.Values.argocdNamespace }}
labels:
  app.kubernetes.io/part-of: platform
annotations:
  argocd.argoproj.io/sync-wave: {{ .wave | quote }}
# Deleting the Application deletes what it created rather than orphaning it.
finalizers:
  - resources-finalizer.argocd.argoproj.io
{{- end }}

{{/*
A plain-manifest component: a directory (or kustomization) in this repository.
*/}}
{{- define "platform.directoryApplication" -}}
{{- /* .root, .name, .wave, .path, .syncOptions (optional list) */ -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  {{- include "platform.metadata" (dict "root" .root "name" .name "wave" .wave) | nindent 2 }}
spec:
  project: {{ .root.Values.project }}
  source:
    repoURL: {{ .root.Values.repoURL }}
    targetRevision: {{ .root.Values.targetRevision }}
    path: {{ .path }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .root.Values.namespace }}
  syncPolicy:
    automated:
      # prune removes objects whose manifests left the repo; selfHeal reverts
      # kubectl edits made behind Argo CD's back. Together they make the repo
      # the only way to change the stack, which is the point of GitOps.
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
{{- range (.syncOptions | default list) }}
      - {{ . }}
{{- end }}
    retry:
      {{- toYaml .root.Values.retry | nindent 6 }}
{{- end }}
