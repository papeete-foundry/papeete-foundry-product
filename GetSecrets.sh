#!/usr/bin/env bash
#
# GetSecrets.sh — mint, validate and install the credentials this product's capability actors
# need, WITHOUT any secret value ever passing through an AI assistant's context.
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
# WHY THE ACTORS NEVER NEED CLAUDE TO HANDLE A TOKEN
#
# Every actor is an ordinary Pod, and each reads its credentials from a k8s Secret its own
# deployment.yaml already names. So this script writes those Secrets, and Claude then deploys
# the product with a command that contains no credential at all and reads none:
#
#     papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry
#
# The values go straight from this file into the cluster. They are never an argument, never on
# stdout, never in a transcript. (kubectl is fed them via --from-file, so they are not visible
# in `ps` either.)
#
# ONE ROW PER CAPABILITY
#
# Each capability in CAPABILITIES below runs the same actor trio, so each needs the same five
# credentials. For a capability with key KEY and id CAP (slug = CAP lowercased, dots to dashes):
#
#   store variable                            k8s secret (key `token`, ns <environment.name>)
#   KEY_IMPLEMENTATION_GITHUB_TOKEN           <slug>-implementation-github
#   KEY_IMPLEMENTATION_CLAUDE_TOKEN           <slug>-implementation-claude
#   KEY_TESTING_GITHUB_TOKEN                  <slug>-testing-github
#   KEY_TESTING_CLAUDE_TOKEN                  <slug>-testing-claude
#   KEY_TASK_ORCHESTRATION_GITHUB_TOKEN       <slug>-task-orchestration-github
#
# plus, once per namespace:
#
#   k8s secret acr-pull  (kubernetes.io/dockerconfigjson)
#   k8s secret acr-push  (kubernetes.io/dockerconfigjson)
#
# A capability is added by adding its row. Nothing else in this file names one.
#
# WHAT IT OWNS, AND WHAT IT ONLY INSTALLS
#
# It OWNS the five credentials per capability: each is minted by a human in a browser and exists
# nowhere else, which is exactly what the TTY gate protects.
#
# It does NOT own the registry credentials. papeete-platform's modules/acr mints them and
# terraform holds them, so this script reads them from `terraform output` at install time rather
# than storing a second copy. One origin, one place to rotate. A machine-minted credential gains
# nothing from a gate designed to keep a human's browser token out of a transcript.
#
# This script lives beside product.yaml because the Secrets it writes are exactly what THIS
# product's namespace needs — the same reasoning that puts papeete-deploy.yaml here. It carries
# no secret value itself, only the flow that collects them.
#
# The canonical store (~/.config/papeete-foundry-local/secrets.env, 0600) lives outside every git
# repo, so it survives a re-clone and cannot be committed.
#
# USAGE
#
#   ./GetSecrets.sh              collect (interactive, TTY-only): guide, prompt, validate, install
#   ./GetSecrets.sh --status     report presence/validity WITHOUT values  [safe for Claude]
#   ./GetSecrets.sh --install    re-install the stored values as k8s Secrets, no prompting
#   ./GetSecrets.sh --k8s        create/update the k8s Secrets only
#   ./GetSecrets.sh --help
#
# Every mode takes:
#
#   --capability KEY (-c)   limit it to one capability (repeatable), e.g. --capability SCO.
#                           Without it: collect asks capability by capability; --status reports
#                           every one; --k8s/--install apply every capability that is collected.
#   --namespace NS (-n)     without it the namespace is read from the sibling product.yaml's
#                           environment.name, so the environment is declared in exactly one place.
#                           Pass it to seed an ephemeral instance of the same product:
#
#   ./GetSecrets.sh --k8s --namespace foundry-pr123

set -euo pipefail
set +x                      # never trace: tracing would echo secret values
umask 077                   # everything created below is owner-only

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

STORE_DIR="$HOME/.config/papeete-foundry-local"
STORE="$STORE_DIR/secrets.env"

# The namespace every Secret below is written into. NOT hardcoded: this script lives beside
# product.yaml, so the environment it serves is already declared there (environment.name) and
# repeating it here would create a second place for the two to disagree. --namespace overrides it
# for an ephemeral instance of the same product (a per-PR namespace), which is the whole reason
# the product can be stood up more than once.
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

