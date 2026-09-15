# papeete-foundry-product

The [`papeete-product`](https://github.com/papeete-hub/papeete-product) contract for **foundry** —
the product this repo names and deploys, per [`product.yaml`](./product.yaml).

Foundry is one implement → test → orchestrate loop per capability. Each capability runs three actors,
named here by identity and a version query alone, never a path or a pre-resolved tag:

- `<CAP>-implementation` implements TASK-NNN cards.
- `<CAP>-testing` black-box tests the published image(s).
- `<CAP>-task-orchestration` coordinates the implement → test → retry → PR loop.

| capability | actors |
|---|---|
| `BNK.RLVR.CAP.SUP.002.BEN`, Beneficiary Identity Anchor | `BNK.RLVR.CAP.SUP.002.BEN-{implementation,testing,task-orchestration}` |
| `BNK.RLVR.CAP.BSP.001.SCO`, Behavioural Scoring | `BNK.RLVR.CAP.BSP.001.SCO-{implementation,testing,task-orchestration}` |
| `BNK.RLVR.CAP.BSP.001.TIE`, Tier Management | `BNK.RLVR.CAP.BSP.001.TIE-{implementation,testing,task-orchestration}` |
| `BNK.RLVR.CAP.CHN.001.DSH`, Beneficiary Dashboard | `BNK.RLVR.CAP.CHN.001.DSH-{implementation,testing,task-orchestration}` |

`GetSecrets.sh --k8s` seeds every actor's Secrets from the foundry's two shared credentials, deriving the actors from `product.yaml`.

Resolving these queries against a real registry and actually running them is
[`papeete-deploy`](https://github.com/papeete-hub/papeete-deploy)'s job — see [`deploy/`](./deploy).

`product.yaml`'s `environment.type` is `k8s`, targeting `docker-desktop`'s local Kubernetes. Every
actor image is pulled from an Azure Container Registry, and two of the three build the
capability's own component images in the cluster's shared buildkitd rather than against any
Docker daemon — see [`deploy/`](./deploy) for the prerequisites that implies.

Each actor's declared `name` now matches its own repo exactly, but none of them lives in a
folder that is itself a sibling of `product.yaml` (they're siblings of *this repo*, not folders
inside it) — so `papeete-deploy`'s zero-config sibling convention still can't find them, and
[`papeete-deploy.yaml`](./papeete-deploy.yaml) maps each one explicitly via `actorDeployOverrides`.
