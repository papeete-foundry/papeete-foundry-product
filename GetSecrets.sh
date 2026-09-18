#!/usr/bin/env bash
#
# GetSecrets.sh — mint, validate and install the credentials this product's actors need, WITHOUT
# any secret value ever passing through an AI assistant's context.
#
# ─────────────────────────────────────────────────────────────────────────────────────────
# RUN THIS YOURSELF, IN YOUR OWN TERMINAL. NOT THROUGH CLAUDE.
#
# The collect mode refuses to start unless stdin AND stdout are both a real TTY, which is
# exactly what an assistant-run shell does not have. That refusal is the enforcement, not a
# convention: if Claude tries to run it, it aborts before a single prompt is shown.
#
# Claude is expected to run only `GetSecrets.sh --status`, which prints presence, a one-way
# SHA-256 fingerprint and a live validation verdict — never a value.
# ─────────────────────────────────────────────────────────────────────────────────────────
#
# TWO CREDENTIALS, TRANSVERSE TO EVERY ACTOR
#
#   FOUNDRY_GITHUB_TOKEN   one fine-grained PAT on the papeete-foundry organisation, All
#                          repositories: Contents, Issues and Pull requests read and write.
#   FOUNDRY_CLAUDE_TOKEN   one `claude setup-token` token.
#
# Every capability's actors use the same two. A capability added to product.yaml needs no new
# credential, only a re-run of `--k8s` so its Secrets exist in the namespace.
#
# WHY THE ACTORS NEVER NEED CLAUDE TO HANDLE A TOKEN
#
# Every actor is an ordinary Pod, and each reads its credentials from a k8s Secret its own
# deployment.yaml already names. So this script writes those Secrets, and Claude then deploys
# the product with a command that contains no credential at all and reads none:
#
#     papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry
#
# The values go straight from the store into the cluster. They are never an argument, never on
# stdout, never in a transcript. (kubectl is fed them via --from-file, so they are not visible
# in `ps` either.)
#
# WHAT IT WRITES
#
# The actors are read from the sibling product.yaml. For every actor named `<CAP>-<role>`, with
# slug = CAP lowercased, dots to dashes (the names each actor's deployment.yaml references, key
# `token` in each):
#
#   <CAP>-implementation       secret <slug>-implementation-github       ← FOUNDRY_GITHUB_TOKEN
#                              secret <slug>-implementation-claude       ← FOUNDRY_CLAUDE_TOKEN
#   <CAP>-testing              secret <slug>-testing-github              ← FOUNDRY_GITHUB_TOKEN
#                              secret <slug>-testing-claude              ← FOUNDRY_CLAUDE_TOKEN
#   <CAP>-task-orchestration   secret <slug>-task-orchestration-github   ← FOUNDRY_GITHUB_TOKEN
#
# plus, once per namespace, acr-pull and acr-push (kubernetes.io/dockerconfigjson).
#
# WHAT IT OWNS, AND WHAT IT ONLY INSTALLS
#
# It OWNS the two tokens: each is minted by a human in a browser and exists nowhere else, which
# is exactly what the TTY gate protects. It does NOT own the registry credential:
# papeete-platform's modules/acr enables it and terraform holds it, so it is read from
# `terraform output` at install time, never stored a second time.
#
# BOTH REGISTRY SECRETS HOLD THE REGISTRY'S ADMIN ACCOUNT
#
# The registry runs on ACR Basic (papeete-platform ADR-PL-0006), which has no scope maps and no
# tokens. Its one credential is the admin account — examples/acr-local's `username` / `password` —
# so acr-pull and acr-push hold the SAME value. There are two Secrets because the actors' manifests
# name both, not because there are two credentials. That credential is registry-wide and can
# overwrite any tag, including through acr-pull. The way back to a read-only pull and a separate
# push is an Entra service principal per role (AcrPull, AcrPush), not a SKU upgrade.
#
# If terraform cannot produce that credential (an output is missing, or empty, as it is right after
# the apply that first enables the admin account), --install, --k8s and collect stop with an error
# rather than skip the two Secrets, and --status marks both ✗.
#
# The canonical store (~/.config/papeete-foundry-local/secrets.env, 0600) lives outside every git
# repo. A store written by an earlier version of this script (per-actor BEN_* variables) is still
# read: when every legacy GitHub variable holds the same value it becomes FOUNDRY_GITHUB_TOKEN, and
# likewise for Claude. The next collect rewrites the store in the new shape.
#
# USAGE
#
#   ./GetSecrets.sh              collect (interactive, TTY-only): guide, prompt, validate, install
#   ./GetSecrets.sh --status     report presence/validity WITHOUT values  [safe for Claude]
#   ./GetSecrets.sh --install    re-install the stored values as k8s Secrets, no prompting
#   ./GetSecrets.sh --k8s        create/update the k8s Secrets only
#   ./GetSecrets.sh --help
#
# Every mode takes --namespace NS (-n). Without it the namespace is read from product.yaml's
# environment.name. Pass it to seed an ephemeral instance of the same product:
#
#   ./GetSecrets.sh --k8s --namespace foundry-pr123