K8S_NS=""          # resolved at the bottom, after any --namespace has been parsed

# ─────────────────────────────────────────────────────────────────────────────────────────
# The capabilities. KEY|capability id|a registry repository its pull token must reach.
#
# KEY prefixes the store variables and is what --capability takes. It is BEN for the first row
# because that is what the store already holds; a new row picks the capability's own code.
# ─────────────────────────────────────────────────────────────────────────────────────────
CAPABILITIES=(
  "BEN|BNK.RLVR.CAP.SUP.002.BEN|bnk.rlvr/sup.002.ben/backend"
  "SCO|BNK.RLVR.CAP.BSP.001.SCO|bnk.rlvr/bsp.001.sco/stub"
  "TIE|BNK.RLVR.CAP.BSP.001.TIE|bnk.rlvr/bsp.001.tie/stub"
  "DSH|BNK.RLVR.CAP.CHN.001.DSH|bnk.rlvr/chn.001.dsh/bff"
)

declare -A CAP_ID=() CAP_ACR_PATH=()
CAP_KEYS=()
for row in "${CAPABILITIES[@]}"; do
  IFS='|' read -r _key _id _acr <<<"$row"
  CAP_KEYS+=("$_key"); CAP_ID[$_key]="$_id"; CAP_ACR_PATH[$_key]="$_acr"
done
unset row _key _id _acr

# The five roles each capability needs, in collection order.
ROLES=(IMPLEMENTATION_GITHUB IMPLEMENTATION_CLAUDE TESTING_GITHUB TESTING_CLAUDE TASK_ORCHESTRATION_GITHUB)

# The registry pull credential every actor references as imagePullSecrets.
K8S_SECRET_ACR_PULL="acr-pull"
# The PUSH credential, mounted as $DOCKER_CONFIG/config.json in the two actors that build. It has
# to live client-side: buildctl resolves registry auth itself and hands it to buildkitd, which
# does not authenticate on a remote client's behalf.
K8S_SECRET_ACR_PUSH="acr-push"

ORG="papeete-foundry"
# Where the task cards live. The orchestration actor never touches them; when round 0 stops on
# open questions or objections it opens an issue here, labelled task:<capability>/<task_id>
# (ADR-FTOA-0004), because callers name this repo as `report_to`.
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

# ─────────────────────────────────────────────────────────────────────────────────────────
# Names, all derived from a KEY and a role
# ─────────────────────────────────────────────────────────────────────────────────────────

var_name()   { printf '%s_%s_TOKEN' "$1" "$2"; }                      # var_name SCO TESTING_GITHUB
var_key()    { printf '%s' "${1%%_*}"; }                              # SCO_TESTING_GITHUB_TOKEN -> SCO
var_role()   { local r="${1#*_}"; printf '%s' "${r%_TOKEN}"; }        # -> TESTING_GITHUB
role_kind()  { printf '%s' "${1##*_}" | tr '[:upper:]' '[:lower:]'; } # -> github
role_tier()  { printf '%s' "${1%_*}" | tr '[:upper:]_' '[:lower:]-'; } # -> testing / task-orchestration
cap_slug()   { printf '%s' "${CAP_ID[$1]}" | tr '[:upper:].' '[:lower:]-'; }
repo_of()    { printf '%s-%s' "${CAP_ID[$1]}" "$2"; }                 # repo_of SCO implementation

cap_vars() {
  local key="$1" role
  for role in "${ROLES[@]}"; do var_name "$key" "$role"; printf '\n'; done
}

secret_of() {
  local v="$1" role
  role="$(var_role "$v")"
  printf '%s-%s-%s' "$(cap_slug "$(var_key "$v")")" "$(role_tier "$role")" "$(role_kind "$role")"
}

