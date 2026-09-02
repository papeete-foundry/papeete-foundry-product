# deploy

Deploys `papeete-foundry-product` — resolves each actor named in
[`../product.yaml`](../product.yaml) against a real registry and runs it, via
[`papeete-deploy`](https://github.com/papeete-hub/papeete-deploy).

```bash
pip install papeete-deploy

papeete-deploy resolve   product.yaml --registry acr --acr-name papeetefoundry
papeete-deploy deploy    product.yaml --registry acr --acr-name papeetefoundry
papeete-deploy undeploy  product.yaml
papeete-deploy undeploy  product.yaml --delete-namespace   # an ephemeral instance (ADR-PD-0007)
```

## Standing the product up more than once

Nothing here is allocated, so the same product can exist N times over — a per-PR instance beside
the long-lived one. Point `environment.name` at another namespace, seed that namespace's Secrets,
and deploy:

```bash
sed 's/^  name: foundry-local$/  name: foundry-pr123/' product.yaml > product-pr123.yaml
../GetSecrets.sh --k8s --namespace foundry-pr123
papeete-deploy deploy product-pr123.yaml --registry acr --acr-name papeetefoundry
```

Both namespaces then run identical Service names without colliding, because a Service name is
namespaced and no host port is involved anywhere. Tear the instance down completely — namespace
included, since this one exists to be thrown away — with
`papeete-deploy undeploy product-pr123.yaml --delete-namespace`.

## Prerequisites

Three things have to exist before a first deploy, none of them per-actor:

1. **A registry, and a builder.** `papeete-platform`'s `examples/acr-local` creates the ACR plus
   its push and pull tokens; `examples/buildkit-local` runs rootless buildkitd and hands it the
   push credential (`ADR-PL-0002`). Two of the three actors build the capability's component
   images through that builder — no Docker daemon is involved, and no node exposes a socket.
2. **The `acr-pull` Secret in `foundry-local`.** Every actor references it as `imagePullSecrets`,
   and `task-orchestration` copies it into each ephemeral `test-<task_id>` namespace it creates.
3. **The five token Secrets** each actor reads (`…-github`, `…-claude` per building actor, plus
   `task-orchestration`'s own), and **`acr-push`**, which the two building actors mount as their
   own `$DOCKER_CONFIG/config.json` — `buildctl` resolves registry auth client-side, so the
   builder having a credential is not enough. `../GetSecrets.sh` creates all seven, into the
   namespace `product.yaml` declares (or `--namespace NS` for another instance), and its collect
   mode is TTY-only by design so no credential passes through an assistant's context.

On Docker Desktop specifically, the node also needs one `hosts.toml` taking the registry out of
its pull-through mirror's path — `examples/acr-local` writes it, and its README explains why the
mirror cannot serve a private registry. No other cluster needs it.

Run these **from this repo's root** (where `product.yaml` and `../papeete-deploy.yaml` both
live) — `papeete-deploy.yaml`'s `actorDeployOverrides` paths resolve relative to the current
working directory at invocation time, not to the config file's own location.

`product.yaml`'s `environment.type` is `k8s`, targeting `docker-desktop` — Docker Desktop's local
Kubernetes, the only target `papeete-deploy` verifies against. Its node does not, as this file
once claimed, share the host's Docker image store: what it actually has is a **pull-through
mirror**, `kind-registry-mirror`, declared in the node's own `certs.d/_default/hosts.toml` and
backed by the host's containerd store. The distinction matters, because that mirror cannot serve
a private registry at all. `deploy` applies each
actor's own `deploy/k8s/overlays/develop` (in that actor's own repo — see `../papeete-deploy.yaml`
for where each one actually lives) to the `foundry-local` namespace, creating it if missing, never
deleting it. Every object `deploy` applies is renamed with a `foundry-` prefix, so a sibling actor
is reachable in-cluster only under its *prefixed* Service name (`foundry-<that actor's own Service
name>`, never the bare one) — each actor's own `deploy/k8s/base/deployment.yaml` that calls a
sibling by name already accounts for this.

Each actor image must already exist in the registry, tagged
`<version>-<label>-<shortSha>`, under `foundry/<the actor's own normalized name>` — the product's
own name is the repository prefix (`papeete-deploy`'s `ADR-PD-0006`), and the wrapper
kustomization rewrites each base manifest's bare image name to that repository at apply time, so
no actor's own manifest ever names a registry.

## k8s/ here — product-level resources

`k8s/base` + `k8s/overlays/develop` are this product's own resources, shared across every actor —
per `papeete-deploy`'s own README, "Product-level resources" (`ADR-PD-0004`). `product.yaml`'s
`environment.recipe: develop` opts the product into them, so a plain `papeete-deploy deploy`
applies this folder's `develop` overlay to `foundry-local` alongside every actor's own.

Right now that's one thing: a Grafana dashboard ConfigMap (`grafana-dashboard-configmap.yaml`)
covering every `BNK.RLVR.CAP.SUP.002.BEN` actor together — the "template-variable drill-down
between them" the ADR itself motivates this feature with. It carries the `grafana_dashboard: "1"`
label observability's own Grafana sidecar already watches cluster-wide (`NAMESPACE=ALL`), so no
Grafana-side config change is needed — dropping the ConfigMap into `foundry-local` is enough. Its
two datasources (`loki`, `tempo`) are observability's own, not invented here.

Three variables drill into it, and the second and third are what make it a *pipeline* dashboard
rather than three log tails side by side:

- **`$service`** — which actor(s).
- **`$task`** — a `TASK-NNN`. Spans every retry attempt, and all three actors.
- **`$correlation`** — one `orchestrate-task` call. It *is* the trace id: task-orchestration
  already propagates W3C `traceparent` to both peers, so the same 32 hex digits identify the run
  in Loki and open it as one trace in Tempo. Nothing about correlation travels in a door's
  payload.

Every record each actor emits carries both ids — including lines from code none of these repos
own, `HttpMailbox`'s own `do_POST door=… outcome=…` access log most of all. Each actor installs
`correlation.py` at startup: a `logging.Filter` on the root logger's *handlers* (not the logger,
which never sees a named logger's records) that stamps the current thread's ids onto everything
passing through, and the HTTP binding serves each request on its own thread, so request scope and
thread scope are the same thing. That module also carries the `stage()`/`event()` vocabulary the
"Pipeline" panel reads — which is where task-orchestration's teardown, deployment and PR
diagnostics now go, instead of the `print()` calls that only ever reached `kubectl logs`.
