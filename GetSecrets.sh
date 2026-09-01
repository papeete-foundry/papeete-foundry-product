#!/usr/bin/env bash
#
# GetSecrets.sh — mint, validate and install the credentials the BNK.RLVR.CAP.SUP.002.BEN
# actors need, WITHOUT any secret value ever passing through an AI assistant's context.
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
# All three actors are ordinary Pods, and each reads its credentials from a k8s Secret its own
# deployment.yaml already names. So this script writes those Secrets, and Claude then deploys
# the product with a command that contains no credential at all and reads none:
#
#     papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry
#
# The values go straight from this file into the cluster. They are never an argument, never on
# stdout, never in a transcript. (kubectl is fed them via --from-file, so they are not visible
# in `ps` either.)
#
# WHAT IT WRITES
#
#   ~/.config/papeete-foundry-local/secrets.env                        0600  canonical store
#   k8s secret bnk-rlvr-cap-sup-002-ben-implementation-github          ns foundry-local
#   k8s secret bnk-rlvr-cap-sup-002-ben-implementation-claude          ns foundry-local
#   k8s secret bnk-rlvr-cap-sup-002-ben-testing-github                 ns foundry-local
#   k8s secret bnk-rlvr-cap-sup-002-ben-testing-claude                 ns foundry-local
#   k8s secret bnk-rlvr-cap-sup-002-ben-task-orchestration-github      ns foundry-local
#   k8s secret acr-pull  (kubernetes.io/dockerconfigjson)              ns foundry-local
#   k8s secret acr-push  (kubernetes.io/dockerconfigjson)              ns foundry-local
#
# WHAT IT OWNS, AND WHAT IT ONLY INSTALLS
#
# It OWNS the five credentials above: each is minted by a human in a browser and exists nowhere
# else, which is exactly what the TTY gate protects.
#
# It does NOT own the registry pull credential. papeete-platform's modules/acr mints that one and
# terraform holds it, so this script reads it from `terraform output` at install time rather than
# storing a second copy. One origin, one place to rotate. A machine-minted credential gains
# nothing from a gate designed to keep a human's browser token out of a transcript.
#
# This script lives beside product.yaml because the Secrets it writes are exactly what THIS
# product's namespace needs — the same reasoning that puts papeete-deploy.yaml here. It carries
# no secret value itself, only the flow that collects them.
#
# The canonical store lives outside every git repo, so it survives a re-clone and cannot be
# committed. Nothing is written inside a repo any more: the actors stopped being host processes
# when image building moved into the cluster, and deploy/local/.env.local went with them.
#
# USAGE
#
#   ./GetSecrets.sh              collect (interactive, TTY-only): guide, prompt, validate, install
#   ./GetSecrets.sh --status     report presence/validity WITHOUT values  [safe for Claude]
#   ./GetSecrets.sh --install    re-install the stored values as k8s Secrets, no prompting
#   ./GetSecrets.sh --k8s        create/update the k8s Secrets only
#   ./GetSecrets.sh --help

set -euo pipefail
set +x                      # never trace: tracing would echo secret values
umask 077                   # everything created below is owner-only

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

STORE_DIR="$HOME/.config/papeete-foundry-local"
STORE="$STORE_DIR/secrets.env"

K8S_NS="foundry-local"

# Each actor's deployment.yaml names these; the key inside every one of them is `token`.
K8S_SECRET_IMPL_GITHUB="bnk-rlvr-cap-sup-002-ben-implementation-github"
K8S_SECRET_IMPL_CLAUDE="bnk-rlvr-cap-sup-002-ben-implementation-claude"
K8S_SECRET_TEST_GITHUB="bnk-rlvr-cap-sup-002-ben-testing-github"
K8S_SECRET_TEST_CLAUDE="bnk-rlvr-cap-sup-002-ben-testing-claude"
K8S_SECRET_ORCH_GITHUB="bnk-rlvr-cap-sup-002-ben-task-orchestration-github"
# The registry pull credential every one of them references as imagePullSecrets.
K8S_SECRET_ACR_PULL="acr-pull"
# The PUSH credential, mounted as $DOCKER_CONFIG/config.json in the two actors that build. It has
# to live client-side: buildctl resolves registry auth itself and hands it to buildkitd, which
# does not authenticate on a remote client's behalf.
K8S_SECRET_ACR_PUSH="acr-push"