# full | none | partial — how much of one capability the loaded store holds.
cap_state() {
  local v have=0 total=0
  while IFS= read -r v; do
    total=$((total + 1))
    [ -n "${!v:-}" ] && have=$((have + 1))
  done < <(cap_vars "$1")
  if [ "$have" = "$total" ]; then echo full
  elif [ "$have" = 0 ]; then echo none
  else echo partial
  fi
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
#
# check_create <token> <repo> <label> <endpoint>   e.g. check_create "$tok" "$REPO_BACKLOG" issues issues
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

# Validate a GitHub token against the scopes its role actually needs.
# validate_github <store variable> <token>
validate_github() {
  local v="$1" tok="$2" rc=0 key impl test
  key="$(var_key "$v")"
  impl="$(repo_of "$key" implementation)"
  test="$(repo_of "$key" testing)"
  case "$(var_role "$v")" in
    IMPLEMENTATION_GITHUB)
      check_repo "$tok" "$impl"             write || rc=1
      check_repo "$tok" banking-governance  read  || rc=1
      check_repo "$tok" reliever-business   read  || rc=1
      check_repo "$tok" reliever-design     read  || rc=1
      ;;
    TESTING_GITHUB)
      check_repo "$tok" "$test"             write || rc=1
      check_repo "$tok" "$impl"             read  || rc=1
      check_repo "$tok" banking-governance  read  || rc=1
      check_repo "$tok" reliever-business   read  || rc=1
      check_repo "$tok" reliever-design     read  || rc=1
      ;;
    TASK_ORCHESTRATION_GITHUB)
      # Clones impl/<task_id> read-only, and opens the implementation PR.
      check_repo   "$tok" "$impl"           read                        || rc=1
      check_create "$tok" "$impl"           "pull requests" pulls       || rc=1
      # Opens the paired testing PR, and commits the run log there when it is too long to inline.
      check_repo   "$tok" "$test"           write                       || rc=1
      check_create "$tok" "$test"           "pull requests" pulls       || rc=1
      # Sends a stopped round 0 to the backlog as an issue (ADR-FTOA-0004).
      check_repo   "$tok" "$REPO_BACKLOG"   read                        || rc=1
      check_create "$tok" "$REPO_BACKLOG"   issues          issues      || rc=1
      ;;
  esac
  return $rc
}

# The registry credentials, straight from the source that mints them. Values land in shell
# variables and are never printed — `terraform output -raw` writes to this script's own capture,
# not to the terminal.
acr_from_terraform() {
  command -v terraform >/dev/null 2>&1 || { info "  ${ylw}–${rst} terraform not on PATH"; return 1; }
  [ -d "$ACR_TF_DIR" ] || { info "  ${ylw}–${rst} no ACR state at $ACR_TF_DIR"; return 1; }
  ACR_LOGIN_SERVER="$(terraform -chdir="$ACR_TF_DIR" output -raw login_server 2>/dev/null)" || return 1
  ACR_PULL_USERNAME="$(terraform -chdir="$ACR_TF_DIR" output -raw pull_username 2>/dev/null)" || return 1
  ACR_PULL_PASSWORD="$(terraform -chdir="$ACR_TF_DIR" output -raw pull_password 2>/dev/null)" || return 1
  ACR_PUSH_USERNAME="$(terraform -chdir="$ACR_TF_DIR" output -raw push_username 2>/dev/null)" || return 1
  ACR_PUSH_PASSWORD="$(terraform -chdir="$ACR_TF_DIR" output -raw push_password 2>/dev/null)" || return 1
  [ -n "$ACR_LOGIN_SERVER" ] && [ -n "$ACR_PULL_USERNAME" ] && [ -n "$ACR_PULL_PASSWORD" ] \
    && [ -n "$ACR_PUSH_USERNAME" ] && [ -n "$ACR_PUSH_PASSWORD" ]
}

# Validate the registry pull token by asking the registry for a pull-scoped bearer token on one
# capability's repository, the same exchange a kubelet performs. Credentials go to curl via
# --config on stdin, never argv.
# validate_acr <registry repository path>
validate_acr() {
  local path="$1" server="${ACR_LOGIN_SERVER:-}" user="${ACR_PULL_USERNAME:-}" pass="${ACR_PULL_PASSWORD:-}"
  if [ -z "$server" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    printf '      %s✗%s registry credentials incomplete\n' "$red" "$rst"; return 1
  fi
  local code
  code="$(printf 'user = "%s:%s"\nurl = "https://%s/oauth2/token?service=%s&scope=repository:%s:pull"\n' \
            "$user" "$pass" "$server" "$server" "$path" \
          | curl -sS --config - -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  case "$code" in
    200) printf '      %s✓%s %-52s pull token accepted\n' "$grn" "$rst" "$path" ;;
    401) printf '      %s✗%s %-52s rejected (401)\n' "$red" "$rst" "$path"; return 1 ;;
    *)   printf '      %s✗%s %-52s HTTP %s\n' "$red" "$rst" "$path" "$code"; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# How to obtain each credential — printed immediately before its prompt.
