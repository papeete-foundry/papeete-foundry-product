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
one datasource (`loki`) is observability's own, not invented here. The other two in that file are
deliberately unused. Prometheus is provisioned without a `uid`, so nothing portable can name it,
and at this volume `count_over_time` over Loki answers the same questions. Tempo would be the
natural home for a cross-actor waterfall, but it currently holds no spans at all, and its
datasource entry points at port 3100 while the `tempo` Service exposes only 3200 — so a traces
panel could render nothing whatever its query. Both are observability's own config, not ours,
which is why the run's shape is drawn from Loki here instead.

**It holds two dashboards, because there are two questions.** The panels a run-in-progress needs
are not the panels a week of runs needs, and one dashboard trying to be both was mostly the wrong
half at any given moment. Each links to the other, carrying the time range and variables across.

**`BNK.RLVR.CAP.SUP.002.BEN — production`** asks *is the pipeline working*. Counters over a range
(runs started / accepted / refused, retries, failed steps, calls no door accepted), the same
counters as rates over time, p95 per step, what the model work cost — and one panel whose whole
job is to notice a **discrepancy**: steps that started and never ended. `stage()` logs both ends
deliberately, which is what makes "started, never finished" expressible at all; a positive number
there is a step whose process went away mid-flight, which no duration-only record could ever show.
Nothing on this dashboard is scoped to a single run and none of it needs an id to be useful. Its
last panel lists the runs, so the crossing to the other dashboard is a copied correlation id.

**`BNK.RLVR.CAP.SUP.002.BEN — development`** asks *what did the pipeline do*. Five variables drive
it, and the last four are what make it a *pipeline* dashboard rather than three log tails side by
side:

- **`$service`** — which actor(s).
- **`$task`** — a `TASK-NNN`. Spans every retry attempt, and all three actors.
- **`$correlation`** — one `orchestrate-task` call. It *is* the trace id: task-orchestration
  already propagates W3C `traceparent` to both peers, so the same 32 hex digits identify the run
  in Loki and would open it as one trace the day Tempo has spans to open. Nothing about
  correlation travels in a door's payload.
- **`$step`** — one `stage()`/`event()` name, for the drill-down.
- **`$grep`** — a case-insensitive regex over the *rendered* transcript lines.

Its five sections answer that question at five depths. **Runs** hands you a correlation id. **The
run as a shape** is the top of the descent: a *call map* — each actor a node, each `call-*` step an
edge labelled with its real duration — beside *actor lanes*, the same run on a clock with one
filled lane per actor. Both deliberately ignore `$service` and always draw the whole run: the
edges are made of task-orchestration's own records, so filtering the section by actor would strip
out the very lines the picture is drawn from. Clicking a node or a lane narrows everything
*below* instead.
**Flow** is the run read top to bottom — `▸` a step starting, `✔`/`✘` the same step ending with
its duration, `·` a point event — so the handoff *is* the reading order: orchestration →
implementation → orchestration → testing → orchestration, with each peer's own steps nested in
the window of the call that woke it. **Dive into a step**
is the one panel deliberately left raw: at that depth the fields attached to the record — repo,
branch, image, namespace, the exception text — are the point. And **the session, as a terminal**
renders each `claude` session the way the CLI prints it rather than as the JSON it arrives in:

```
▶ claude claude-sonnet-5   ·   /tmp/…-TASK-DASH-001-c_lu5yp3
● I'll start by reading the existing test suite and the capability context.
⏺ Bash(find backend/tests -type f | sort)
  ⎿ find: ‘backend/tests’: No such file or directory
⏺ Read(process.json)
  ⎿ 1 {"schema_version":"1.0.0","engine":{"name":"kpack",…   … +3 lines
⏺ Write(backend/tests/test_health.py)
  ⎿ File created successfully at: backend/tests/test_health.py
■ success   ·   26 turns   ·   166.3s   ·   $1.4821   ·   3163→9854 tok
```

**A tool result is collapsed, the way the CLI collapses one.** This matters more than it
sounds: a single `Read` of a capability context file used to dump *40 kB of JSON* into the
panel, and one of those is enough to bury the whole session. Each `⎿` is now one line with
`… +N lines` after it (`count` over the newlines), the `/tmp/<workdir>/` prefix every path
carries is stripped, and a turn that carries nothing — an empty thinking block — is dropped
rather than rendered as a bare `✻ thinking…`. What is left is the session, not the log; the
untouched record is always one panel down, in *Dive into a step*. Setting `$grep` to `^●`
narrows it to claude's prose alone.

That is `line_format` doing the work in the query, not a change to what the actors emit. Two
things make it honest rather than a guess. The CLI emits one message per content block, so every
transcript record carries exactly **one** element in `blocks` — `blocks[0]` is the turn, not the
first of several. And Loki's `| json` *skips arrays entirely*, so `blocks` is invisible to it: the
second `| json` with explicit expressions (`b_tool="blocks[0].tool_use"`) is what reaches inside,
and it is required rather than stylistic. A nested object addressed that way comes back as its own
JSON string, which is what lets one label stand in as the argument of a tool whose input key the
query did not name individually.

**The call map invents no topology, and is built from logs queries on purpose.** A node is one
*inbound* call, read off `HttpMailbox`'s access log — which is why an actor that *refused* a call
is a node like any other, ringed red with the refusal as its subtitle. An edge is the caller's own
`call-*` step, whose `url` field names the callee; `label_format` rebuilds the callee's exact
`service_name` out of that url, so node and edge join on a value neither side hardcodes. Both are
*logs* queries rather than the metric queries the numbers suggest, and that is forced: Grafana
reads only `nodes[0]` and `edges[0]` — the first frame of each kind — while a Loki metric query
returns one frame *per series*, so `sum by (service_name)` would offer three node frames and draw
exactly one node. A logs query returns a single frame with one row per line, which is the shape
the panel needs. The consequence worth knowing: the map is a **one-run** view. Left at `.+` it
draws every run at once, and an actor called more than once collapses onto one node.

Every record each actor emits carries both ids — including lines from code none of these repos
own, `HttpMailbox`'s own `do_POST door=… outcome=…` access log most of all. Each actor installs
`correlation.py` at startup: a `logging.Filter` on the root logger's *handlers* (not the logger,
which never sees a named logger's records) that stamps the current thread's ids onto everything
passing through, and the HTTP binding serves each request on its own thread, so request scope and
thread scope are the same thing. That module also carries the `stage()`/`event()` vocabulary the
"Flow" panel reads — which is where task-orchestration's teardown, deployment and PR
diagnostics now go, instead of the `print()` calls that only ever reached `kubectl logs`.

**Including the calls no handler ever sees.** A door an actor does not declare, a payload its
card's `request_schema` rejects, a body that is not JSON — none of those reach a handler, so
nothing of ours is there to bind an id. `papeete-actor-synchronous-messaging-http` **0.4.0**
(`ADR-PASH-0005`) is what closes that: it opens its `SERVER` span before routing the path and
before reading the body, and logs and meters one line per call from inside it, so `no-route` and
`bad-request` — which previously produced no span, no metric and no log record whatsoever — are
outcomes like any other. `correlation.py`'s filter then falls back to the active span's trace id,
which is the caller's own. The door panels are the ones that filter on `$correlation`
alone: a call refused before a handler ran has no `task_id`, and requiring one would hide exactly
what those panels are for. A GET to an unknown path has neither id, because it is logged but
deliberately never spanned — a readiness probe every few seconds would bury real calls in a
deployment's traces — which is why those panels carry a second, unscoped query for it.