set -euo pipefail
set +x                      # never trace: tracing would echo secret values
umask 077                   # everything created below is owner-only

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

STORE_DIR="$HOME/.config/papeete-foundry-local"
STORE="$STORE_DIR/secrets.env"

# The product this script serves. Its environment.name is the namespace, and its actors are what
# the Secrets are written for — declared once, there, rather than a second time here.
PRODUCT_YAML="${PAPEETE_PRODUCT_YAML:-$SCRIPT_DIR/product.yaml}"

namespace_from_product() {
  [ -f "$PRODUCT_YAML" ] || return 1
  python3 - "$PRODUCT_YAML" <<'PYEOF' 2>/dev/null
import sys, yaml
try:
    env = (yaml.safe_load(open(sys.argv[1])) or {}).get("environment") or {}
except Exception:
    sys.exit(1)
name = env.get("name")
if not name or env.get("type") != "k8s":
    sys.exit(1)
print(name)
PYEOF
}

# One line per actor: `<capability id>|<role>`, for every actor named `<CAP>-<role>` with a role
# this script knows. Anything else in the product is not one of these actors and needs nothing here.
# `<cap>|<role>|<repo>` per actor. The repo is NOT `<cap>-<role>`: an actor's name and the
# repository it pushes to stopped being the same string the day a capability's three actors moved
# into one repository (BNK.RLVR.CAP.BSP.001.TIE). It is read from that actor's own sidecar — the
# one place that states it — found through papeete-deploy.yaml, which already says where each
# actor's folder is. `<cap>-<role>` remains the fallback for an actor this file cannot locate,
# which is exactly the convention the sidecar would have spelled anyway.
actors_from_product() {
  [ -f "$PRODUCT_YAML" ] || return 1
  python3 - "$PRODUCT_YAML" "$SCRIPT_DIR/papeete-deploy.yaml" <<'PYEOF'
import re, sys, yaml
from pathlib import Path

product, deploy_cfg = Path(sys.argv[1]), Path(sys.argv[2])
doc = yaml.safe_load(product.read_text()) or {}

folders = {}
if deploy_cfg.is_file():
    cfg = yaml.safe_load(deploy_cfg.read_text()) or {}
    for entry in cfg.get("actorDeployOverrides") or []:
        if entry.get("type") == "local" and entry.get("path"):
            folders[str(entry.get("actor"))] = deploy_cfg.parent / str(entry["path"])

def repo_of(name, default):
    sidecar = folders.get(name, Path("/nonexistent")) / "actor-agentic-context.yaml"
    if not sidecar.is_file():
        return default
    declared = (yaml.safe_load(sidecar.read_text()) or {}).get("source_repo")
    # `<owner>/<repo>`; the caller prefixes the org itself, so hand back the repo half only.
    return str(declared).partition("/")[2] if declared else default

for actor in doc.get("actors") or []:
    name = str(actor.get("name", ""))
    m = re.fullmatch(r"(.+)-(implementation|testing|task-orchestration)", name)
    if m:
        print(f"{m.group(1)}|{m.group(2)}|{repo_of(name, name)}")
PYEOF
}

K8S_NS=""          # resolved at the bottom, after any --namespace has been parsed

VARS=(FOUNDRY_GITHUB_TOKEN FOUNDRY_CLAUDE_TOKEN)

# The two registry Secrets, both holding the admin account (see the header): acr-pull, which every
# actor references as imagePullSecrets, and acr-push, which the two building actors mount as
# $DOCKER_CONFIG/config.json (buildctl resolves registry auth client-side; buildkitd does not
# authenticate on a remote client's behalf).
K8S_SECRET_ACR_PULL="acr-pull"
K8S_SECRET_ACR_PUSH="acr-push"

ORG="papeete-foundry"
# The knowledge repos every implementation and testing session's ground_in fetches read.
REPOS_KNOWLEDGE=(banking-governance reliever-business reliever-design)
# Where the task cards live. The orchestration actor never touches them; when round 0 stops on
# open questions or objections it opens an issue here (ADR-FTOA-0004).
REPO_BACKLOG="reliever-implementation"

# Where papeete-platform's ACR example keeps its state. Override with PAPEETE_ACR_DIR if the
# papeete-hub checkout lives somewhere else.
ACR_TF_DIR="${PAPEETE_ACR_DIR:-$SCRIPT_DIR/../../papeete-hub/papeete-platform/examples/acr-local}"

