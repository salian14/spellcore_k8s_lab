# Istio examples

Runnable companions to the [Service mesh](../../README.md#service-mesh)
section of the root README.

| File | What it shows |
| --- | --- |
| `httpbin.yaml` | A plain HTTP service, nothing Istio-specific in it; the sidecar arrives via the namespace label |
| `gateway.yaml` | Exposing it through the installed ingress gateway with Istio's `Gateway` + `VirtualService` |
| `gateway-api.yaml` | The same route with the Kubernetes Gateway API `Gateway` + `HTTPRoute`; Istio deploys a gateway for it |

## Trying them out

The `default` namespace is labelled for sidecar injection by the `k8s_istio`
role, so deploy there:

```bash
kubectl -n default apply -f httpbin.yaml
kubectl -n default get pods -l app=httpbin     # READY 2/2 -- the second container is the sidecar
kubectl -n default apply -f gateway.yaml       # or gateway-api.yaml, not both
```

Then from the host, through the installed gateway's NodePort:

```bash
curl -s http://192.168.56.10:30880/httpbin/get
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10:30880/httpbin/status/418
```

`gateway-api.yaml` is different: a Gateway API `Gateway` makes Istio deploy a
*new* gateway (`httpbin-gateway-istio`) rather than binding to the installed
one, and its NodePort is allocated rather than fixed. Find it and use it:

```bash
kubectl -n default get gateway httpbin-gateway          # PROGRAMMED True
kubectl -n default get svc httpbin-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}'
curl -s http://192.168.56.10:<that port>/httpbin/get
```

Every request shows up three ways:

- **Access logs** on the gateway and the sidecar:
  `kubectl -n istio-ingress logs deploy/istio-ingressgateway --tail=5` (or
  `deploy/httpbin-gateway-istio` in `default` for the Gateway API one) and
  `kubectl -n default logs deploy/httpbin -c istio-proxy --tail=5`.
- **Metrics** in Prometheus (<http://192.168.56.10:30090>): query
  `istio_requests_total{destination_service_name="httpbin"}`. The lab's
  Prometheus scrapes sidecars through the same `prometheus.io/scrape`
  annotation mechanism the developer guide describes.
- **Traces** in Grafana (<http://192.168.56.10:30300>, Explore → Tempo), service
  `istio-ingressgateway.istio-ingress` or `httpbin.default`. Two spans per
  request -- gateway and sidecar -- because httpbin itself isn't instrumented;
  an app that propagates the `traceparent` header (see
  [`docs/observability-for-developers.md`](../../docs/observability-for-developers.md))
  fills in the middle.

Clean up:

```bash
kubectl -n default delete -f gateway.yaml -f httpbin.yaml   # or gateway-api.yaml
```
