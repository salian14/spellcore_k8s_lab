# Observability for developers

This guide is for whoever is deploying an **application** into this lab and wants
its telemetry to show up in Grafana. It assumes the cluster is already running —
if it isn't, start at the [README](../README.md).

The short version: set a block of `OTEL_*` environment variables pointing at the
collector gateway, and traces, metrics and logs all arrive with no other
infrastructure work. Dashboards and alert rules ship as labelled ConfigMaps in
your own namespace. Nothing here needs a change to the stack's own manifests
under `gitops/observability/`.

For *why* the stack is built the way it is — chart choices, values, the traps
behind each setting — see [`gitops/README.md`](../gitops/README.md#the-observability-stack).
This document only covers using it.

## What you get

| Thing | Address | Notes |
| --- | --- | --- |
| Grafana | <http://192.168.56.10:30300> | `admin` / `lab-observability` |
| Prometheus | <http://192.168.56.10:30090> | for `/targets` and raw PromQL |
| OTLP ingest, gRPC | `otel-collector.observability.svc.cluster.local:4317` | in-cluster only |
| OTLP ingest, HTTP | `otel-collector.observability.svc.cluster.local:4318` | in-cluster only |

Both NodePorts answer on `192.168.56.11` and `.12` as well. The OTLP endpoints
are plain ClusterIP with no TLS and no auth — there is no default-deny
`NetworkPolicy`, so a pod in any namespace can reach them.

Where each signal ends up:

| Signal | Path | Store | Retention |
| --- | --- | --- | --- |
| Traces | app → collector → Tempo | SeaweedFS (S3) | 72h |
| Logs | app → collector → Loki | SeaweedFS (S3) | 168h (7 days) |
| Metrics, pushed | app → collector → Prometheus OTLP receiver | local-path PVC | 15d |
| Metrics, scraped | Prometheus → your `/metrics` | local-path PVC | 15d |
| RED metrics + service graph | Tempo derives them from your spans | local-path PVC | 15d |
| Kubernetes events | collector `k8s_events` receiver → Loki | SeaweedFS (S3) | 168h |

**Pod `stdout`/`stderr` is not collected.** There is no log-scraping DaemonSet on
the nodes, so `kubectl logs` output does not reach Loki. Logs get there by your
application exporting them over OTLP — see [Logs](#logs). This is the assumption
most people arrive with and it is worth un-learning early.

Prometheus is the one component with no object-storage backend, so its 20Gi
volume is the only copy of the metrics. Everything sits on `local-path` volumes,
which means `terraform destroy` takes all of it.

## Wiring an application up

This is nearly the whole job, and it is the same block whatever language you are
in. The OpenTelemetry SDKs all read these variables:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://otel-collector.observability.svc.cluster.local:4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: grpc
  - name: OTEL_SERVICE_NAME
    value: my-app
  - name: OTEL_PROPAGATORS
    value: tracecontext,baggage
  - name: OTEL_TRACES_SAMPLER
    value: parentbased_always_on
  - name: OTEL_METRIC_EXPORT_INTERVAL
    value: "60000"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: service.version=0.1.0,deployment.environment.name=lab
```

| Variable | Value here | Why |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | the collector Service | One gateway takes all three signals |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | Use `http/protobuf` with the `:4318` endpoint instead if your SDK prefers it |
| `OTEL_SERVICE_NAME` | your service | The single most important attribute — see below |
| `OTEL_PROPAGATORS` | `tracecontext,baggage` | W3C headers, so traces join up across services |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | No sampling is configured anywhere; a lab this size can keep every span |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` (ms) | Prometheus scrapes at 30s; pushing faster than that buys nothing |
| `OTEL_RESOURCE_ATTRIBUTES` | version, environment | Only what the collector *can't* work out for itself — see below |

**Always set `OTEL_SERVICE_NAME`.** Unset, the SDK falls back to
`unknown_service`, and that is the name you will be hunting for in Tempo, Loki
and Prometheus alike. It is also the join key for every cross-signal link in
Grafana.

**You do not need to pass the `k8s.*` attributes yourself, and you do not need
the downward API.** The collector runs the `k8sattributes` processor, which
associates every incoming batch with the pod it came from — by `k8s.pod.ip`, then
`k8s.pod.uid`, then falling back to the connection's source address — and stamps
the rest on itself. These are the resource attributes on a span from a pod that
set *none* of them:

```
container.image.name = ghcr.io/open-telemetry/.../telemetrygen
container.image.tag  = v0.158.0
k8s.cluster.uid      = 894ae44c-b8d6-4010-9957-c3e424b1c0b6
k8s.namespace.name   = obs-example
k8s.node.name        = k8s-worker1
k8s.pod.name         = anno-probe
k8s.pod.uid          = 103e5406-5fca-4e46-90c1-6266fefa912b
k8s.pod.start_time   = 2026-08-24T07:57:57Z
k8s.container.name   = telemetrygen
service.namespace    = obs-example
service.instance.id  = obs-example.anno-probe.telemetrygen
```

It also extracts `k8s.deployment.name`, `k8s.replicaset.*`, `k8s.daemonset.*`,
`k8s.statefulset.*`, `k8s.job.*` and `k8s.cronjob.name` where they apply.

Two consequences worth reading twice. **`service.namespace` and
`service.instance.id` are derived**, so you get a distinct `instance` label per
replica without doing anything — passing `$(POD_NAME)` through the downward API
just to set them is redundant. And what is left for `OTEL_RESOURCE_ATTRIBUTES` is
genuinely only what the cluster cannot know: your **version**, your
**environment**, and anything domain-specific.

Attributes your application sets are **not** overwritten, so setting some of
these anyway is harmless belt-and-braces. `service.name` is the exception worth
being deliberate about: the processor will guess it from your
`app.kubernetes.io/name` label or the workload name if you leave it unset, and a
guess is a poor thing to build dashboards on.

The processor also runs with `otel_annotations` enabled, so a pod annotation is a
third way to set any resource attribute without touching the container at all —
verified working in this cluster:

```yaml
metadata:
  annotations:
    resource.opentelemetry.io/deployment.environment.name: lab
    resource.opentelemetry.io/service.version: "0.1.0"
```

Useful when you cannot change the image or its env — otherwise prefer
`OTEL_RESOURCE_ATTRIBUTES`, which keeps the whole declaration in one place.

A complete Deployment using all of this is in
[`examples/observability/instrumented-app.yaml`](../examples/observability/instrumented-app.yaml).

### Python

Everything above is configuration, so the code change is usually nothing at all:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install          # pulls instrumentation for your libs
```

then launch through the agent:

```dockerfile
ENTRYPOINT ["opentelemetry-instrument", "python", "-m", "myapp"]
```

Traces and metrics flow from here. **Logs need one more variable** — the Python
auto-instrumentation does not hook the `logging` module unless you ask:

```yaml
  - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
    value: "true"
```

Custom instruments use the ordinary API, and the naming convention matters —
see [Metrics](#metrics) for what happens to the dots:

```python
from opentelemetry import metrics, trace

meter = metrics.get_meter("myapp")
orders = meter.create_counter("myapp.orders.processed", unit="1")
tracer = trace.get_tracer("myapp")

with tracer.start_as_current_span("process-order") as span:
    span.set_attribute("order.id", order_id)
    orders.add(1, {"result": "ok"})
```

### Go

Go has no auto-instrumentation agent, so the SDK is wired up in `main`. The
exporters read `OTEL_EXPORTER_OTLP_ENDPOINT` on their own, and
`resource.WithFromEnv()` is what picks up `OTEL_SERVICE_NAME` and
`OTEL_RESOURCE_ATTRIBUTES` — miss it and the env block above is ignored:

```go
res, err := resource.New(ctx,
    resource.WithFromEnv(),        // OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES
    resource.WithTelemetrySDK(),
)

texp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithInsecure())
tp := sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(texp),
    sdktrace.WithResource(res),
)
otel.SetTracerProvider(tp)
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{}, propagation.Baggage{},
))