bold=''; dim=''; red=''; grn=''; ylw=''; rst=''
if [ -t 1 ]; then
  bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'
fi

die()  { printf '%s!! %s%s\n' "$red" "$*" "$rst" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s%s\n' "$bold" "$*" "$rst"; }

# One-way fingerprint: lets you confirm WHICH token is stored without revealing any of it.
fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-12
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"
}

cap_slug() { printf '%s' "$1" | tr '[:upper:].' '[:lower:]-'; }

# The product's actors, loaded once: ACTOR_CAPS[i] and ACTOR_ROLES[i].
load_actors() {
  ACTOR_CAPS=(); ACTOR_ROLES=(); ACTOR_REPOS=()
  local line
  while IFS='|' read -r cap role repo; do
    [ -n "$cap" ] || continue
    ACTOR_CAPS+=("$cap"); ACTOR_ROLES+=("$role"); ACTOR_REPOS+=("${repo:-$cap-$role}")
  done < <(actors_from_product || die "could not read the actors from $PRODUCT_YAML")
  [ "${#ACTOR_CAPS[@]}" -gt 0 ] || die "$PRODUCT_YAML names no <CAP>-{implementation,testing,task-orchestration} actor"
}

# Every Secret the product's actors reference, one per line: `<name>|<GITHUB|CLAUDE>`.
secrets_needed() {
  local i slug
  for i in "${!ACTOR_CAPS[@]}"; do
    slug="$(cap_slug "${ACTOR_CAPS[$i]}")"
    printf '%s-%s-github|GITHUB\n' "$slug" "${ACTOR_ROLES[$i]}"
    case "${ACTOR_ROLES[$i]}" in
      implementation|testing) printf '%s-%s-claude|CLAUDE\n' "$slug" "${ACTOR_ROLES[$i]}" ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# Validation. Tokens are passed to curl via --config on stdin, never as an argv element,
# so they are not visible in `ps` to anything else on this machine. Only the HTTP status
# and the parsed permission booleans are ever printed — the response body carries no token.
# ─────────────────────────────────────────────────────────────────────────────────────────

gh_api() {
  # gh_api <token> <path> -> prints "HTTP_CODE<newline>BODY"
  local tok="$1" path="$2"
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nurl = "https://api.github.com%s"\n' \
    "$tok" "$path" \
    | curl -sS --config - -w '\n%{http_code}' 2>/dev/null || true
}

gh_repo_perms() {
  # gh_repo_perms <token> <owner/repo> -> "ok:<pull>:<push>" | "http:<code>"
  local tok="$1" repo="$2" out code body
  out="$(gh_api "$tok" "/repos/$repo")"
  code="$(printf '%s' "$out" | tail -n1)"
  body="$(printf '%s' "$out" | sed '$d')"
  if [ "$code" != "200" ]; then
    printf 'http:%s' "$code"
    return
  fi
  printf '%s' "$body" | python3 -c '
import json,sys
try:
    p = json.load(sys.stdin).get("permissions") or {}
    print("ok:%s:%s" % (bool(p.get("pull")), bool(p.get("push"))))
except Exception:
    print("parse:error")
'
}

# Report one repo requirement. want = "read" | "write"
check_repo() {
  local tok="$1" repo="$2" want="$3" res
  res="$(gh_repo_perms "$tok" "$ORG/$repo")"
  case "$res" in
    ok:True:True)
      printf '      %s✓%s %-52s read+write\n' "$grn" "$rst" "$repo" ;;
    ok:True:False)
      if [ "$want" = read ]; then
        printf '      %s✓%s %-52s read-only\n' "$grn" "$rst" "$repo"
      else
        printf '      %s✗%s %-52s read-only, NEEDS WRITE\n' "$red" "$rst" "$repo"
        return 1
      fi ;;
    http:404)
      printf '      %s✗%s %-52s not visible to this token\n' "$red" "$rst" "$repo"; return 1 ;;
    http:401)
      printf '      %s✗%s %-52s token rejected (401)\n' "$red" "$rst" "$repo"; return 1 ;;
    http:*)
      printf '      %s✗%s %-52s HTTP %s\n' "$red" "$rst" "$repo" "${res#http:}"; return 1 ;;
    *)
      printf '      %s?%s %-52s could not parse response\n' "$ylw" "$rst" "$repo"; return 1 ;;
  esac
}

