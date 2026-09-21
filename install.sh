#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Bootstrap DevOps Tooling
# ============================================================================
#
# Deux modes d'exécution:
#
#   1. Depuis un clone local (comportement habituel):
#      ./install.sh [options]
#
#   2. Bootstrap sans clone préalable (curl | bash):
#      curl -fsSL https://raw.githubusercontent.com/jeanmermozeffi/devops-engineering/main/install.sh | bash
#      curl -fsSL .../install.sh | bash -s -- --scope deployment --non-interactive
#
# Options transmises à devops-manager install:
#   --scope <all|deployment|git-devops|database>
#   --source <managed|local>
#   --repo-url <url>
#   --ref <branch-or-tag>
#   --bin-dir <path>
#   --non-interactive
#   --yes
# ============================================================================

REPO_URL="${DEVOPS_REPO_URL:-https://github.com/jeanmermozeffi/devops-engineering.git}"
DEFAULT_REF="${DEVOPS_REF:-main}"
MANAGED_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/devops-enginering/repo"

_C_CYAN="\033[0;36m"
_C_GREEN="\033[0;32m"
_C_YELLOW="\033[1;33m"
_C_RED="\033[0;31m"
_C_RESET="\033[0m"

_log()  { printf "%b[INFO]%b  %s\n" "$_C_CYAN"   "$_C_RESET" "$*"; }
_ok()   { printf "%b[OK]%b    %s\n" "$_C_GREEN"  "$_C_RESET" "$*"; }
_warn() { printf "%b[WARN]%b  %s\n" "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
_die()  { printf "%b[ERROR]%b %s\n" "$_C_RED"    "$_C_RESET" "$*" >&2; exit 1; }

# Normalise SSH/HTTPS/HTTP en "host/owner/repo" pour comparaison insensible au protocole
_norm_url() {
    local u="$1"
    u="${u%.git}"
    # git@github.com:user/repo → github.com/user/repo
    u="${u#git@}"; u="${u/://}"
    # https://github.com/user/repo → github.com/user/repo
    u="${u#https://}"; u="${u#http://}"
    printf "%s" "$u"
}

# ── Détection: clone local ou bootstrap curl ──────────────────────────────

_LOCAL_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]:-}" != "bash" ]; then
    _candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -f "$_candidate/bin/devops-manager" ]; then
        _LOCAL_DIR="$_candidate"
    fi
fi

if [ -n "$_LOCAL_DIR" ]; then
    # Mode local: déléguer directement au manager du clone
    exec "$_LOCAL_DIR/bin/devops-manager" install "$@"
fi

# ── Mode bootstrap: exécuté via curl | bash ───────────────────────────────

echo ""
printf "%b╔══════════════════════════════════════════════════════╗%b\n" "$_C_CYAN" "$_C_RESET"
printf "%b║  Bootstrap DevOps Tooling                            ║%b\n" "$_C_CYAN" "$_C_RESET"
printf "%b╚══════════════════════════════════════════════════════╝%b\n" "$_C_CYAN" "$_C_RESET"
echo ""

command -v git >/dev/null 2>&1 || _die "git est requis. Installez git et relancez."

_log "Repo   : $REPO_URL"
_log "Ref    : $DEFAULT_REF"
_log "Dossier: $MANAGED_DIR"
echo ""

mkdir -p "$(dirname "$MANAGED_DIR")"

if [ -d "$MANAGED_DIR/.git" ]; then
    _current_remote="$(git -C "$MANAGED_DIR" remote get-url origin 2>/dev/null || true)"
    if [ -n "$_current_remote" ] && \
       [ "$(_norm_url "$_current_remote")" != "$(_norm_url "$REPO_URL")" ]; then
        _warn "Le clone managed existant pointe vers: $_current_remote"
        _warn "Attendu (même dépôt, protocole différent accepté): $REPO_URL"
        _warn "Supprimez $MANAGED_DIR et relancez, ou utilisez --repo-url pour aligner."
        exit 1
    fi
    _log "Clone déjà présent — mise à jour..."
    git -C "$MANAGED_DIR" fetch --tags --prune origin --quiet
    git -C "$MANAGED_DIR" checkout --quiet -B "$DEFAULT_REF" "origin/$DEFAULT_REF" 2>/dev/null || \
        git -C "$MANAGED_DIR" checkout --quiet "$DEFAULT_REF"
    git -C "$MANAGED_DIR" pull --ff-only --quiet origin "$DEFAULT_REF" 2>/dev/null || true
else
    _log "Clonage du dépôt..."
    git clone --branch "$DEFAULT_REF" --quiet "$REPO_URL" "$MANAGED_DIR" || \
        git clone --quiet "$REPO_URL" "$MANAGED_DIR"
fi

_ok "Dépôt prêt: $MANAGED_DIR"
echo ""

# Déléguer l'installation au manager depuis le clone managed
exec "$MANAGED_DIR/bin/devops-manager" install \
    --source managed \
    --repo-url "$REPO_URL" \
    --ref "$DEFAULT_REF" \
    --managed-dir "$MANAGED_DIR" \
    "$@"
