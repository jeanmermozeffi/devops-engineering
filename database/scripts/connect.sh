#!/usr/bin/env bash
# =============================================================================
# connect.sh — Sélection interactive du serveur PostgreSQL
#
# Usage:
#   ./connect.sh                             # Menu interactif
#   ./connect.sh --server oscrum-vps        # Sans menu (non-interactif)
#   ./connect.sh --server oscrum-vps db list # Commande pg-admin directe
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config stable hors du clone (~/.config/devops par défaut), repli sur SCRIPT_DIR.
DEVOPS_CONFIG_HOME="${DEVOPS_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/devops}"
if [[ -n "${SERVERS_CONF_FILE:-}" ]]; then
    SERVERS_FILE="$SERVERS_CONF_FILE"
elif [[ -f "$DEVOPS_CONFIG_HOME/servers.conf" ]]; then
    SERVERS_FILE="$DEVOPS_CONFIG_HOME/servers.conf"
else
    SERVERS_FILE="${SCRIPT_DIR}/servers.conf"
fi

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# VÉRIFICATIONS
# =============================================================================

if [[ ! -f "$SERVERS_FILE" ]]; then
    echo -e "${RED}[ERROR]${NC} Fichier servers.conf introuvable."
    echo -e "        Emplacement recommandé (stable) : ${BOLD}$DEVOPS_CONFIG_HOME/servers.conf${NC}"
    echo -e "        Repli (local)                   : ${BOLD}$SCRIPT_DIR/servers.conf${NC}"
    echo -e "        Init : ${BOLD}mkdir -p $DEVOPS_CONFIG_HOME && cp \"$SCRIPT_DIR/servers.conf.example\" \"$DEVOPS_CONFIG_HOME/servers.conf\" && chmod 600 \"$DEVOPS_CONFIG_HOME/servers.conf\"${NC}"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/pg-admin.sh" ]]; then
    echo -e "${RED}[ERROR]${NC} pg-admin.sh introuvable dans : $SCRIPT_DIR"
    exit 1
fi

# =============================================================================
# LECTURE DE servers.conf — tableaux parallèles (compatible bash 3)
# =============================================================================

SECTION_IDS=()
SECTION_DESCS=()
_idx=-1
_current=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # ignorer commentaires et lignes vides
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
        _current="${BASH_REMATCH[1]}"
        _idx=$(( _idx + 1 ))
        SECTION_IDS[$_idx]="$_current"
        SECTION_DESCS[$_idx]=""
        continue
    fi

    if [[ -n "$_current" && "$line" == DESCRIPTION=* ]]; then
        _val="${line#DESCRIPTION=}"
        # supprimer les guillemets englobants
        _val="${_val%\"}"
        _val="${_val#\"}"
        SECTION_DESCS[$_idx]="$_val"
    fi
done < "$SERVERS_FILE"

if [[ ${#SECTION_IDS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Aucun serveur défini dans servers.conf"
    exit 1
fi

# =============================================================================
# MODE NON-INTERACTIF : --server <id> [args...]
# =============================================================================

SELECTED_SECTION=""
SELECTED_IDX=-1
PASSTHROUGH_ARGS=("$@")

if [[ "${1:-}" == "--server" ]]; then
    _target="${2:-}"
    PASSTHROUGH_ARGS=("${@:3}")
    for _i in "${!SECTION_IDS[@]}"; do
        if [[ "${SECTION_IDS[$_i]}" == "$_target" ]]; then
            SELECTED_SECTION="$_target"
            SELECTED_IDX=$_i
            break
        fi
    done
    if [[ -z "$SELECTED_SECTION" ]]; then
        echo -e "${RED}[ERROR]${NC} Serveur inconnu : '$_target'"
        printf "  Disponibles : %s\n" "${SECTION_IDS[*]}"
        exit 1
    fi
fi

# =============================================================================
# MENU INTERACTIF
# =============================================================================

if [[ -z "$SELECTED_SECTION" ]]; then
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}${BOLD}Connexion PostgreSQL — Sélection du serveur${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo ""

    for _i in "${!SECTION_IDS[@]}"; do
        printf "  ${GREEN}[%d]${NC}  %-24s  %s\n" \
            "$(( _i + 1 ))" "${SECTION_IDS[$_i]}" "${SECTION_DESCS[$_i]}"
    done

    echo ""
    while true; do
        read -rp "  Choisir [1-${#SECTION_IDS[@]}] ou 'q' pour quitter : " _choice
        [[ "$_choice" == "q" || "$_choice" == "Q" ]] && echo "Annulé." && exit 0
        if [[ "$_choice" =~ ^[0-9]+$ ]] && \
           (( _choice >= 1 && _choice <= ${#SECTION_IDS[@]} )); then
            SELECTED_IDX=$(( _choice - 1 ))
            SELECTED_SECTION="${SECTION_IDS[$SELECTED_IDX]}"
            break
        fi
        echo -e "  ${YELLOW}Choix invalide.${NC} Entrer un nombre entre 1 et ${#SECTION_IDS[@]}."
    done
fi

# =============================================================================
# EXTRACTION DU PROFIL SÉLECTIONNÉ → FICHIER TEMPORAIRE
# =============================================================================

TEMP_CONF=$(mktemp "${TMPDIR:-/tmp}/pg-connect.XXXXXX")
chmod 600 "$TEMP_CONF"
trap 'rm -f "$TEMP_CONF"' EXIT INT TERM

_in_section=false
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == "$SELECTED_SECTION" ]]; then
            _in_section=true
        elif $_in_section; then
            break   # on a dépassé la section cible
        else
            _in_section=false
        fi
        continue
    fi

    if $_in_section; then
        case "$line" in
            PG_HOST=*|PG_PORT=*|PG_ADMIN_USER=*|PG_ADMIN_PASSWORD=*|\
            PG_DEFAULT_DB=*|USE_SSH=*|SSH_HOST=*|SSH_PORT=*|\
            SSH_USER=*|SSH_KEY=*|DOCKER_CONTAINER=*)
                echo "$line" >> "$TEMP_CONF"
                ;;
        esac
    fi
done < "$SERVERS_FILE"

if [[ ! -s "$TEMP_CONF" ]]; then
    echo -e "${RED}[ERROR]${NC} Impossible d'extraire la config du serveur '$SELECTED_SECTION'"
    exit 1
fi

# =============================================================================
# LANCEMENT
# =============================================================================

echo ""
echo -e "  ${GREEN}[✓]${NC}  Serveur : ${WHITE}${BOLD}${SELECTED_SECTION}${NC}"
_desc="${SECTION_DESCS[$SELECTED_IDX]:-}"
[[ -n "$_desc" ]] && echo -e "       ${_desc}"
echo ""

PG_CONFIG_FILE="$TEMP_CONF" exec "${SCRIPT_DIR}/pg-admin.sh" \
    ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