# Probe whether a token may CREATE on an endpoint, without creating anything.
#
# WHY A PROBE. A fine-grained PAT's per-permission grants (Issues, Pull requests) are not in the
# `permissions` block `GET /repos/{repo}` returns — that block says what the USER may do, so a
# token missing "Issues: write" still reads as push:true there, and the first sign of it used to be
# a live round 0 whose issue silently failed to open. So ask the endpoint itself: POST an empty
# object. GitHub authorises before it validates, so a token holding the permission gets 422 (the
# body lacks a title / head / base) and one without gets 403 — and nothing is ever created.
check_create() {
  local tok="$1" repo="$2" what="$3" endpoint="$4" code
  code="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nrequest = "POST"\ndata = "{}"\nurl = "https://api.github.com/repos/%s/%s/%s"\n' \
            "$tok" "$ORG" "$repo" "$endpoint" \
          | curl -sS --config - -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  case "$code" in
    422) printf '      %s✓%s %-52s %s: write\n' "$grn" "$rst" "$repo" "$what" ;;
    403) printf '      %s✗%s %-52s %s: NEEDS READ AND WRITE\n' "$red" "$rst" "$repo" "$what"; return 1 ;;
    404) printf '      %s✗%s %-52s %s: not visible to this token\n' "$red" "$rst" "$repo" "$what"; return 1 ;;
    401) printf '      %s✗%s %-52s token rejected (401)\n' "$red" "$rst" "$repo"; return 1 ;;
    *)   printf '      %s?%s %-52s %s: unexpected HTTP %s\n' "$ylw" "$rst" "$repo" "$what" "$code"; return 1 ;;
  esac
}

# Validate the one GitHub token against everything the product's actors do with it: each
# implementation and testing actor pushes to its own repo; each orchestrator opens PRs on both
# and an issue on the backlog; every session reads the knowledge repos.
# The repository the actor serving `<cap>` in `<role>` actually pushes to.
repo_for() {
  local cap="$1" role="$2" i
  for i in "${!ACTOR_CAPS[@]}"; do
    if [ "${ACTOR_CAPS[$i]}" = "$cap" ] && [ "${ACTOR_ROLES[$i]}" = "$role" ]; then
      printf '%s' "${ACTOR_REPOS[$i]}"; return 0
    fi
  done
  printf '%s-%s' "$cap" "$role"
}

validate_github() {
  local tok="$1" rc=0 i repo peer_repo peer seen=" " pr_seen=" "
  for i in "${!ACTOR_CAPS[@]}"; do
    repo="${ACTOR_REPOS[$i]}"
    case "$seen" in *" $repo "*) ;; *)
      seen="$seen$repo "
      check_repo "$tok" "$repo" write || rc=1 ;;
    esac
    if [ "${ACTOR_ROLES[$i]}" = task-orchestration ]; then
      # The two PRs this actor opens. Both peers can now answer to ONE repository, so the pair is
      # deduped — otherwise a consolidated capability checks the same repo twice and says so twice.
      for peer in implementation testing; do
        peer_repo="$(repo_for "${ACTOR_CAPS[$i]}" "$peer")"
        case "$pr_seen" in *" $peer_repo "*) continue ;; esac
        pr_seen="$pr_seen$peer_repo "
        check_create "$tok" "$peer_repo" "pull requests" pulls || rc=1
      done
    fi
  done
  for repo in "${REPOS_KNOWLEDGE[@]}"; do
    check_repo "$tok" "$repo" read || rc=1
  done
  check_repo   "$tok" "$REPO_BACKLOG" read          || rc=1
  check_create "$tok" "$REPO_BACKLOG" issues issues || rc=1
  return $rc
}

# The registry's one credential, the admin account, straight from the terraform state that holds
# it. Values land in shell variables and are never printed. On failure ACR_PROBLEM says which
# output let it down, for the caller to report; every output must be present AND non-empty, because
# the apply that first enables the admin account reports success with empty strings.
acr_from_terraform() {
  ACR_LOGIN_SERVER=""; ACR_USERNAME=""; ACR_PASSWORD=""; ACR_PROBLEM=""
  if ! command -v terraform >/dev/null 2>&1; then
    ACR_PROBLEM="terraform is not on PATH"; return 1
  fi
  if [ ! -d "$ACR_TF_DIR" ]; then
    ACR_PROBLEM="no ACR state at $ACR_TF_DIR"; return 1
  fi
  # Output NAMES only: the values go into python on a pipe and only the names come out.
  local names out val
  names=" $(terraform -chdir="$ACR_TF_DIR" output -json 2>/dev/null \
            | python3 -c 'import json, sys; print(" ".join(json.load(sys.stdin)))' 2>/dev/null) " || names=" "
  if [ "$names" = "  " ] || [ "$names" = " " ]; then
    ACR_PROBLEM="no terraform outputs in $ACR_TF_DIR — apply papeete-platform's examples/acr-local"; return 1
  fi
  for out in login_server username password; do
    case "$names" in
      *" $out "*) ;;
      *) ACR_PROBLEM="terraform output '$out' is missing in $ACR_TF_DIR — examples/acr-local predates ADR-PL-0006; pull papeete-platform and apply it"
         return 1 ;;
    esac
    if ! val="$(terraform -chdir="$ACR_TF_DIR" output -raw "$out" 2>/dev/null)"; then
      ACR_PROBLEM="cannot read terraform output '$out' in $ACR_TF_DIR (null when admin_enabled is off)"
      return 1
    fi
    if [ -z "$val" ]; then
      ACR_PROBLEM="terraform output '$out' is empty in $ACR_TF_DIR — if the admin account was just enabled, apply it a second time (modules/acr README)"
      return 1
    fi
    case "$out" in
      login_server) ACR_LOGIN_SERVER="$val" ;;
      username)     ACR_USERNAME="$val" ;;
      password)     ACR_PASSWORD="$val" ;;
    esac
  done
}