mexp, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithInsecure())
mp := sdkmetric.NewMeterProvider(
    sdkmetric.WithReader(sdkmetric.NewPeriodicReader(mexp)),
    sdkmetric.WithResource(res),
)
otel.SetMeterProvider(mp)

defer tp.Shutdown(ctx)
defer mp.Shutdown(ctx)
```

`WithInsecure()` is correct here — the collector's OTLP listener is plaintext.
For HTTP servers and clients, `otelhttp.NewHandler` and `otelhttp.NewTransport`
give you spans and the standard `http.server.*` / `http.client.*` metrics without
writing any of them by hand.

### Checking it worked

```bash
kubectl -n observability logs deploy/otel-collector --tail=50   # refused connections show up here
```

Then **Grafana → Explore → Tempo → Search**, and pick your service from the
dropdown. If the service name is missing from that list, nothing has arrived yet.

## Traces

Once the env block is set there is nothing more to do for traces. Spans arrive at
Tempo tagged with the `k8s.*` attributes above, which is what makes them
navigable — you can go from a span straight to the pod that emitted it.

Search them in **Explore → Tempo**, either with the Search tab or in TraceQL:

```traceql
{ resource.service.name = "my-app" && duration > 500ms }
{ resource.k8s.namespace.name = "my-namespace" && status = error }
```

**Tempo derives RED metrics from your spans for free.** Its metrics-generator
watches every trace and remote-writes two families into Prometheus, with no
instrumentation on your side beyond emitting spans at all:

| Series | What it is |
| --- | --- |
| `traces_spanmetrics_calls_total` | request count, by service and span |
| `traces_spanmetrics_latency_bucket` / `_count` / `_sum` | duration histogram |
| `traces_spanmetrics_size_total` | span size |
| `traces_service_graph_request_total` | calls between services |
| `traces_service_graph_request_server_seconds_*` | latency, server side |
| `traces_service_graph_request_client_seconds_*` | latency, client side |

The labels on these are `service`, `span_name`, `span_kind` and `status_code` —
note **`service`**, not `service.name`. It is a different label vocabulary from
the OTLP metrics in the next section, living in the same Prometheus, and mixing
them up is the most common reason one of these queries returns nothing:

```promql
sum by (service) (rate(traces_spanmetrics_calls_total[5m]))