ORG="papeete-foundry"
REPO_IMPL="BNK.RLVR.CAP.SUP.002.BEN-implementation"
REPO_TEST="BNK.RLVR.CAP.SUP.002.BEN-testing"

# The five credentials this script OWNS, in collection order. Each one is minted by a human in a
# browser and exists nowhere else — which is what the TTY gate above protects.
#
# The registry pull credential is deliberately NOT here. papeete-platform's modules/acr mints it,
# terraform holds it, and `terraform output` is where it comes from — giving it a second home in
# this store would mean two places to rotate and no way to tell which one is current. This script
# still INSTALLS it (see acr_from_terraform below), because one command putting everything a
# namespace needs in place is the whole point; it just does not own it.
VARS=(
  BEN_IMPLEMENTATION_GITHUB_TOKEN
  BEN_IMPLEMENTATION_CLAUDE_TOKEN
  BEN_TESTING_GITHUB_TOKEN
  BEN_TESTING_CLAUDE_TOKEN
  BEN_TASK_ORCHESTRATION_GITHUB_TOKEN
)

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

# Validate a GitHub token against the scopes its role actually needs.
validate_github() {
  local role="$1" tok="$2" rc=0
  case "$role" in
    BEN_IMPLEMENTATION_GITHUB_TOKEN)
      check_repo "$tok" "$REPO_IMPL"        write || rc=1
      check_repo "$tok" banking-governance  read  || rc=1
      check_repo "$tok" reliever-business   read  || rc=1
      check_repo "$tok" reliever-design     read  || rc=1
      ;;
    BEN_TESTING_GITHUB_TOKEN)
      check_repo "$tok" "$REPO_TEST"        write || rc=1
      check_repo "$tok" "$REPO_IMPL"        read  || rc=1
      check_repo "$tok" banking-governance  read  || rc=1
      check_repo "$tok" reliever-business   read  || rc=1
      check_repo "$tok" reliever-design     read  || rc=1
      ;;
    BEN_TASK_ORCHESTRATION_GITHUB_TOKEN)
      check_repo "$tok" "$REPO_IMPL"        read  || rc=1
      ;;
  esac
  return $rc
}

# The registry pull credential, straight from the source that mints it. Values land in shell
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

# Validate the registry pull token by asking the registry for a pull-scoped bearer token, the
# same exchange a kubelet performs. Credentials go to curl via --config on stdin, never argv.
validate_acr() {
  local server="${ACR_LOGIN_SERVER:-}" user="${ACR_PULL_USERNAME:-}" pass="${ACR_PULL_PASSWORD:-}"
  if [ -z "$server" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    printf '      %s✗%s registry credentials incomplete\n' "$red" "$rst"; return 1
  fi
  local code
  code="$(printf 'user = "%s:%s"\nurl = "https://%s/oauth2/token?service=%s&scope=repository:bnk.rlvr/sup.002.ben/backend:pull"\n' \
            "$user" "$pass" "$server" "$server" \
          | curl -sS --config - -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  case "$code" in
    200) printf '      %s✓%s %-52s pull token accepted\n' "$grn" "$rst" "$server" ;;
    401) printf '      %s✗%s %-52s rejected (401)\n' "$red" "$rst" "$server"; return 1 ;;
    *)   printf '      %s✗%s %-52s HTTP %s\n' "$red" "$rst" "$server" "$code"; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────────────────
# How to obtain each credential — printed immediately before its prompt.
# ─────────────────────────────────────────────────────────────────────────────────────────