# Does secret/<name> hold exactly the credential terraform holds? The Secret's data goes from
# kubectl into python on a pipe and comes back as a SHA-256 of `user:password`, compared here with
# the same hash of terraform's; neither value is printed. Every entry form kubelet honours must
# agree — `auth` wins over username/password when both are set — so a half-patched Secret fails.
secret_holds_acr_credential() {
  local name="$1" have want
  have="$(kubectl -n "$K8S_NS" get "secret/$name" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
    | python3 -c '
import base64, hashlib, json, sys
try:
    auths = json.loads(base64.b64decode(sys.stdin.read())).get("auths") or {}
    entry = auths.get(sys.argv[1]) or auths.get("https://" + sys.argv[1]) or {}
    pairs = set()
    if entry.get("username") or entry.get("password"):
        pairs.add((entry.get("username") or "", entry.get("password") or ""))
    if entry.get("auth"):
        user, _, pw = base64.b64decode(entry["auth"]).decode().partition(":")
        pairs.add((user, pw))
    (user, pw), = pairs
    print(hashlib.sha256(f"{user}:{pw}".encode()).hexdigest() if user and pw else "none")
except Exception:
    print("none")
' "$ACR_LOGIN_SERVER" || true)"
  want="$(printf '%s:%s' "$ACR_USERNAME" "$ACR_PASSWORD" | sha256sum | cut -d' ' -f1)"
  [ "$have" = "$want" ]
}

# Validate the admin credential by asking for a pull-scoped bearer token on each actor's own image
# repository, the same exchange a kubelet performs. There is one credential, so this proves the
# value acr-push carries as well.
validate_acr() {
  local server="${ACR_LOGIN_SERVER:-}" user="${ACR_USERNAME:-}" pass="${ACR_PASSWORD:-}"
  if [ -z "$server" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    printf '      %s✗%s registry credential incomplete\n' "$red" "$rst"; return 1
  fi
  local rc=0 i path code
  for i in "${!ACTOR_CAPS[@]}"; do
    path="foundry/$(printf '%s' "${ACTOR_CAPS[$i]}-${ACTOR_ROLES[$i]}" | tr '[:upper:]' '[:lower:]')"
    code="$(printf 'user = "%s:%s"\nurl = "https://%s/oauth2/token?service=%s&scope=repository:%s:pull"\n' \
              "$user" "$pass" "$server" "$server" "$path" \
            | curl -sS --config - -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    case "$code" in
      200) printf '      %s✓%s %-52s admin credential accepted\n' "$grn" "$rst" "$path" ;;
      401) printf '      %s✗%s %-52s rejected (401)\n' "$red" "$rst" "$path"; rc=1 ;;
      *)   printf '      %s✗%s %-52s HTTP %s\n' "$red" "$rst" "$path" "$code"; rc=1 ;;
    esac
  done
  return $rc
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# How to obtain each credential — printed immediately before its prompt.
# ─────────────────────────────────────────────────────────────────────────────────────────

guide_github_pat() {
  cat <<COMMON

  Open:  https://github.com/settings/personal-access-tokens/new

    Token name        anything memorable
    Resource owner    $ORG          <- MUST be the org, not your personal account
    Expiration        your call (90 days is a reasonable default)
    Repository access "All repositories"

    Repository permissions:
        Contents .................... Read and write
        Issues ...................... Read and write
        Pull requests ............... Read and write

  One token for every actor of every capability. It is validated below against exactly
  what the actors in product.yaml do with it: push to their own repos, open the paired PRs,
  open a round-0 issue on $REPO_BACKLOG, and read the knowledge repos.

  If the org enforces approval, the token stays "pending" until an owner approves it —
  it will fail validation here until then.
COMMON
}

