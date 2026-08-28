# deploy

Deploys `papeete-foundry-product` — resolves each actor named in
[`../product.yaml`](../product.yaml) against a real registry and runs it, via
[`papeete-deploy`](https://github.com/papeete-hub/papeete-deploy).

```bash
pip install papeete-deploy

papeete-deploy resolve   product.yaml
papeete-deploy deploy    product.yaml
papeete-deploy undeploy  product.yaml
```

Run these **from this repo's root** (where `product.yaml` and `../papeete-deploy.yaml` both
live) — `papeete-deploy.yaml`'s `actorDeployOverrides` paths resolve relative to the current
working directory at invocation time, not to the config file's own location.

`product.yaml`'s `environment.type` is `k8s`, targeting `docker-desktop` — Docker Desktop's local
Kubernetes, the only target `papeete-deploy` verifies against; its node shares the host's own
local Docker image store, so nothing needs pushing to a separate registry. `deploy` applies each
actor's own `deploy/k8s/overlays/develop` (in that actor's own repo — see `../papeete-deploy.yaml`
for where each one actually lives) to the `foundry-local` namespace, creating it if missing, never
deleting it. Every object `deploy` applies is renamed with a `foundry-` prefix, so a sibling actor
is reachable in-cluster only under its *prefixed* Service name (`foundry-<that actor's own Service
name>`, never the bare one) — each actor's own `deploy/k8s/base/deployment.yaml` that calls a
sibling by name already accounts for this.

Each actor image must already exist in the local Docker daemon, tagged
`<name>:<version>-<label>-<shortSha>` (`papeete-actor build`, run in that actor's own repo) —
Docker Desktop's Kubernetes node shares that same daemon's image store, so no push step is needed.

## k8s/ here — product-level resources

`k8s/base` + `k8s/overlays/develop` are this product's own resources, shared across every actor —
per `papeete-deploy`'s own README, "Product-level resources" (`ADR-PD-0004`). `product.yaml`'s
`environment.recipe: develop` opts the product into them, so a plain `papeete-deploy deploy`
applies this folder's `develop` overlay to `foundry-local` alongside every actor's own.

Right now that's one thing: a Grafana dashboard ConfigMap (`grafana-dashboard-configmap.yaml`)
covering every `BNK.RLVR.CAP.SUP.002.BEN` actor together — logs and recent traces, filtered by an
`$service` template variable, the "template-variable drill-down between them" the ADR itself
motivates this feature with. It carries the `grafana_dashboard: "1"` label observability's own
Grafana sidecar already watches cluster-wide (`NAMESPACE=ALL`), so no Grafana-side config change
is needed — dropping the ConfigMap into `foundry-local` is enough. Its two datasources (`loki`,
`tempo`) are observability's own, not invented here.