guide_github_pat() {
  local role="$1"
  cat <<'COMMON'

  Open:  https://github.com/settings/personal-access-tokens/new

    Token name        anything memorable
    Resource owner    papeete-foundry          <- MUST be the org, not your personal account
    Expiration        your call (90 days is a reasonable default)
    Repository access "Only select repositories", then select exactly the repos listed below

COMMON
  case "$role" in
    BEN_IMPLEMENTATION_GITHUB_TOKEN)
      cat <<COMMON
    Select these 4 repositories:
        $REPO_IMPL
        banking-governance
        reliever-business
        reliever-design

    Repository permissions:
        Contents .................... Read and write
COMMON
      ;;
    BEN_TESTING_GITHUB_TOKEN)
      cat <<COMMON
    Select these 5 repositories:
        $REPO_TEST
        $REPO_IMPL
        banking-governance
        reliever-business
        reliever-design

    Repository permissions:
        Contents .................... Read and write
COMMON
      ;;
    BEN_TASK_ORCHESTRATION_GITHUB_TOKEN)
      cat <<COMMON
    Select this 1 repository:
        $REPO_IMPL

    Repository permissions:
        Contents .................... Read-only
        Pull requests ............... Read and write
COMMON
      ;;
  esac

  if [ "$role" != BEN_TASK_ORCHESTRATION_GITHUB_TOKEN ]; then
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

  The two actors may share one token, or use one each — answer the prompt accordingly.
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