guide_claude_token() {
  cat <<'COMMON'

  Run, in a terminal on a machine with a browser:

      claude setup-token

  It opens a browser, you authorise, and it prints a token. It must be tied to a
  Pro / Max / Team / Enterprise subscription — that is what makes the actors' headless
  `claude` sessions spend the subscription credit pool instead of metered API billing.

  Do NOT substitute ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN: setting either silently
  routes every session through metered billing.
COMMON
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# Store I/O
# ─────────────────────────────────────────────────────────────────────────────────────────

# Populates FOUNDRY_* from the store. Callers must never print them. A legacy store's per-actor
# variables are folded in when they agree; LEGACY_NOTE says what happened, for --status.
load_store() {
  [ -f "$STORE" ] || return 1
  set -a
  # shellcheck disable=SC1090
  . "$STORE"
  set +a
  LEGACY_NOTE=""
  local kind v values distinct
  for kind in GITHUB CLAUDE; do
    v="FOUNDRY_${kind}_TOKEN"
    [ -n "${!v:-}" ] && continue
    values="$(compgen -v | grep -E "^[A-Z]+_(IMPLEMENTATION|TESTING|TASK_ORCHESTRATION)_${kind}_TOKEN$" || true)"
    [ -n "$values" ] || continue
    distinct="$(for n in $values; do [ -n "${!n:-}" ] && printf '%s\n' "${!n}"; done | sort -u | wc -l)"
    if [ "$distinct" = 1 ]; then
      local first
      first="$(printf '%s\n' $values | head -n1)"
      printf -v "$v" '%s' "${!first}"
      LEGACY_NOTE="$LEGACY_NOTE  ${dim}$v read from the legacy per-actor variables (all equal); the next collect rewrites the store${rst}\n"
    elif [ "$distinct" -gt 1 ]; then
      LEGACY_NOTE="$LEGACY_NOTE  ${ylw}!${rst} the legacy per-actor ${kind} tokens differ — re-run ./GetSecrets.sh to pick one\n"
    fi
  done
}

write_store() {
  mkdir -p "$STORE_DIR"
  chmod 700 "$STORE_DIR"
  local tmp v
  tmp="$(mktemp "$STORE_DIR/.secrets.XXXXXX")"
  {
    echo "# papeete-foundry credentials — written by GetSecrets.sh on $(date -Iseconds)"
    echo "# 0600, outside every git repo. Never print these; use GetSecrets.sh --status."
    for v in "${VARS[@]}"; do
      printf "%s='%s'\n" "$v" "${!v}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STORE"
  info "  ${grn}✓${rst} wrote $STORE (0600)"
}

require_store_values() {
  local v
  for v in "${VARS[@]}"; do
    [ -n "${!v:-}" ] || die "$v is missing from the store — run ./GetSecrets.sh yourself, in your own terminal"
  done
}

# One Secret holding one `token` key. --from-file, not --from-literal: keeps the value out of
# kubectl's argv (and out of `ps`).
apply_token_secret() {
  local name="$1" value="$2" tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  printf '%s' "$value" > "$tmp"
  kubectl -n "$K8S_NS" create secret generic "$name" \
      --from-file=token="$tmp" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  rm -f "$tmp"
  info "  ${grn}✓${rst} applied secret/$name in namespace $K8S_NS"
}

# One registry Secret, as the dockerconfigjson kubelet and buildctl read, from the credential
# acr_from_terraform loaded. The JSON is built into a 0600 temp file and handed over with
# --from-file, like the tokens: `create secret docker-registry` would put the password in kubectl's
# argv, where a local `ps` catches it, and that password is the registry's admin account.
apply_acr_secret() {
  local name="$1" tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  printf '%s\n%s\n%s\n' "$ACR_LOGIN_SERVER" "$ACR_USERNAME" "$ACR_PASSWORD" | python3 -c '
import base64, json, sys
server, user, pw = sys.stdin.read().split("\n")[:3]
auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
with open(sys.argv[1], "w") as f:
    json.dump({"auths": {server: {"username": user, "password": pw, "auth": auth}}}, f)
' "$tmp"
  kubectl -n "$K8S_NS" create secret generic "$name" --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$tmp" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  rm -f "$tmp"
  info "  ${grn}✓${rst} applied secret/$name in namespace $K8S_NS  ${dim}(registry admin account)${rst}"
}

# Both registry Secrets from the ONE credential. A credential terraform cannot produce is an error,
# not a skip: skipping is how acr-push kept a destroyed Premium push token for weeks while every
# run of this script looked fine.
apply_acr_secrets() {
  acr_from_terraform || die "cannot write secret/$K8S_SECRET_ACR_PULL or secret/$K8S_SECRET_ACR_PUSH in namespace $K8S_NS:
   $ACR_PROBLEM.
   Fix papeete-platform's examples/acr-local, then re-run './GetSecrets.sh --k8s'."
  apply_acr_secret "$K8S_SECRET_ACR_PULL"
  apply_acr_secret "$K8S_SECRET_ACR_PUSH"
}

apply_k8s() {
  if ! command -v kubectl >/dev/null 2>&1; then
    info "  ${ylw}–${rst} kubectl not on PATH, skipping the k8s Secrets"
    return 0
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    info "  ${ylw}–${rst} no reachable cluster, skipping the k8s Secrets"
    info "     re-run './GetSecrets.sh --k8s' once the cluster is up"
    return 0
  fi
  kubectl create namespace "$K8S_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local name kind v
  while IFS='|' read -r name kind; do
    v="FOUNDRY_${kind}_TOKEN"
    apply_token_secret "$name" "${!v}"
  done < <(secrets_needed)
  apply_acr_secrets
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# Modes
# ─────────────────────────────────────────────────────────────────────────────────────────

mode_status() {
  # SAFE FOR CLAUDE: presence, fingerprint and verdict only. No values.
  hdr "Actors in $(basename "$PRODUCT_YAML")"
  local i
  for i in "${!ACTOR_CAPS[@]}"; do
    info "  ${ACTOR_CAPS[$i]}-${ACTOR_ROLES[$i]}"
  done

  hdr "Credential status"
  if [ ! -f "$STORE" ]; then
    info "  ${red}✗${rst} $STORE does not exist"
    info "     run ./GetSecrets.sh yourself, in a real terminal, to create it"
    return 1
  fi
  local perm
  perm="$(stat -c '%a' "$STORE")"
  info "  store: $STORE (mode $perm)"
  [ "$perm" = 600 ] || info "  ${ylw}!${rst} expected mode 600"

  load_store || die "could not read $STORE"
  [ -z "$LEGACY_NOTE" ] || printf '%b' "$LEGACY_NOTE"

  local v missing=0
  for v in "${VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
      printf '  %s✗%s %-24s absent\n' "$red" "$rst" "$v"
      missing=1
    else
      printf '  %s✓%s %-24s present  fp:%s\n' "$grn" "$rst" "$v" "$(fingerprint "${!v}")"
    fi
  done
  [ "$missing" = 0 ] || return 1

  local rc=0
  hdr "Live validation of FOUNDRY_GITHUB_TOKEN against GitHub"
  validate_github "$FOUNDRY_GITHUB_TOKEN" || rc=1
  printf '  %s\n' "registry admin credential, for acr-pull and acr-push (from $ACR_TF_DIR)"
  local acr_ok=0
  if acr_from_terraform; then
    acr_ok=1
    validate_acr || rc=1
  else
    printf '      %s✗%s %s\n' "$red" "$rst" "$ACR_PROBLEM"
    rc=1
  fi
  info ""
  info "  ${dim}The Claude token cannot be checked offline; an actor session proves it.${rst}"

  hdr "Installed artefacts"
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    local name kind
    while IFS='|' read -r name kind; do
      if kubectl -n "$K8S_NS" get "secret/$name" >/dev/null 2>&1; then
        printf '  %s✓%s secret/%-52s ns %s\n' "$grn" "$rst" "$name" "$K8S_NS"
      else
        printf '  %s✗%s secret/%-52s absent in ns %s\n' "$red" "$rst" "$name" "$K8S_NS"
        rc=1
      fi
    done < <(secrets_needed)
    # The registry Secrets are ✓ only when they hold what terraform holds now. Existing is not
    # enough: a Secret left behind by a rotated credential exists, and cannot pull or push.
    for name in "$K8S_SECRET_ACR_PULL" "$K8S_SECRET_ACR_PUSH"; do
      if [ "$acr_ok" != 1 ]; then
        printf '  %s✗%s secret/%-52s cannot be derived — see the registry credential above\n' "$red" "$rst" "$name"
        rc=1
      elif ! kubectl -n "$K8S_NS" get "secret/$name" >/dev/null 2>&1; then
        printf '  %s✗%s secret/%-52s absent in ns %s\n' "$red" "$rst" "$name" "$K8S_NS"
        rc=1
      elif secret_holds_acr_credential "$name"; then
        printf '  %s✓%s secret/%-52s ns %s, holds the registry admin credential\n' "$grn" "$rst" "$name" "$K8S_NS"
      else
        printf '  %s✗%s secret/%-52s STALE in ns %s — not the credential terraform holds; run ./GetSecrets.sh --k8s\n' "$red" "$rst" "$name" "$K8S_NS"
        rc=1
      fi
    done
  else
    info "  ${ylw}–${rst} no reachable cluster, cannot report the Secrets"
  fi
  return $rc
}

mode_collect() {
  [ -t 0 ] && [ -t 1 ] || die "refusing to run: collect mode needs a real terminal.
   This is the safeguard that keeps credentials out of an AI assistant's context.
   Open your own terminal and run:  $0
   (An assistant may run '$0 --status', which prints no values.)"

  require curl
  require python3
  require git

  cat <<EOF

${bold}papeete-foundry — credential setup${rst}

Two credentials, shared by every actor in $(basename "$PRODUCT_YAML"). For each one you get
instructions, then a silent prompt (your paste is not echoed), then live validation before
anything is written. Ctrl-C is safe at any point.

Values are written only to:
  $STORE                     (0600, outside every git repo)
  k8s Secrets in namespace $K8S_NS
EOF

  if [ -f "$STORE" ]; then
    hdr "An existing store was found"
    info "  $STORE"
    info "  Press Enter at any prompt to keep the currently stored value."
    load_store || true
    [ -z "$LEGACY_NOTE" ] || printf '%b' "$LEGACY_NOTE"
  fi

  local v
  for v in "${VARS[@]}"; do
    hdr "── $v"
    case "$v" in
      FOUNDRY_GITHUB_TOKEN) guide_github_pat ;;
      FOUNDRY_CLAUDE_TOKEN) guide_claude_token ;;
    esac

    local current="${!v:-}" entered="" prompt="  Paste $v (input hidden): "
    [ -n "$current" ] && prompt="  Paste $v (hidden, Enter keeps fp:$(fingerprint "$current")): "

    while :; do
      printf '\n%s' "$prompt"
      IFS= read -rs entered || true
      printf '\n'
      if [ -z "$entered" ] && [ -n "$current" ]; then
        entered="$current"
        info "  ${dim}keeping the stored value${rst}"
      fi
      [ -n "$entered" ] || { info "  ${red}empty — try again${rst}"; continue; }
      case "$entered" in
        *\'*) info "  ${red}contains a single quote, which this store cannot encode — regenerate it${rst}"; continue ;;
        *[[:space:]]*) info "  ${red}contains whitespace — you probably pasted extra characters${rst}"; continue ;;
      esac

      printf -v "$v" '%s' "$entered"

      if [ "$v" = FOUNDRY_GITHUB_TOKEN ]; then
        info "  fp:$(fingerprint "$entered")  — validating against GitHub…"
        if validate_github "$entered"; then
          info "  ${grn}✓ scopes satisfy every actor in the product${rst}"
          break
        fi
        local again=""
        printf '\n  Validation failed. Re-enter? [Y/n] '
        read -r again || true
        case "${again:-Y}" in
          [Nn]*) info "  ${ylw}accepting anyway — the live run may fail${rst}"; break ;;
          *) continue ;;
        esac
      else
        info "  ${grn}✓${rst} stored  fp:$(fingerprint "$entered")  ${dim}(not verifiable offline)${rst}"
        break
      fi
    done
  done

  hdr "Writing"
  write_store
  hdr "Installing"
  apply_k8s

  cat <<EOF