# ─────────────────────────────────────────────────────────────────────────────────────────

guide_github_pat() {
  local v="$1" key impl test role
  key="$(var_key "$v")"; role="$(var_role "$v")"
  impl="$(repo_of "$key" implementation)"
  test="$(repo_of "$key" testing)"
  cat <<'COMMON'

  Open:  https://github.com/settings/personal-access-tokens/new

    Token name        anything memorable
    Resource owner    papeete-foundry          <- MUST be the org, not your personal account
    Expiration        your call (90 days is a reasonable default)
    Repository access "Only select repositories", then select exactly the repos listed below

COMMON
  case "$role" in
    IMPLEMENTATION_GITHUB)
      cat <<COMMON
    Select these 4 repositories:
        $impl
        banking-governance
        reliever-business
        reliever-design

    Repository permissions:
        Contents .................... Read and write
COMMON
      ;;
    TESTING_GITHUB)
      cat <<COMMON
    Select these 5 repositories:
        $test
        $impl
        banking-governance
        reliever-business
        reliever-design

    Repository permissions:
        Contents .................... Read and write
COMMON
      ;;
    TASK_ORCHESTRATION_GITHUB)
      cat <<COMMON
    Select these 3 repositories:
        $impl
        $test
        $REPO_BACKLOG

    Repository permissions:
        Contents .................... Read and write
        Issues ...................... Read and write
        Pull requests ............... Read and write

  Why each: it clones $impl and opens the implementation PR there; opens
  the paired PR on $test and commits the test log to its branch (hence Contents
  write — one permission set covers every selected repo); and when round 0 stops on open
  questions or objections, opens an issue on $REPO_BACKLOG. It never edits a task card.
COMMON
      ;;
  esac

  if [ "$role" != TASK_ORCHESTRATION_GITHUB ]; then
    cat <<'COMMON'

  Why "Read and write" across all of them, when the actor only writes to its own repo:
  a fine-grained PAT applies ONE permission set to EVERY repository you select. Write on
  its own repo plus read-only on the three upstreams cannot be expressed in a single
  token, and the engines take exactly one GITHUB_TOKEN. Granting Contents:Read+write over
  the set is the only way to satisfy both halves. The engines only ever push to their own
  repo; kpack and kontract read the other three.
COMMON
  fi

  cat <<'COMMON'

  If the org enforces approval, the token stays "pending" until an owner approves it —
  it will fail validation here until then.
COMMON
}

