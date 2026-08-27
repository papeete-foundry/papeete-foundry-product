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

## k8s/ here — product-level resources (still inert)

`k8s/base` + `k8s/overlays/develop` are a placeholder for resources shared across every actor —
a dashboard, say — per `papeete-deploy`'s own README, "Product-level resources". They stay inert
until `product.yaml`'s `environment` also sets a top-level `recipe`, opting the product into them
(`ADR-PD-0004`) — not set here, since nothing product-level exists to deploy yet.
