# papeete-foundry-product

The [`papeete-product`](https://github.com/papeete-hub/papeete-product) contract for **foundry** —
the product this repo names and deploys, per [`product.yaml`](./product.yaml).

Right now foundry is the `BNK.RLVR.CAP.SUP.002.BEN` implement → test → orchestrate loop: three
actors, named here by identity and a version query alone, never a path or a pre-resolved tag —

- `BNK.RLVR.CAP.SUP.002.BEN-implementation` — implements TASK-NNN cards.
- `BNK.RLVR.CAP.SUP.002.BEN-testing` — black-box tests the published image(s).
- `BNK.RLVR.CAP.SUP.002.BEN-task-orchestration` — coordinates the implement → test → retry → PR loop.

Resolving these queries against a real registry and actually running them is
[`papeete-deploy`](https://github.com/papeete-hub/papeete-deploy)'s job — see [`deploy/`](./deploy).

`product.yaml`'s `environment.type` is `k8s`, targeting `docker-desktop`'s local Kubernetes (its
node shares the host's own local image store, so nothing needs pushing to a separate registry).
Each actor's declared `name` now matches its own repo exactly, but none of the three live in a
folder that is itself a sibling of `product.yaml` (they're siblings of *this repo*, not folders
inside it) — so `papeete-deploy`'s zero-config sibling convention still can't find them, and
[`papeete-deploy.yaml`](./papeete-deploy.yaml) maps each one explicitly via `actorDeployOverrides`.