guide_claude_token() {
  cat <<'COMMON'

  Run, in a terminal on a machine with a browser:

      claude setup-token

  It opens a browser, you authorise, and it prints a token. It must be tied to a
  Pro / Max / Team / Enterprise subscription — that is what makes the actor's headless
  `claude` session spend the subscription credit pool instead of metered API billing.

  Do NOT substitute ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN. Both actors' Dockerfiles
  warn about this: setting either silently routes every session through metered billing.

  Actors may share one token, or use one each — answer the prompt accordingly.
COMMON
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# Store I/O
# ─────────────────────────────────────────────────────────────────────────────────────────

load_store() {
  # Populates the shell with stored values. Callers must never print them.
  [ -f "$STORE" ] || return 1
  set -a
  # shellcheck disable=SC1090
  . "$STORE"
  set +a
}

# Writes every capability's variables that hold a value — including capabilities this run did
# not touch, which were loaded from the existing store first.
write_store() {
  mkdir -p "$STORE_DIR"
  chmod 700 "$STORE_DIR"
  local tmp key v
  tmp="$(mktemp "$STORE_DIR/.secrets.XXXXXX")"
  {
    echo "# papeete-foundry capability credentials — written by GetSecrets.sh on $(date -Iseconds)"
    echo "# 0600, outside every git repo. Never print these; use GetSecrets.sh --status."
    for key in "${CAP_KEYS[@]}"; do
      while IFS= read -r v; do
        [ -n "${!v:-}" ] && printf "%s='%s'\n" "$v" "${!v}"
      done < <(cap_vars "$key")
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STORE"
  info "  ${grn}✓${rst} wrote $STORE (0600)"
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

# The registry pull credential, as the dockerconfigjson type kubelet expects. The password does
# reach kubectl's argv here — `create secret docker-registry` has no --from-file equivalent — so
# it is the one value on this path that a local `ps` could catch, and it is the least privileged
# of the set: read-only, scoped to this product's repository paths.
apply_acr_pull_secret() {
  if ! acr_from_terraform; then
    info "  ${ylw}–${rst} skipping secret/$K8S_SECRET_ACR_PULL and secret/$K8S_SECRET_ACR_PUSH — could not read the registry"
    info "     credentials from $ACR_TF_DIR."
    info "     Apply papeete-platform's examples/acr-local first, then re-run './GetSecrets.sh --k8s'."
    return 0
  fi
  kubectl -n "$K8S_NS" create secret docker-registry "$K8S_SECRET_ACR_PULL" \
      --docker-server="$ACR_LOGIN_SERVER" \
      --docker-username="$ACR_PULL_USERNAME" \
      --docker-password="$ACR_PULL_PASSWORD" \
      --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  info "  ${grn}✓${rst} applied secret/$K8S_SECRET_ACR_PULL in namespace $K8S_NS"
}

apply_acr_push_secret() {
  kubectl -n "$K8S_NS" create secret docker-registry "$K8S_SECRET_ACR_PUSH" \
      --docker-server="$ACR_LOGIN_SERVER" \
      --docker-username="$ACR_PUSH_USERNAME" \
      --docker-password="$ACR_PUSH_PASSWORD" \
      --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  info "  ${grn}✓${rst} applied secret/$K8S_SECRET_ACR_PUSH in namespace $K8S_NS"
}

# apply_k8s <KEY>... — the capabilities whose Secrets to write, each already known to be full.
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

  local key v
  for key in "$@"; do
    while IFS= read -r v; do
      apply_token_secret "$(secret_of "$v")" "${!v}"
    done < <(cap_vars "$key")
  done
  apply_acr_pull_secret
  acr_from_terraform >/dev/null 2>&1 && apply_acr_push_secret
}

# The capabilities --k8s / --install act on: the selected ones that are fully collected. A
# capability named with --capability and not fully collected is an error; one merely present in
# the table is skipped with a note.
installable_caps() {
  local key state
  INSTALL_KEYS=()
  for key in "${SELECTED[@]}"; do
    state="$(cap_state "$key")"
    case "$state" in
      full) INSTALL_KEYS+=("$key") ;;
      partial) die "$key (${CAP_ID[$key]}) is only partly collected — re-run ./GetSecrets.sh --capability $key" ;;
      none)
        [ "$EXPLICIT" = 1 ] && die "$key (${CAP_ID[$key]}) is not collected — run ./GetSecrets.sh --capability $key first, in your own terminal"
        info "  ${dim}– $key (${CAP_ID[$key]}) not collected, skipped${rst}" ;;
    esac
  done
  [ "${#INSTALL_KEYS[@]}" -gt 0 ] || die "no capability is collected — run ./GetSecrets.sh first, in your own terminal"
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# Modes
# ─────────────────────────────────────────────────────────────────────────────────────────

