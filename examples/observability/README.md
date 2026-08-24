# Observability examples

Runnable companions to
[`docs/observability-for-developers.md`](../../docs/observability-for-developers.md).

| File | What it shows |
| --- | --- |
| `instrumented-app.yaml` | The `OTEL_*` env block a Deployment needs to push traces, metrics and logs at the collector gateway |
| `dashboard-configmap.yaml` | A dashboard shipped from an application's own namespace, with datasource UIDs pinned |
| `alert-configmap.yaml` | A Grafana-managed alert rule shipped the same way |

## Trying them out

`instrumented-app.yaml` references a placeholder image
(`registry.lab:5000/my-app:0.1.0`) — swap in your own before applying it, or
check it renders without deploying:

```bash
kubectl create namespace obs-example
kubectl -n obs-example apply --dry-run=server -f instrumented-app.yaml
```

The two ConfigMaps stand alone and can be applied as-is:

```bash
kubectl -n obs-example apply -f dashboard-configmap.yaml -f alert-configmap.yaml
```

To put real data behind them without building anything, `telemetrygen` emits
spans from any namespace. Tempo's metrics-generator turns those into the
`traces_spanmetrics_*` series the dashboard and alert both query:

```bash
kubectl -n obs-example run telemetrygen --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.158.0 -- \
  traces --otlp-endpoint otel-collector.observability.svc.cluster.local:4317 \
         --otlp-insecure --traces 200 --service my-app
```

Then in Grafana (<http://192.168.56.10:30300>, `admin` / `lab-observability`):

- **Dashboards → Applications → My App / Overview** — the span-metrics panels
  populate within a minute or so.
- **Alerting → Alert rules → Applications → my-app** — the rule is listed and
  evaluating. It is provisioned, so it is read-only in the UI.
- **Explore → Tempo → Search**, service `my-app` — the spans themselves.

Tidy up:

The alert rule needs removing explicitly first — deleting its ConfigMap takes
away the provisioning file but leaves the rule in Grafana, still evaluating:

```bash
kubectl -n obs-example apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-alerts-delete
  labels:
    grafana_alert: "1"
data:
  my-app-alerts-delete.yaml: |
    apiVersion: 1
    deleteRules:
      - orgId: 1
        uid: my-app-error-rate
EOF

kubectl delete namespace obs-example
```

Dashboards need none of that — deleting the ConfigMap removes the dashboard, so
its lifecycle follows the application's. Alert rules are the exception, and it is
worth knowing before you tear something down and wonder why it is still firing.