sum by (service) (rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
  / sum by (service) (rate(traces_spanmetrics_calls_total[5m]))
```

The **Service Graph** tab on the Tempo datasource renders from
`traces_service_graph_*`. It stays empty until the generator has seen a client
span and its matching server span, which means both sides of a call have to be
instrumented and propagating `traceparent` — that is what `OTEL_PROPAGATORS`
buys you.

```bash
# span metrics for your service should be non-empty within a minute or two
curl -s --get http://192.168.56.10:30090/api/v1/query \
  --data-urlencode 'query=sum by (service) (rate(traces_spanmetrics_calls_total[5m]))'
```

## Metrics

There are two ways in. Pushing over OTLP is the primary one and is what the rest
of this stack is tuned for; annotation-based scraping exists for things that
already expose a `/metrics` endpoint and are never going to speak OTLP.

### Pushing over OTLP

The SDK's meter provider exports to the same collector endpoint as traces. The
collector converts delta temporality to cumulative on the way through
(`deltatocumulative`), so you can leave your SDK on whichever temporality it
prefers — Prometheus gets sane counters either way.

**Metric names keep their dots.** Prometheus is configured with
`translation_strategy: NoUTF8EscapingWithSuffixes`, which appends unit and
`_total` suffixes but does *not* rewrite `.` to `_`. An instrument called
`myapp.orders.processed` is stored as:

```
myapp.orders.processed_total
http.server.request.duration_seconds_bucket
```

**Resource attributes keep their dots too.** Five are promoted onto every series
as labels; the rest stay on a companion `target_info` series:

```
service.name   service.namespace   k8s.namespace.name   k8s.pod.name   k8s.node.name
```

Which means PromQL against your application metrics needs Prometheus 3's UTF-8
quoted syntax — the name goes inside the braces as a quoted string, and so does
any dotted label:

```promql
sum by ("service.name") (rate({"myapp.orders.processed_total"}[5m]))

histogram_quantile(0.95, sum by (le) (rate(
  {__name__="http.server.request.duration_seconds_bucket", "service.name"="my-app"}[5m])))
```

Write `myapp_orders_processed_total` out of habit and you get an empty result
with no error, which is a slow thing to debug. If you would rather not deal with
the quoting, name your instruments with underscores in the first place —
`myapp_orders_processed` comes through unchanged.

**`job` and `instance` are derived.** Prometheus builds them from your resource
attributes rather than from a scrape config:

| Label | Comes from |
| --- | --- |
| `job` | `<service.namespace>/<service.name>`, or just `service.name` if unset |
| `instance` | `service.instance.id` |

Both come from resource attributes the `k8sattributes` processor derives, so each
replica gets a distinct `instance` — `<namespace>.<pod>.<container>` — with no
downward API needed. Set `service.instance.id` yourself only if you want a
different value.

**Exemplars work end to end.** Prometheus runs with `exemplar-storage` enabled
and the Grafana datasource links exemplars into Tempo, so a spike on a histogram
panel can be clicked through to a trace that caused it. Recent SDKs attach
exemplars automatically when a span is active while the measurement is recorded —
no configuration needed, but it only happens inside a span.

### Letting Prometheus scrape you

There is no Prometheus Operator in this cluster, so **`ServiceMonitor`,
`PodMonitor` and `PrometheusRule` do not exist** — `kubectl apply` of one fails
with "no matches for kind". Discovery is annotation-based instead. Annotate the
pod template:

```yaml
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: /metrics      # default /metrics
        prometheus.io/scheme: http        # default http
```

| Annotation | Effect |
| --- | --- |
| `prometheus.io/scrape: "true"` | opt in, at the global 30s interval |
| `prometheus.io/scrape_slow: "true"` | opt in at 5m instead — use for expensive endpoints |
| `prometheus.io/port` | target port; required unless you want the pod's first declared port |
| `prometheus.io/path` | metrics path |
| `prometheus.io/scheme` | `http` or `https` |
| `prometheus.io/param_<name>` | adds `?<name>=...` to the scrape URL |

The same annotations on a **Service** work too, via the
`kubernetes-service-endpoints` job. Use the Service form when you want one target
per endpoint behind the Service; use the pod form when you want one per pod.

Two consequences worth knowing. Everything discovered this way shares a single
`job` label — `kubernetes-pods` or `kubernetes-service-endpoints` — so you filter
by `namespace`, `pod` and your own pod labels, which are mapped onto the series,
rather than by `job`. And scraped metric names are whatever your exporter emits,
with no dots and no translation, so they need none of the quoting above.

```bash
# your pod should appear as UP under the kubernetes-pods job
open http://192.168.56.10:30090/targets
```

## Logs

Logs reach Loki only over OTLP. Point your logging framework's OTLP handler at
the collector — in Python that is the `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED`
variable from earlier; in Go it is `otelslog` over an `otlploggrpc` exporter.

**Loki indexes exactly one label: `service_name`.** Note the underscore — Loki
normalises `service.name` where Prometheus does not, so the same attribute is
spelled differently in the two systems. Everything else your application sends is
attached as *structured metadata*, which is filtered after the stream selector
rather than inside the braces:

```logql
{service_name="my-app"}
{service_name="my-app"} | k8s_namespace_name="my-namespace"
{service_name="my-app"} | severity_text="ERROR" |= "timeout"
{service_name="my-app"} | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
```

Putting `k8s_namespace_name` inside the braces gives an empty result — it is not
an index label. `{service_name="my-app"}` is almost always the right starting
point, narrowed with `|` filters from there.

**`trace_id` and `span_id` arrive automatically** when a log record is emitted
inside an active span, which is what makes the log↔trace jump in Grafana work.
Nothing to configure; just log from inside your instrumented code paths.

**Kubernetes events are a second, free log stream.** The collector's `k8s_events`
receiver forwards them to Loki under `service_name="unknown_service"`, carrying
`k8s_namespace_name`, `k8s_object_kind`, `k8s_object_name` and `k8s_event_reason`
as structured metadata. This is often the fastest way to find out why a pod is
not starting:

```logql
{service_name="unknown_service"} | k8s_namespace_name="my-namespace"
{service_name="unknown_service"} | k8s_event_reason="Failed"
```

Again, `kubectl logs` output is not here. If you need a container's stdout in
Grafana, the application has to export it over OTLP.

## Correlating signals

The datasources are provisioned with links in every direction, which is the main
reason to run all three behind one Grafana. Each link needs something small from
your application:

| Jump | How | Needs from you |
| --- | --- | --- |
| Span → logs | **Logs** button on a span in Tempo | logs exported over OTLP, same `service.name` |
| Log → span | **TraceID** link on a log line in Loki | logging from inside an active span |
| Span → RED metrics | **Metrics** button on a span | nothing — Tempo derives them |
| Metric → trace | exemplar dot on a Prometheus graph | metrics recorded inside a span |
| Service graph | **Service Graph** tab on Tempo | `traceparent` propagated across both sides |

The single dependency running through all of these is a consistent
`service.name`. Set it once, in `OTEL_SERVICE_NAME`, and everything else lines up.

Grafana's **Explore opens on Tempo**, because Tempo is the default datasource
here. Switch the picker for PromQL or LogQL.

## Dashboards

Dashboards are **delegated**: Grafana runs a sidecar watching every namespace for
ConfigMaps labelled `grafana_dashboard`, so your dashboard ships alongside your
application, in your own namespace, with no change to this repo.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-dashboards
  namespace: my-namespace
  labels:
    grafana_dashboard: "1"          # presence matches; the value is ignored
  annotations:
    grafana_folder: "Applications"  # Grafana folder; omit for General
data:
  my-app-overview.json: |
    { ... dashboard JSON ... }
```

Apply it and the dashboard appears within a few seconds. A worked example with
both a span-metrics and an OTLP-metrics panel is in
[`examples/observability/dashboard-configmap.yaml`](../examples/observability/dashboard-configmap.yaml).

Things that will bite otherwise:

- **Pin the datasource UID on every panel.** They are fixed: `prometheus`, `loki`,
  `tempo`. A panel with no explicit datasource resolves to Grafana's *default*,
  which in this stack is **Tempo** — so a PromQL panel renders empty with no error.
- **One dashboard per ConfigMap.** A ConfigMap is capped at 1MiB and real
  dashboards get large; the seven bundled cluster dashboards are one ConfigMap
  each for exactly this reason.
- **Use `kubectl apply --server-side` for large JSON.** A client-side apply also
  stores the whole object in a `last-applied-configuration` annotation, doubling
  it against that 1MiB limit.
- **Provisioned dashboards are read-only in the UI.** The edit loop is: build it
  in Grafana, **Export → JSON**, paste into the ConfigMap, apply. Editing in
  place is not offered, and would be overwritten on the next sidecar sync anyway.
- **Deleting the ConfigMap deletes the dashboard.** That is deliberate — your
  dashboard's lifecycle follows your application's.

When exporting from the UI, strip the `__inputs` and `__requires` blocks and set
`"id": null`. Those are for the import wizard, which file provisioning never runs.

```bash
kubectl -n my-namespace apply -f my-app-dashboards.yaml
kubectl -n observability logs deploy/grafana -c grafana-sc-dashboard --tail=20
curl -s -u admin:lab-observability http://192.168.56.10:30300/api/search | jq '.[].title'
```

## Alerts

Same mechanism, different label. A ConfigMap labelled `grafana_alert` is picked
up by a second sidecar and written into Grafana's alerting provisioning
directory. Alertmanager is not running — Grafana's own embedded alerting is the
path here, so what goes in the ConfigMap is Grafana provisioning YAML:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-alerts
  namespace: my-namespace
  labels:
    grafana_alert: "1"
data:
  my-app-alerts.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: my-app
        folder: Applications      # a `folder:` key, NOT an annotation
        interval: 1m
        rules:
          - uid: my-app-error-rate
            title: my-app error rate above 5%
            condition: C
            for: 5m
            noDataState: NoData
            execErrState: Error
            labels:
              severity: warning
            annotations:
              summary: Error rate for my-app has been above 5% for 5 minutes
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: prometheus
                model:
                  refId: A
                  expr: >-
                    sum(rate(traces_spanmetrics_calls_total{service="my-app",status_code="STATUS_CODE_ERROR"}[5m]))
                    / sum(rate(traces_spanmetrics_calls_total{service="my-app"}[5m]))
                  instant: true
              - refId: C
                datasourceUid: __expr__
                model:
                  refId: C
                  type: threshold
                  expression: A
                  conditions:
                    - evaluator: { type: gt, params: [0.05] }
```

Note the differences from dashboards:

- **The folder is a `folder:` key inside the YAML**, not a `grafana_folder`
  annotation. The alerts sidecar has no folder-annotation support; annotating the
  ConfigMap does nothing. Grafana creates the folder if it doesn't exist.
- **Every query needs an explicit `datasourceUid`.** There is no default to fall
  back on, and `__expr__` is the special uid for server-side expressions —
  threshold, reduce, math.
- **`condition` names the refId that decides.** It has to be a boolean-producing
  expression node, not the raw query.
- **`uid` should be stable.** Change it and you get a second rule rather than an
  edited one.

**With no contact point configured, a firing alert is visible in Grafana's
Alerting UI and goes nowhere else.** That is a reasonable default for a lab. To
route it somewhere, add contact points and a notification policy to the same
file — the sidecar handles all three provisioning types:

```yaml
    contactPoints:
      - orgId: 1
        name: my-app-webhook
        receivers:
          - uid: my-app-webhook
            type: webhook
            settings:
              url: http://my-webhook.my-namespace.svc.cluster.local:8080/alerts
    policies:
      - orgId: 1
        receiver: grafana-default-email
        routes:
          - receiver: my-app-webhook
            object_matchers:
              - [severity, =, warning]
```

A complete example is in
[`examples/observability/alert-configmap.yaml`](../examples/observability/alert-configmap.yaml).

```bash
kubectl -n my-namespace apply -f my-app-alerts.yaml
kubectl -n observability logs deploy/grafana -c grafana-sc-alerts --tail=20
curl -s -u admin:lab-observability \
  http://192.168.56.10:30300/api/v1/provisioning/alert-rules | jq '.[].title'
```

Provisioned rules are read-only in the UI, the same as dashboards. **Unlike
dashboards, deleting the ConfigMap does not delete the rule** — the sidecar
removes the provisioning file and Grafana reloads cleanly, but the rule stays
behind, still evaluating. Grafana only removes a provisioned rule when something
explicitly asks it to, which means a `deleteRules` block:

```yaml
    apiVersion: 1
    deleteRules:
      - orgId: 1
        uid: my-app-error-rate
```

Apply that as a `grafana_alert` ConfigMap, confirm the rule is gone, then delete
both ConfigMaps. It is an easy asymmetry to get caught by when tearing an
application down — the dashboard vanishes with the namespace and the alert
quietly does not.

## Troubleshooting

Roughly in the order worth checking.

- **Nothing at all arrived.** Look at the collector first —
  `kubectl -n observability logs deploy/otel-collector --tail=50`. Connection
  refused or DNS failures from your app show up as export errors in *your* pod's
  logs, not the collector's, so check both ends.
- **Your service is called `unknown_service`.** `OTEL_SERVICE_NAME` isn't
  reaching the SDK. In Go, the usual cause is a `resource.New` without
  `resource.WithFromEnv()`.
- **A PromQL query returns nothing, with no error.** Almost always the dotted
  names. Confirm what is actually stored before debugging the query:
  ```bash
  curl -s http://192.168.56.10:30090/api/v1/label/__name__/values | jq -r '.data[]' | grep -i myapp
  ```
  And remember the two vocabularies: `service` on `traces_spanmetrics_*`,
  `"service.name"` on everything you pushed over OTLP.
- **A Grafana panel is empty but the same query works in Explore.** The panel has
  no explicit datasource and fell through to Tempo. Pin the uid.
- **A scraped endpoint isn't appearing.** <http://192.168.56.10:30090/targets> is
  the page that answers this, and Grafana cannot show it. Check the pod is
  annotated, `Running`, and that `prometheus.io/port` matches a port the container
  actually listens on.
- **The Service Graph tab is empty.** The generator needs paired client and server
  spans. One instrumented side is not enough, and neither is a service that only
  ever receives.
- **A LogQL query returns nothing.** Check you are not filtering on structured
  metadata inside the braces. Start from `{service_name="my-app"}` alone and add
  filters back one at a time.
- **An alert rule you deleted is still firing.** Removing the ConfigMap does not
  remove the rule — see the `deleteRules` block in [Alerts](#alerts).
- **Telemetry vanished after a restart.** `local-path` volumes are directories on
  whichever node the pod first landed on, so those pods can never be rescheduled
  elsewhere — and `terraform destroy` takes the lot.

## See also

- [`README.md`](../README.md#observability) — what the stack is and how to reach it
- [`gitops/README.md`](../gitops/README.md#the-observability-stack) — why every
  chart and value was chosen, and the traps behind them
- [`examples/observability/`](../examples/observability/) — runnable manifests for
  everything in this guide