mode_status() {
  # SAFE FOR CLAUDE: presence, fingerprint and verdict only. No values.
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

  local rc=0 key v state collected=()
  for key in "${SELECTED[@]}"; do
    state="$(cap_state "$key")"
    printf '\n  %s%s%s  %s\n' "$bold" "$key" "$rst" "${CAP_ID[$key]}"
    if [ "$state" = none ]; then
      info "    ${dim}– not collected (run ./GetSecrets.sh --capability $key to add it)${rst}"
      continue
    fi
    while IFS= read -r v; do
      if [ -z "${!v:-}" ]; then
        printf '    %s✗%s %-40s absent\n' "$red" "$rst" "$v"
      else
        printf '    %s✓%s %-40s present  fp:%s\n' "$grn" "$rst" "$v" "$(fingerprint "${!v}")"
      fi
    done < <(cap_vars "$key")
    if [ "$state" = partial ]; then rc=1; continue; fi
    collected+=("$key")
  done

  [ "${#collected[@]}" -gt 0 ] || { info ""; info "  nothing collected to validate"; return $rc; }

  hdr "Live validation against GitHub"
  for key in "${collected[@]}"; do
    for v in "$(var_name "$key" IMPLEMENTATION_GITHUB)" "$(var_name "$key" TESTING_GITHUB)" \
             "$(var_name "$key" TASK_ORCHESTRATION_GITHUB)"; do
      printf '  %s\n' "$v"
      validate_github "$v" "${!v}" || rc=1
    done
  done
  printf '  %s\n' "registry pull token (from $ACR_TF_DIR)"
  if acr_from_terraform; then
    for key in "${collected[@]}"; do
      validate_acr "${CAP_ACR_PATH[$key]}" || rc=1
    done
  else
    printf '      %s✗%s could not read it — apply papeete-platform/examples/acr-local\n' "$red" "$rst"
    rc=1
  fi
  info ""
  info "  ${dim}Claude tokens cannot be checked offline; an actor session proves them.${rst}"

  hdr "Installed artefacts"
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    local sec secrets=()
    for key in "${collected[@]}"; do
      while IFS= read -r v; do secrets+=("$(secret_of "$v")"); done < <(cap_vars "$key")
    done
    secrets+=("$K8S_SECRET_ACR_PULL" "$K8S_SECRET_ACR_PUSH")
    for sec in "${secrets[@]}"; do
      if kubectl -n "$K8S_NS" get "secret/$sec" >/dev/null 2>&1; then
        printf '  %s✓%s secret/%-52s ns %s\n' "$grn" "$rst" "$sec" "$K8S_NS"
      else
        printf '  %s✗%s secret/%-52s absent in ns %s\n' "$red" "$rst" "$sec" "$K8S_NS"
      fi
    done
  else
    info "  ${ylw}–${rst} no reachable cluster, cannot report the Secrets"
  fi
  return $rc
}

# Offer an already-held value for variable v — the same capability's implementation Claude token
# for its testing one, or the same role's token from another capability. Sets REUSED=1 when taken.
offer_reuse() {
  local v="$1" key role candidates=() c answer
  key="$(var_key "$v")"; role="$(var_role "$v")"
  REUSED=0
  if [ "$role" = TESTING_CLAUDE ]; then
    candidates+=("$(var_name "$key" IMPLEMENTATION_CLAUDE)")
  fi
  for c in "${CAP_KEYS[@]}"; do
    [ "$c" = "$key" ] && continue
    candidates+=("$(var_name "$c" "$role")")
    [ "$(role_kind "$role")" = claude ] && candidates+=("$(var_name "$c" IMPLEMENTATION_CLAUDE)")
  done
  for c in "${candidates[@]}"; do
    [ -n "${!c:-}" ] || continue
    [ "$c" = "$v" ] && continue
    printf '\n  Reuse the value of %s (fp:%s)? [y/N] ' "$c" "$(fingerprint "${!c}")"
    read -r answer || true
    case "${answer:-N}" in
      [Yy]*) printf -v "$v" '%s' "${!c}"; REUSED=1; return 0 ;;
    esac
  done
}

collect_one() {
  local v="$1"
  hdr "── $v"

  local current="${!v:-}" entered="" prompt="  Paste $v (input hidden): "

  if [ -z "$current" ]; then
    offer_reuse "$v"
    if [ "$REUSED" = 1 ]; then
      entered="${!v}"
      if [ "$(role_kind "$(var_role "$v")")" = github ]; then
        info "  fp:$(fingerprint "$entered")  — validating against GitHub…"
        if validate_github "$v" "$entered"; then
          info "  ${grn}✓ scopes satisfy this actor${rst}"
          return 0
        fi
        info "  ${ylw}that token does not reach this capability's repos — paste another one${rst}"
        printf -v "$v" '%s' ""
      else
        info "  ${grn}✓${rst} reusing (fp:$(fingerprint "$entered"))"
        return 0
      fi
    fi
  fi

  case "$v" in
    *GITHUB_TOKEN) guide_github_pat "$v" ;;
    *CLAUDE_TOKEN) guide_claude_token ;;
  esac
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

    case "$v" in
      *GITHUB_TOKEN)
        info "  fp:$(fingerprint "$entered")  — validating against GitHub…"
        if validate_github "$v" "$entered"; then
          info "  ${grn}✓ scopes satisfy this actor${rst}"
          break
        fi
        local again=""
        printf '\n  Validation failed. Re-enter? [Y/n] '
        read -r again || true
        case "${again:-Y}" in
          [Nn]*) info "  ${ylw}accepting anyway — the live run may fail${rst}"; break ;;
          *) continue ;;
        esac
        ;;
      *)
        info "  ${grn}✓${rst} stored  fp:$(fingerprint "$entered")  ${dim}(not verifiable offline)${rst}"
        break
        ;;
    esac
  done
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