${bold}${grn}Done.${rst}

Claude can now deploy the whole product with a command that contains no
credential, and every actor is an ordinary Pod:

    cd papeete-foundry-product
    papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry

Verify any time, without exposing a value, with:

    ./GetSecrets.sh --status

EOF
}

mode_install() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  require_store_values
  hdr "Installing"
  apply_k8s
}

mode_k8s() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  require_store_values
  hdr "Applying the k8s Secrets"
  apply_k8s
}

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --namespace may appear before or after the mode; everything else is a mode.
mode=""
ns_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n)
      [ $# -ge 2 ] || die "--namespace needs a value"
      ns_override="$2"; shift 2 ;;
    --namespace=*)  ns_override="${1#*=}"; shift ;;
    --status|-s|--install|--k8s|--help|-h)
      [ -z "$mode" ] || die "give one mode at a time (got '$mode' and '$1')"
      mode="$1"; shift ;;
    *) die "unknown option '$1' — try --help" ;;
  esac
done

if [ "$mode" = --help ] || [ "$mode" = -h ]; then
  usage; exit 0
fi

if [ -n "$ns_override" ]; then
  K8S_NS="$ns_override"
elif K8S_NS="$(namespace_from_product)" && [ -n "$K8S_NS" ]; then
  :
else
  die "could not read environment.name from $PRODUCT_YAML — pass --namespace NS, or set
   PAPEETE_PRODUCT_YAML to a k8s product.yaml"
fi

LEGACY_NOTE=""
load_actors

case "$mode" in
  '')            mode_collect ;;
  --status|-s)   mode_status ;;
  --install)     mode_install ;;
  --k8s)         mode_k8s ;;
esac