write_store() {
  mkdir -p "$STORE_DIR"
  chmod 700 "$STORE_DIR"
  local tmp
  tmp="$(mktemp "$STORE_DIR/.secrets.XXXXXX")"
  {
    echo "# BNK.RLVR.CAP.SUP.002.BEN credentials — written by GetSecrets.sh on $(date -Iseconds)"
    echo "# 0600, outside every git repo. Never print these; use GetSecrets.sh --status."
    local v
    for v in "${VARS[@]}"; do
      printf "%s='%s'\n" "$v" "${!v}"
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
# of the set: read-only, scoped to this capability's repository paths.
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

  apply_token_secret "$K8S_SECRET_IMPL_GITHUB" "$BEN_IMPLEMENTATION_GITHUB_TOKEN"
  apply_token_secret "$K8S_SECRET_IMPL_CLAUDE" "$BEN_IMPLEMENTATION_CLAUDE_TOKEN"
  apply_token_secret "$K8S_SECRET_TEST_GITHUB" "$BEN_TESTING_GITHUB_TOKEN"
  apply_token_secret "$K8S_SECRET_TEST_CLAUDE" "$BEN_TESTING_CLAUDE_TOKEN"
  apply_token_secret "$K8S_SECRET_ORCH_GITHUB" "$BEN_TASK_ORCHESTRATION_GITHUB_TOKEN"
  apply_acr_pull_secret
  acr_from_terraform >/dev/null 2>&1 && apply_acr_push_secret
}

install_all() {
  hdr "Installing"
  apply_k8s
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

  local v missing=0
  for v in "${VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
      printf '  %s✗%s %-38s absent\n' "$red" "$rst" "$v"
      missing=1
    else
      printf '  %s✓%s %-38s present  fp:%s\n' "$grn" "$rst" "$v" "$(fingerprint "${!v}")"
    fi
  done
  [ "$missing" = 0 ] || return 1

  hdr "Live validation against GitHub"
  local rc=0
  for v in BEN_IMPLEMENTATION_GITHUB_TOKEN BEN_TESTING_GITHUB_TOKEN BEN_TASK_ORCHESTRATION_GITHUB_TOKEN; do
    printf '  %s\n' "$v"
    validate_github "$v" "${!v}" || rc=1
  done
  printf '  %s\n' "registry pull token (from $ACR_TF_DIR)"
  if acr_from_terraform; then
    validate_acr || rc=1
  else
    printf '      %s✗%s could not read it — apply papeete-platform/examples/acr-local\n' "$red" "$rst"
    rc=1
  fi
  info ""
  info "  ${dim}Claude tokens cannot be checked offline; an actor session proves them.${rst}"

  hdr "Installed artefacts"
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    local sec
    for sec in "$K8S_SECRET_IMPL_GITHUB" "$K8S_SECRET_IMPL_CLAUDE" \
               "$K8S_SECRET_TEST_GITHUB" "$K8S_SECRET_TEST_CLAUDE" \
               "$K8S_SECRET_ORCH_GITHUB" "$K8S_SECRET_ACR_PULL" "$K8S_SECRET_ACR_PUSH"; do
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

mode_collect() {
  [ -t 0 ] && [ -t 1 ] || die "refusing to run: collect mode needs a real terminal.
   This is the safeguard that keeps credentials out of an AI assistant's context.
   Open your own terminal and run:  $0
   (An assistant may run '$0 --status', which prints no values.)"

  require curl
  require python3
  require git

  cat <<EOF

${bold}BNK.RLVR.CAP.SUP.002.BEN — credential setup${rst}

Five credentials. For each one you get instructions, then a silent prompt (your
paste is not echoed), then live validation before anything is written.

Nothing is written until all five are collected. Ctrl-C is safe at any point.

Values are written only to:
  $STORE                     (0600, outside every git repo)
  seven k8s Secrets in namespace $K8S_NS
EOF

  local v existing_loaded=0
  if [ -f "$STORE" ]; then
    hdr "An existing store was found"
    info "  $STORE"
    info "  Press Enter at any prompt to keep the currently stored value."
    load_store && existing_loaded=1
  fi

  for v in "${VARS[@]}"; do
    hdr "── $v"
    case "$v" in
      *GITHUB_TOKEN) guide_github_pat "$v" ;;
      *CLAUDE_TOKEN)
        if [ "$v" = BEN_TESTING_CLAUDE_TOKEN ] && [ -n "${BEN_IMPLEMENTATION_CLAUDE_TOKEN:-}" ]; then
          local reuse=""
          printf '\n  Reuse the same Claude token as the implementation actor? [Y/n] '
          read -r reuse || true
          case "${reuse:-Y}" in
            [Nn]*) guide_claude_token ;;
            *) BEN_TESTING_CLAUDE_TOKEN="$BEN_IMPLEMENTATION_CLAUDE_TOKEN"
               info "  ${grn}✓${rst} reusing (fp:$(fingerprint "$BEN_TESTING_CLAUDE_TOKEN"))"
               continue ;;
          esac
        else
          guide_claude_token
        fi
        ;;
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
  done

  hdr "Writing"
  write_store
  install_all

  cat <<EOF

${bold}${grn}Done.${rst}

Claude can now deploy the whole product with a command that contains no
credential, and all three actors are ordinary Pods:

    cd papeete-foundry-product
    papeete-deploy deploy product.yaml --registry acr --acr-name papeetefoundry

Each actor reads its own Secret; none of them reads a file in a repo. Verify any
time, without exposing a value, with:

    ./GetSecrets.sh --status

EOF
  [ "$existing_loaded" = 1 ] && true
}

mode_install() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  local v
  for v in "${VARS[@]}"; do
    [ -n "${!v:-}" ] || die "$v is missing from the store — re-run ./GetSecrets.sh"
  done
  install_all
}

mode_k8s() {
  load_store || die "no store at $STORE — run ./GetSecrets.sh first, in your own terminal"
  local v
  for v in "${VARS[@]}"; do
    [ -n "${!v:-}" ] || die "$v is missing from the store — re-run ./GetSecrets.sh"
  done
  hdr "Applying the k8s Secrets"
  apply_k8s
}

usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  '')            mode_collect ;;
  --status|-s)   mode_status ;;
  --install)     mode_install ;;
  --k8s)         mode_k8s ;;
  --help|-h)     usage ;;
  *)             die "unknown option '$1' — try --help" ;;
esac