${bold}papeete-foundry — capability credential setup${rst}

Five credentials per capability. For each one you get instructions, then a silent
prompt (your paste is not echoed), then live validation before anything is written.

Nothing is written until every chosen capability is collected. Ctrl-C is safe at any point.

Values are written only to:
  $STORE                     (0600, outside every git repo)
  k8s Secrets in namespace $K8S_NS
EOF

  if [ -f "$STORE" ]; then
    hdr "An existing store was found"
    info "  $STORE"
    info "  Press Enter at any prompt to keep the currently stored value."
    load_store || true
  fi

  local key state answer chosen=() v
  for key in "${SELECTED[@]}"; do
    if [ "$EXPLICIT" = 1 ]; then chosen+=("$key"); continue; fi
    state="$(cap_state "$key")"
    if [ "$state" = none ]; then
      printf '\n  Collect %s (%s)? [y/N] ' "$key" "${CAP_ID[$key]}"
      read -r answer || true
      case "${answer:-N}" in [Yy]*) chosen+=("$key") ;; esac
    else
      printf '\n  Review %s (%s), %s? [Y/n] ' "$key" "${CAP_ID[$key]}" "$state"
      read -r answer || true
      case "${answer:-Y}" in [Nn]*) ;; *) chosen+=("$key") ;; esac
    fi
  done
  [ "${#chosen[@]}" -gt 0 ] || die "no capability chosen — nothing to do"

  for key in "${chosen[@]}"; do
    hdr "━━ $key — ${CAP_ID[$key]}"
    while IFS= read -r v; do
      collect_one "$v"
    done < <(cap_vars "$key")
  done

  hdr "Writing"
  write_store
  hdr "Installing"
  apply_k8s "${chosen[@]}"

  cat <<EOF

${bold}${grn}Done.${rst}

Claude can now deploy the whole product with a command that contains no
credential, and every actor is an ordinary Pod:

    cd papeete-foundry-product
    papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry

Each actor reads its own Secret; none of them reads a file in a repo. Verify any
time, without exposing a value, with:

    ./GetSecrets.sh --status

EOF
}

mode_install() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  installable_caps
  hdr "Installing"
  apply_k8s "${INSTALL_KEYS[@]}"
}

mode_k8s() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  installable_caps
  hdr "Applying the k8s Secrets"
  apply_k8s "${INSTALL_KEYS[@]}"
}

usage() { sed -n '2,82p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --namespace and --capability may appear before or after the mode; everything else is a mode.
mode=""
ns_override=""
SELECTED=()
EXPLICIT=0
add_capability() {
  local want
  want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [ -n "${CAP_ID[$want]:-}" ] || die "unknown capability '$1' — known: ${CAP_KEYS[*]}"
  SELECTED+=("$want"); EXPLICIT=1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n)
      [ $# -ge 2 ] || die "--namespace needs a value"
      ns_override="$2"; shift 2 ;;
    --namespace=*)  ns_override="${1#*=}"; shift ;;
    --capability|-c)
      [ $# -ge 2 ] || die "--capability needs a value"
      add_capability "$2"; shift 2 ;;
    --capability=*) add_capability "${1#*=}"; shift ;;
    --status|-s|--install|--k8s|--help|-h)
      [ -z "$mode" ] || die "give one mode at a time (got '$mode' and '$1')"
      mode="$1"; shift ;;
    *) die "unknown option '$1' — try --help" ;;
  esac
done
[ "$EXPLICIT" = 1 ] || SELECTED=("${CAP_KEYS[@]}")

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

case "$mode" in
  '')            mode_collect ;;
  --status|-s)   mode_status ;;
  --install)     mode_install ;;
  --k8s)         mode_k8s ;;
esac
