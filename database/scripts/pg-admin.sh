#!/usr/bin/env bash
# =============================================================================
# pg-admin.sh — PostgreSQL Admin CLI v3.0 — CICBI
# Consolidation de pg-manager.sh + pg-manager-v2.sh
#
# Fonctionnalités :
#   - Gestion BDD, schémas, utilisateurs
#   - RBAC orienté Data Team (Engineer / Analyst / BI User / Service / Admin)
#   - Permissions granulaires (schéma, table)
#   - Backup & restauration
#   - Monitoring & audit
#   - Mode interactif (menus numérotés) + mode CLI non-interactif
#   - Mode dry-run, verbose, journalisation des actions
#   - Support local (psql) et SSH
#
# Usage:
#   ./pg-admin.sh                   # Mode interactif
#   ./pg-admin.sh --help            # Aide CLI
#   ./pg-admin.sh --dry-run <cmd>   # Preview SQL sans exécuter
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONSTANTES
# =============================================================================

readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dossier de config stable (hors du clone managed). Repli sur le dossier du
# script pour un usage local/checkout. Ordre de résolution par fichier :
#   1) $DEVOPS_CONFIG_HOME/<f>   (~/.config/devops par défaut)
#   2) $SCRIPT_DIR/<f>
readonly DEVOPS_CONFIG_HOME="${DEVOPS_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/devops}"
_resolve_conf() {
    local f="$1"
    if [ -f "$DEVOPS_CONFIG_HOME/$f" ]; then
        printf '%s' "$DEVOPS_CONFIG_HOME/$f"
    else
        printf '%s' "$SCRIPT_DIR/$f"
    fi
}

CONFIG_FILE="${PG_CONFIG_FILE:-$(_resolve_conf pg-config.conf)}"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly CREDS_DIR="${SCRIPT_DIR}/.credentials"

# Couleurs
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Privilèges PostgreSQL autorisés (validation whitelist)
readonly VALID_PRIVS="SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER CONNECT TEMPORARY EXECUTE USAGE CREATE ALL"

# =============================================================================
# ÉTAT GLOBAL
# =============================================================================

DRY_RUN=false
VERBOSE=false
ASSUME_YES="${ASSUME_YES:-false}"   # --yes : confirme automatiquement (CI/automation)

PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
PG_DEFAULT_DB="${PG_DEFAULT_DB:-postgres}"
USE_SSH="${USE_SSH:-local}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"

# Noms des rôles RBAC (surchargeables via env ou config)
ROLE_DATA_ENGINEER="${ROLE_DATA_ENGINEER:-role_data_engineer}"
ROLE_DATA_ANALYST="${ROLE_DATA_ANALYST:-role_data_analyst}"
ROLE_BI_USER="${ROLE_BI_USER:-role_bi_user}"
ROLE_SERVICE_ACCOUNT="${ROLE_SERVICE_ACCOUNT:-role_service_account}"
ROLE_DB_ADMIN="${ROLE_DB_ADMIN:-role_db_admin}"

TEMP_PGPASSFILE=""

# =============================================================================
# LOGGING
# =============================================================================

_log()        { echo -e "$1" >&2; }
log_info()    { _log "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { _log "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { _log "${RED}[ERROR]${NC} $*"; }
log_success() { _log "${GREEN}[✓]${NC}     $*"; }
log_debug()   { [[ "$VERBOSE" == true ]] && _log "${CYAN}[DEBUG]${NC} $*" || true; }

log_header() {
    _log ""
    _log "${CYAN}══════════════════════════════════════════════${NC}"
    _log "  ${WHITE}${BOLD}$*${NC}"
    _log "${CYAN}══════════════════════════════════════════════${NC}"
    _log ""
}

audit_log() {
    local action="$1"
    local details="${2:-}"
    mkdir -p "$LOG_DIR"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local who; who=$(whoami 2>/dev/null || echo "unknown")
    printf '[%s] USER=%-15s ACTION=%-30s DETAILS=%s\n' \
        "$ts" "$who" "$action" "$details" >> "${LOG_DIR}/audit-$(date +%Y-%m-%d).log"
    # Mirroir JSONL structuré (parseable / requêtable hors-ligne)
    printf '{"ts":"%s","user":"%s","action":"%s","details":"%s"}\n' \
        "$ts" "$who" "$action" "$(printf '%s' "$details" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
        >> "${LOG_DIR}/audit-$(date +%Y-%m-%d).jsonl"
    # Audit en base (best-effort) si AUDIT_DB défini — fonction du module ext
    if declare -f audit_db_record >/dev/null 2>&1; then
        audit_db_record "$action" "$details"
    fi
    log_debug "AUDIT: $action | $details"
}

# =============================================================================
# NETTOYAGE & TRAP
# =============================================================================

_TEMP_SERVER_CONF=""

_cleanup() {
    if [[ -n "${TEMP_PGPASSFILE:-}" && -f "$TEMP_PGPASSFILE" ]]; then
        rm -f "$TEMP_PGPASSFILE"
        log_debug "Fichier pgpass temporaire supprimé"
    fi
    if [[ -n "${_TEMP_SERVER_CONF:-}" && -f "$_TEMP_SERVER_CONF" ]]; then
        rm -f "$_TEMP_SERVER_CONF"
        log_debug "Fichier config serveur temporaire supprimé"
    fi
}
trap _cleanup EXIT INT TERM

# =============================================================================
# SÉCURITÉ : PGPASSFILE (évite PGPASSWORD visible dans `ps`)
# =============================================================================

setup_pgpassfile() {
    # Docker mode uses PGPASSWORD via env in _psql_docker, no file needed
    [[ "$USE_SSH" == "docker" ]] && return 0
    TEMP_PGPASSFILE=$(mktemp "${TMPDIR:-/tmp}/pgpass.XXXXXX")
    chmod 600 "$TEMP_PGPASSFILE"
    # Format : hostname:port:database:username:password
    printf '%s:%s:*:%s:%s\n' \
        "$PG_HOST" "$PG_PORT" "$PG_ADMIN_USER" "$PG_ADMIN_PASSWORD" \
        > "$TEMP_PGPASSFILE"
    log_debug "PGPASSFILE configuré: $TEMP_PGPASSFILE"
}

# =============================================================================
# SÉCURITÉ : VALIDATION DES ENTRÉES
# =============================================================================

# Identifiants PG : lettres, chiffres, underscore, tiret ; commence par lettre ou _ ; max 63
# Le tiret est autorisé car ces identifiants sont toujours interpolés entre
# guillemets doubles dans le SQL ("$value") ; seul un guillemet double
# embarqué permettrait une évasion, d'où son exclusion explicite.
validate_identifier() {
    local value="$1"
    local label="${2:-identifiant}"
    if [[ -z "$value" ]]; then
        log_error "$label ne peut pas être vide"
        return 1
    fi
    if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,62}$ ]]; then
        log_error "Valeur invalide pour $label: '$value'"
        log_error "  → Uniquement lettres/chiffres/underscore/tiret, max 63 chars, commence par lettre ou _"
        return 1
    fi
}

validate_port() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
        log_error "Port invalide: '$value' (1-65535)"
        return 1
    fi
}

# Validation whitelist des privilèges PostgreSQL
validate_privilege_list() {
    local privs="$1"
    IFS=',' read -ra priv_array <<< "$privs"
    for priv in "${priv_array[@]}"; do
        priv="${priv// /}"  # trim espaces
        local p_upper; p_upper=$(echo "$priv" | tr '[:lower:]' '[:upper:]')
        if ! grep -qw "$p_upper" <<< "$VALID_PRIVS"; then
            log_error "Privilège invalide: '$priv'"
            log_error "  → Autorisés: $VALID_PRIVS"
            return 1
        fi
    done
}

# Échappe les apostrophes pour les littéraux SQL (protection injection)
pg_escape_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# =============================================================================
# CONNEXION : EXÉCUTION SQL
# =============================================================================

# Exécute SQL via psql local — SQL passé par stdin (pas en argument CLI)
_psql_local() {
    local database="$1"; shift
    PGPASSFILE="$TEMP_PGPASSFILE" psql \
        -h "$PG_HOST" -p "$PG_PORT" \
        -U "$PG_ADMIN_USER" -d "$database" \
        --no-password -v ON_ERROR_STOP=1 \
        "$@"
}

# Exécute SQL via docker exec — utile quand psql n'est pas installé localement
_psql_docker() {
    local database="$1"; shift
    docker exec -i "$DOCKER_CONTAINER" \
        env PGPASSWORD="$PG_ADMIN_PASSWORD" \
        psql -U "$PG_ADMIN_USER" -d "$database" \
        -v ON_ERROR_STOP=1 "$@"
}

# Exécute SQL via SSH — SQL pipé par stdin pour éviter l'injection shell
_psql_ssh() {
    local database="$1"; shift
    local ssh_opts=(-p "$SSH_PORT"
                    -o BatchMode=yes
                    -o ConnectTimeout=10
                    -o StrictHostKeyChecking=accept-new)
    local ssh_key_expanded="${SSH_KEY/#\~/$HOME}"
    [[ -n "$ssh_key_expanded" && -f "$ssh_key_expanded" ]] && ssh_opts+=(-i "$ssh_key_expanded")

    # Le mot de passe est transmis via la variable d'environnement côté remote.
    # Le SQL est pipé par stdin → pas d'injection via argument CLI.
    ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" \
        "PGPASSWORD=$(printf '%q' "$PG_ADMIN_PASSWORD") psql \
         -h localhost -p $(printf '%q' "$PG_PORT") \
         -U $(printf '%q' "$PG_ADMIN_USER") \
         -d $(printf '%q' "$database") \
         --no-password -v ON_ERROR_STOP=1" "$@"
}

execute_sql() {
    local sql="$1"
    local database="${2:-$PG_DEFAULT_DB}"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Base: ${CYAN}$database${NC}"
        echo -e "${YELLOW}SQL ▶${NC}"
        echo "$sql"
        return 0
    fi

    log_debug "SQL sur '$database'"

    if [[ "$USE_SSH" == "ssh" ]]; then
        printf '%s\n' "$sql" | _psql_ssh "$database"
    elif [[ "$USE_SSH" == "docker" ]]; then
        printf '%s\n' "$sql" | _psql_docker "$database"
    else
        printf '%s\n' "$sql" | _psql_local "$database"
    fi
}

# Retourne une liste brute (une valeur par ligne, sans en-tête ni séparateurs)
# Flags -t (tuples only) -A (unaligned) pour parsing direct dans les pickers
execute_sql_list() {
    local sql="$1"
    local database="${2:-$PG_DEFAULT_DB}"
    if [[ "$USE_SSH" == "ssh" ]]; then
        printf '%s\n' "$sql" | _psql_ssh "$database" -t -A 2>/dev/null || true
    elif [[ "$USE_SSH" == "docker" ]]; then
        printf '%s\n' "$sql" | _psql_docker "$database" -t -A 2>/dev/null || true
    else
        printf '%s\n' "$sql" | _psql_local "$database" -t -A 2>/dev/null || true
    fi
}

# =============================================================================
# CONNEXION : TEST, CONFIG, CHARGEMENT
# =============================================================================

check_connection() {
    log_info "Test de connexion (${PG_ADMIN_USER}@${PG_HOST}:${PG_PORT})..."
    if execute_sql "SELECT version();" "$PG_DEFAULT_DB" >/dev/null 2>&1; then
        log_success "Connexion OK — ${PG_ADMIN_USER}@${PG_HOST}:${PG_PORT}/${PG_DEFAULT_DB}"
        return 0
    else
        log_error "Impossible de se connecter à ${PG_HOST}:${PG_PORT}"
        return 1
    fi
}

_test_ssh() {
    [[ "$USE_SSH" == "ssh" ]] || return 0
    local ssh_opts=(-p "$SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes)
    local ssh_key_expanded="${SSH_KEY/#\~/$HOME}"
    [[ -n "$ssh_key_expanded" && -f "$ssh_key_expanded" ]] && ssh_opts+=(-i "$ssh_key_expanded")
    ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "exit" 2>/dev/null
}

_test_docker() {
    [[ "$USE_SSH" == "docker" ]] || return 0
    docker inspect "$DOCKER_CONTAINER" >/dev/null 2>&1 || {
        log_error "Conteneur Docker introuvable: $DOCKER_CONTAINER"
        return 1
    }
}

# Chargement de la config sans `source` (évite exécution de code arbitraire)
load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && { log_debug "Pas de fichier config ($CONFIG_FILE)"; return 0; }

    local perms
    perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
    [[ -n "$perms" && "$perms" != "600" ]] && \
        log_warn "Permissions du fichier config non sécurisées (recommandé: 600, actuel: $perms)"

    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$|^[[:space:]]*$ ]] && continue
        key="${key// /}"
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            PG_HOST)           PG_HOST="$value" ;;
            PG_PORT)           PG_PORT="$value" ;;
            PG_ADMIN_USER)     PG_ADMIN_USER="$value" ;;
            PG_ADMIN_PASSWORD) PG_ADMIN_PASSWORD="$value" ;;
            PG_DEFAULT_DB)     PG_DEFAULT_DB="$value" ;;
            USE_SSH)           USE_SSH="$value" ;;
            SSH_HOST)          SSH_HOST="$value" ;;
            SSH_PORT)          SSH_PORT="$value" ;;
            SSH_USER)          SSH_USER="$value" ;;
            SSH_KEY)           SSH_KEY="$value" ;;
            DOCKER_CONTAINER)  DOCKER_CONTAINER="$value" ;;
        esac
    done < "$CONFIG_FILE"
    log_debug "Config chargée depuis $CONFIG_FILE"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << CONFEOF
# pg-admin configuration — NE PAS COMMITTER (secrets inclus)
# Ajouter ce fichier à .gitignore

PG_HOST="$PG_HOST"
PG_PORT="$PG_PORT"
PG_ADMIN_USER="$PG_ADMIN_USER"
PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD"
PG_DEFAULT_DB="$PG_DEFAULT_DB"
USE_SSH="$USE_SSH"
SSH_HOST="$SSH_HOST"
SSH_PORT="$SSH_PORT"
SSH_USER="$SSH_USER"
SSH_KEY="$SSH_KEY"
DOCKER_CONTAINER="$DOCKER_CONTAINER"
CONFEOF
    chmod 600 "$CONFIG_FILE"
    log_success "Configuration sauvegardée: $CONFIG_FILE (permissions 600)"
}

# =============================================================================
# SÉLECTION INTERACTIVE DU SERVEUR (servers.conf)
# =============================================================================
#
# Appelé automatiquement au démarrage si :
#   - PG_CONFIG_FILE n'est pas défini explicitement dans l'environnement
#   - servers.conf existe dans le même répertoire que pg-admin.sh
#
# Met à jour CONFIG_FILE avec un fichier temporaire contenant la config
# du serveur sélectionné, qui sera lu ensuite par load_config().

_select_server_from_conf() {
    local servers_file="${SERVERS_CONF_FILE:-$(_resolve_conf servers.conf)}"
    [[ ! -f "$servers_file" ]] && return 0

    # --- Lecture des sections (compatible bash 3 — pas de declare -A) ---
    local section_ids=()
    local section_descs=()
    local _idx=-1
    local _current=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            _current="${BASH_REMATCH[1]}"
            _idx=$(( _idx + 1 ))
            section_ids[$_idx]="$_current"
            section_descs[$_idx]=""
            continue
        fi
        if [[ -n "$_current" && "$line" == DESCRIPTION=* ]]; then
            local _val="${line#DESCRIPTION=}"
            _val="${_val%\"}"
            _val="${_val#\"}"
            section_descs[$_idx]="$_val"
        fi
    done < "$servers_file"

    [[ ${#section_ids[@]} -eq 0 ]] && log_debug "servers.conf vide" && return 0

    # --- Sélection ---
    local selected_section=""
    local selected_idx=0

    if [[ ${#section_ids[@]} -eq 1 ]]; then
        # Un seul serveur → sélection automatique silencieuse
        selected_section="${section_ids[0]}"
        selected_idx=0
    elif [[ ! -t 0 ]]; then
        # Mode non-interactif → premier serveur par défaut
        log_debug "Mode non-interactif — premier serveur sélectionné"
        selected_section="${section_ids[0]}"
        selected_idx=0
    else
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}${BOLD}Connexion PostgreSQL — Sélection du serveur${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        echo ""
        for _i in "${!section_ids[@]}"; do
            printf "  ${GREEN}[%d]${NC}  %-24s  %s\n" \
                "$(( _i + 1 ))" "${section_ids[$_i]}" "${section_descs[$_i]}"
        done
        echo ""
        while true; do
            read -rp "  Choisir [1-${#section_ids[@]}] ou 'q' pour quitter : " _choice
            [[ "$_choice" == "q" || "$_choice" == "Q" ]] && echo "Annulé." && exit 0
            if [[ "$_choice" =~ ^[0-9]+$ ]] && \
               (( _choice >= 1 && _choice <= ${#section_ids[@]} )); then
                selected_idx=$(( _choice - 1 ))
                selected_section="${section_ids[$selected_idx]}"
                break
            fi
            echo -e "  ${YELLOW}Choix invalide.${NC} Entrer un nombre entre 1 et ${#section_ids[@]}."
        done
    fi

    # --- Extraction du profil vers fichier temporaire ---
    _TEMP_SERVER_CONF=$(mktemp "${TMPDIR:-/tmp}/pg-connect.XXXXXX")
    chmod 600 "$_TEMP_SERVER_CONF"

    local _in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$selected_section" ]]; then
                _in_section=true
            elif $_in_section; then
                break
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
                    echo "$line" >> "$_TEMP_SERVER_CONF"
                    ;;
            esac
        fi
    done < "$servers_file"

    if [[ ! -s "$_TEMP_SERVER_CONF" ]]; then
        rm -f "$_TEMP_SERVER_CONF"
        _TEMP_SERVER_CONF=""
        log_warn "Impossible d'extraire la config de '$selected_section' — utilisation des défauts"
        return 0
    fi

    # Remplacer CONFIG_FILE par le profil sélectionné
    CONFIG_FILE="$_TEMP_SERVER_CONF"

    echo ""
    echo -e "  ${GREEN}[✓]${NC}  Serveur : ${WHITE}${BOLD}${selected_section}${NC}"
    local _desc="${section_descs[$selected_idx]:-}"
    [[ -n "$_desc" ]] && echo -e "       ${_desc}"
    echo ""
}

# =============================================================================
# UTILITAIRES
# =============================================================================

check_requirements() {
    local missing=()
    if [[ "$USE_SSH" == "ssh" ]]; then
        command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    elif [[ "$USE_SSH" == "docker" ]]; then
        command -v docker >/dev/null 2>&1 || missing+=("docker")
        if [[ -z "$DOCKER_CONTAINER" ]]; then
            log_error "USE_SSH=docker requiert DOCKER_CONTAINER= dans la config"
            exit 1
        fi
    else
        command -v psql    >/dev/null 2>&1 || missing+=("psql")
        command -v pg_dump >/dev/null 2>&1 || missing+=("pg_dump")
    fi
    if (( ${#missing[@]} > 0 )); then
        log_error "Outils manquants: ${missing[*]}"
        log_info "macOS:  brew install postgresql"
        log_info "Ubuntu: sudo apt-get install postgresql-client"
        exit 1
    fi
}

# Confirme une action simple (y/N)
confirm() {
    local message="$1"
    local answer
    [[ "$ASSUME_YES" == true ]] && { log_warn "$message → OUI (--yes)"; return 0; }
    [[ ! -t 0 ]] && { log_error "Confirmation requise mais stdin non-interactif (utilisez --yes pour l'automation)"; return 1; }
    read -r -p "$(echo -e "${YELLOW}⚠  $message${NC} [y/N] ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Double confirmation pour les opérations irréversibles (taper le nom exact)
confirm_double() {
    local action="$1"
    local target="$2"
    [[ ! -t 0 ]] && { log_error "Confirmation requise mais stdin non-interactif"; return 1; }
    log_warn "Action IRRÉVERSIBLE : $action sur '${BOLD}$target${NC}'"
    local typed
    read -r -p "$(echo -e "  Tapez exactement ${RED}${BOLD}${target}${NC} pour confirmer: ")" typed
    if [[ "$typed" != "$target" ]]; then
        log_info "Confirmation échouée — opération annulée"
        return 1
    fi
}

generate_password() {
    local length="${1:-20}"
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()-_=+' < /dev/urandom | head -c "$length"
    echo
}

_save_credentials() {
    local username="$1" password="$2" profile="$3"
    mkdir -p "$CREDS_DIR"
    chmod 700 "$CREDS_DIR"
    local cred_file="${CREDS_DIR}/${username}_$(date +%Y%m%d_%H%M%S).txt"
    cat > "$cred_file" << CREDEOF
# Credentials générés le $(date)
# FICHIER SENSIBLE — ne pas committer

User:     $username
Password: $password
Profile:  $profile
Host:     $PG_HOST:$PG_PORT
Database: $PG_DEFAULT_DB
URI:      postgresql://${username}:${password}@${PG_HOST}:${PG_PORT}/${PG_DEFAULT_DB}
CREDEOF
    chmod 600 "$cred_file"
    log_info "Credentials sauvegardés: $cred_file"
}

# Pause interactive (appuyer sur Entrée)
_press_enter() {
    echo ""
    [[ -t 0 ]] && read -r -p "$(echo -e "${CYAN}[Entrée pour continuer...]${NC}")" || true
}

# =============================================================================
# BASES DE DONNÉES
# =============================================================================

db_list() {
    log_header "BASES DE DONNÉES"
    execute_sql "
SELECT
    datname                                          AS \"Nom\",
    pg_size_pretty(pg_database_size(datname))        AS \"Taille\",
    pg_encoding_to_char(encoding)                    AS \"Encodage\",
    datcollate                                       AS \"Collation\",
    (SELECT count(*) FROM pg_stat_activity
     WHERE datname = d.datname)                      AS \"Connexions\"
FROM pg_database d
WHERE datistemplate = false
ORDER BY datname;"
}

db_create() {
    local dbname="$1"
    local owner="${2:-$PG_ADMIN_USER}"
    validate_identifier "$dbname" "nom de base" || return 1
    validate_identifier "$owner"  "propriétaire" || return 1

    log_header "CRÉATION BASE: $dbname"

    local exists
    exists=$(execute_sql \
        "SELECT 1 FROM pg_database WHERE datname = '$(pg_escape_literal "$dbname")';" \
        2>/dev/null | grep -c "^ 1$" || true)
    if (( exists > 0 )); then
        log_warn "La base '$dbname' existe déjà — aucune action"
        return 0
    fi

    local owner_exists
    owner_exists=$(execute_sql \
        "SELECT 1 FROM pg_roles WHERE rolname = '$(pg_escape_literal "$owner")';" \
        2>/dev/null | grep -c "^ 1$" || true)
    if (( owner_exists == 0 )); then
        log_warn "Le rôle propriétaire '$owner' n'existe pas"
        if [[ ! -t 0 ]]; then
            log_error "Confirmation requise mais stdin non-interactif — abandon"
            return 1
        fi
        local create_role
        read -r -p "  Créer ce rôle maintenant ? [o/N] : " create_role </dev/tty
        if [[ ! "$create_role" =~ ^[oOyY]$ ]]; then
            log_error "Abandon — le rôle '$owner' doit exister avant de créer la base"
            return 1
        fi
        user_create "$owner" "" "db-owner" || {
            log_error "Échec de la création du rôle '$owner' — abandon"
            return 1
        }
    fi

    if ! execute_sql "
CREATE DATABASE \"$dbname\"
    WITH OWNER      = \"$owner\"
         ENCODING   = 'UTF8'
         LC_COLLATE = 'en_US.UTF-8'
         LC_CTYPE   = 'en_US.UTF-8'
         TEMPLATE   = template0;"; then
        log_error "Échec de la création de la base '$dbname'"
        return 1
    fi

    # Extensions utiles
    for ext in "uuid-ossp" "pg_trgm" "unaccent"; do
        execute_sql "CREATE EXTENSION IF NOT EXISTS \"$ext\";" "$dbname" 2>/dev/null || true
    done

    audit_log "CREATE_DATABASE" "db=$dbname owner=$owner"
    log_success "Base '$dbname' créée (owner: $owner)"
}

db_change_owner() {
    local dbname="$1"
    local new_owner="$2"
    validate_identifier "$dbname"    "nom de base"       || return 1
    validate_identifier "$new_owner" "nouveau propriétaire" || return 1

    log_header "CHANGEMENT PROPRIÉTAIRE: $dbname → $new_owner"
    execute_sql "ALTER DATABASE \"$dbname\" OWNER TO \"$new_owner\";"
    audit_log "CHANGE_OWNER_DB" "db=$dbname new_owner=$new_owner"
    log_success "Propriétaire de '$dbname' changé → '$new_owner'"
}

db_drop() {
    local dbname="$1"
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "SUPPRESSION BASE: $dbname"

    confirm_double "DROP DATABASE" "$dbname" || return 0

    # Bloque les nouvelles connexions le temps du drop, pour éviter la
    # course entre pg_terminate_backend et DROP DATABASE (ex: pool/app
    # qui se reconnecte juste avant le DROP).
    execute_sql "REVOKE CONNECT ON DATABASE \"$dbname\" FROM PUBLIC;" 2>/dev/null || true

    local attempt
    for attempt in 1 2 3; do
        execute_sql "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$(pg_escape_literal "$dbname")' AND pid <> pg_backend_pid();" 2>/dev/null || true

        if execute_sql "DROP DATABASE IF EXISTS \"$dbname\";" 2>/dev/null; then
            audit_log "DROP_DATABASE" "db=$dbname"
            log_success "Base '$dbname' supprimée"
            return 0
        fi

        log_warn "Tentative $attempt/3 : connexions actives détectées, nouvel essai..."
        sleep 1
    done

    # Le drop a échoué malgré les tentatives : on restaure l'accès plutôt
    # que de laisser la base injoignable.
    execute_sql "GRANT CONNECT ON DATABASE \"$dbname\" TO PUBLIC;" 2>/dev/null || true
    log_error "Impossible de supprimer '$dbname' : connexions persistantes après 3 tentatives"
    return 1
}

# =============================================================================
# SCHÉMAS
# =============================================================================

schema_list() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "SCHÉMAS — $dbname"
    execute_sql "
SELECT
    schema_name  AS \"Schéma\",
    schema_owner AS \"Propriétaire\"
FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY schema_name;" "$dbname"
}

schema_create() {
    local dbname="$1" schema="$2" owner="${3:-$PG_ADMIN_USER}"
    validate_identifier "$dbname" "nom de base"   || return 1
    validate_identifier "$schema" "nom de schéma" || return 1
    validate_identifier "$owner"  "propriétaire"  || return 1

    log_header "CRÉATION SCHÉMA: $schema (DB: $dbname)"
    execute_sql "CREATE SCHEMA IF NOT EXISTS \"$schema\" AUTHORIZATION \"$owner\";" "$dbname"
    audit_log "CREATE_SCHEMA" "db=$dbname schema=$schema owner=$owner"
    log_success "Schéma '$schema' créé dans '$dbname'"
}

schema_drop() {
    local dbname="$1" schema="$2" cascade="${3:-false}"
    validate_identifier "$dbname" "nom de base"   || return 1
    validate_identifier "$schema" "nom de schéma" || return 1

    log_header "SUPPRESSION SCHÉMA: $schema"
    confirm_double "DROP SCHEMA" "$schema" || return 0

    local sql="DROP SCHEMA IF EXISTS \"$schema\""
    [[ "$cascade" == "true" ]] && sql+=" CASCADE" || sql+=" RESTRICT"
    execute_sql "$sql;" "$dbname"
    audit_log "DROP_SCHEMA" "db=$dbname schema=$schema cascade=$cascade"
    log_success "Schéma '$schema' supprimé"
}

# =============================================================================
# UTILISATEURS
# =============================================================================

user_list() {
    log_header "UTILISATEURS"
    execute_sql "
SELECT
    rolname                                           AS \"Utilisateur\",
    CASE
        WHEN rolsuper      THEN 'Superuser'
        WHEN rolcreatedb   THEN 'CreateDB'
        WHEN rolcreaterole THEN 'CreateRole'
        ELSE 'Normal'
    END                                               AS \"Type\",
    CASE WHEN rolcanlogin  THEN '✓' ELSE '✗' END      AS \"Login\",
    CASE WHEN rolbypassrls THEN '✓' ELSE '✗' END      AS \"BypassRLS\",
    CASE WHEN rolconnlimit < 0 THEN '∞'
         ELSE rolconnlimit::text END                   AS \"MaxConn\",
    COALESCE(rolvaliduntil::text, '—')                AS \"Expiration\"
FROM pg_roles
WHERE rolname NOT LIKE 'pg_%'
ORDER BY rolcanlogin DESC, rolname;"
}

user_create() {
    local username="$1"
    local password="${2:-}"
    local profile="${3:-analyst}"

    validate_identifier "$username" "nom d'utilisateur" || return 1

    local exists
    exists=$(execute_sql \
        "SELECT 1 FROM pg_roles WHERE rolname = '$(pg_escape_literal "$username")';" \
        2>/dev/null | grep -c "^ 1$" || true)
    if (( exists > 0 )); then
        log_error "L'utilisateur '$username' existe déjà"
        return 1
    fi

    local auto_generated=false
    if [[ -z "$password" ]]; then
        password=$(generate_password 20)
        auto_generated=true
    fi

    log_header "CRÉATION UTILISATEUR: $username (profil: $profile)"
    local escaped_pw; escaped_pw=$(pg_escape_literal "$password")

    execute_sql "
CREATE USER \"$username\"
    WITH PASSWORD '$escaped_pw'
         LOGIN
         CONNECTION LIMIT -1;"

    audit_log "CREATE_USER" "user=$username profile=$profile"
    _save_credentials "$username" "$password" "$profile"

    if [[ "$auto_generated" == true ]]; then
        log_warn "Mot de passe auto-généré — sauvegardez-le maintenant !"
        log_info "Mot de passe: ${BOLD}$password${NC}"
    fi
    log_success "Utilisateur '$username' créé"
}

user_drop() {
    local username="$1"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    log_header "SUPPRESSION UTILISATEUR: $username"

    confirm_double "DROP USER" "$username" || return 0

    # Réassigner les objets appartenant à l'utilisateur
    execute_sql "REASSIGN OWNED BY \"$username\" TO \"$PG_ADMIN_USER\";" 2>/dev/null || true
    execute_sql "DROP OWNED BY \"$username\";" 2>/dev/null || true
    execute_sql "DROP USER IF EXISTS \"$username\";"
    audit_log "DROP_USER" "user=$username"
    log_success "Utilisateur '$username' supprimé"
}

user_change_password() {
    local username="$1"
    local new_password="${2:-}"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    local auto_generated=false
    if [[ -z "$new_password" ]]; then
        new_password=$(generate_password 20)
        auto_generated=true
    fi

    local escaped_pw; escaped_pw=$(pg_escape_literal "$new_password")
    execute_sql "ALTER USER \"$username\" WITH PASSWORD '$escaped_pw';"
    audit_log "CHANGE_PASSWORD" "user=$username"
    declare -f audit_record_rotation >/dev/null 2>&1 && audit_record_rotation "$username"

    if [[ "$auto_generated" == true ]]; then
        log_info "Nouveau mot de passe: ${BOLD}$new_password${NC}"
    fi
    log_success "Mot de passe mis à jour pour '$username'"
}

user_lock() {
    local username="$1"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    execute_sql "ALTER USER \"$username\" NOLOGIN;"
    audit_log "LOCK_USER" "user=$username"
    log_success "Utilisateur '$username' verrouillé (NOLOGIN)"
}

user_unlock() {
    local username="$1"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    execute_sql "ALTER USER \"$username\" LOGIN;"
    audit_log "UNLOCK_USER" "user=$username"
    log_success "Utilisateur '$username' déverrouillé (LOGIN)"
}

user_set_expiry() {
    local username="$1"
    local expiry="${2:-}"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    if [[ -z "$expiry" ]]; then
        execute_sql "ALTER USER \"$username\" VALID UNTIL 'infinity';"
        log_success "Expiration supprimée pour '$username'"
    else
        local escaped_exp; escaped_exp=$(pg_escape_literal "$expiry")
        execute_sql "ALTER USER \"$username\" VALID UNTIL '$escaped_exp';"
        log_success "Expiration fixée à '$expiry' pour '$username'"
    fi
    audit_log "SET_EXPIRY" "user=$username expiry=${expiry:-infinity}"
}

user_set_conn_limit() {
    local username="$1"
    local limit="${2:-}"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    # Valider : entier >= -1  (-1 = illimité, 0 = aucune connexion, N = max N)
    if [[ -n "$limit" && ! "$limit" =~ ^-?[0-9]+$ ]]; then
        log_error "Valeur invalide : '$limit' (entier >= -1, ou vide pour ∞)"
        return 1
    fi
    if [[ -n "$limit" && "$limit" -lt -1 ]]; then
        log_error "Valeur invalide : minimum -1 (∞)"
        return 1
    fi

    # Vide ou -1 → illimité
    local effective_limit="${limit:--1}"

    execute_sql "ALTER USER \"$username\" CONNECTION LIMIT ${effective_limit};"

    if [[ "$effective_limit" == "-1" ]]; then
        log_success "MaxConn de '$username' : ∞ (illimité)"
    elif [[ "$effective_limit" == "0" ]]; then
        log_warn "MaxConn de '$username' : 0 — aucune nouvelle connexion autorisée"
    else
        log_success "MaxConn de '$username' : ${effective_limit} connexions simultanées"
    fi
    audit_log "SET_CONN_LIMIT" "user=$username limit=${effective_limit}"
}

# =============================================================================
# RBAC — PROFILS DATA TEAM
# =============================================================================
#
# Hiérarchie des rôles (pas de LOGIN — groupes) :
#
#   role_db_admin          Tous les droits sur la base
#   role_data_engineer     DDL + DML complet sur les schémas de travail
#   role_data_analyst      SELECT sur les schémas analytiques (dwh, mart)
#   role_bi_user           SELECT sur les schémas de reporting (mart uniquement)
#   role_service_account   Permissions minimales, configurées au cas par cas
#
# Attribution : GRANT <role> TO <user>
# =============================================================================

rbac_create_roles() {
    local dbname="$1"
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "INITIALISATION RÔLES RBAC — $dbname"

    for role in "$ROLE_DB_ADMIN" "$ROLE_DATA_ENGINEER" "$ROLE_DATA_ANALYST" \
                "$ROLE_BI_USER" "$ROLE_SERVICE_ACCOUNT"; do
        execute_sql "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$(pg_escape_literal "$role")') THEN
        CREATE ROLE \"$role\" NOLOGIN;
        RAISE NOTICE 'Rôle créé: $role';
    ELSE
        RAISE NOTICE 'Rôle existant (ignoré): $role';
    END IF;
END
\$\$;"
        log_info "Rôle '$role' assuré"
    done

    # CONNECT sur la base pour tous sauf service_account (géré manuellement)
    for role in "$ROLE_DB_ADMIN" "$ROLE_DATA_ENGINEER" "$ROLE_DATA_ANALYST" "$ROLE_BI_USER"; do
        execute_sql "GRANT CONNECT ON DATABASE \"$dbname\" TO \"$role\";"
    done

    # DB Admin : tous les droits sur la base
    execute_sql "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$ROLE_DB_ADMIN\";"

    audit_log "CREATE_RBAC_ROLES" "db=$dbname"
    log_success "Rôles RBAC initialisés pour '$dbname'"
    log_info "Prochaine étape : appliquer les profils sur les schémas (menu RBAC › option 3, ou: rbac apply <db> <schema> <profil>)"
}

# Data Engineer : DDL + DML complet, maintenance
rbac_apply_engineer() {
    local dbname="$1" schema="${2:-public}"
    validate_identifier "$dbname" "nom de base"   || return 1
    validate_identifier "$schema" "nom de schéma" || return 1
    local role="$ROLE_DATA_ENGINEER"

    log_header "RBAC DATA ENGINEER → $role @ $dbname.$schema"
    log_info "Droits : DDL, DML complet (INSERT/UPDATE/DELETE/TRUNCATE), CREATE, séquences, fonctions"

    # Schéma : usage + create (peut créer des tables/vues)
    execute_sql "GRANT USAGE, CREATE ON SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    # Tables existantes : DML complet
    execute_sql "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    # Séquences existantes : lecture + écriture (SERIAL/IDENTITY)
    execute_sql "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    # Fonctions existantes
    execute_sql "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    # Futurs objets
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO \"$role\";" "$dbname"
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO \"$role\";" "$dbname"
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT EXECUTE ON FUNCTIONS TO \"$role\";" "$dbname"

    audit_log "RBAC_APPLY_ENGINEER" "db=$dbname schema=$schema role=$role"
    log_success "Profil Data Engineer appliqué sur $schema"
}

# Data Analyst : SELECT uniquement sur schémas analytiques
rbac_apply_analyst() {
    local dbname="$1" schema="${2:-public}"
    validate_identifier "$dbname" "nom de base"   || return 1
    validate_identifier "$schema" "nom de schéma" || return 1
    local role="$ROLE_DATA_ANALYST"

    log_header "RBAC DATA ANALYST → $role @ $dbname.$schema"
    log_info "Droits : SELECT uniquement sur tables et vues, pas de CREATE"

    execute_sql "GRANT USAGE ON SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    execute_sql "GRANT SELECT ON ALL TABLES IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    execute_sql "GRANT SELECT ON ALL SEQUENCES IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT SELECT ON TABLES TO \"$role\";" "$dbname"
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT SELECT ON SEQUENCES TO \"$role\";" "$dbname"

    audit_log "RBAC_APPLY_ANALYST" "db=$dbname schema=$schema role=$role"
    log_success "Profil Data Analyst appliqué sur $schema"
}

# BI User : SELECT sur le schéma mart (reporting uniquement)
rbac_apply_bi_user() {
    local dbname="$1" schema="${2:-mart}"
    validate_identifier "$dbname" "nom de base"   || return 1
    validate_identifier "$schema" "nom de schéma" || return 1
    local role="$ROLE_BI_USER"

    log_header "RBAC BI USER → $role @ $dbname.$schema"
    log_info "Droits : SELECT sur $schema uniquement (schéma de reporting)"

    execute_sql "GRANT USAGE ON SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    execute_sql "GRANT SELECT ON ALL TABLES IN SCHEMA \"$schema\" TO \"$role\";" "$dbname"
    execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
        GRANT SELECT ON TABLES TO \"$role\";" "$dbname"

    audit_log "RBAC_APPLY_BI_USER" "db=$dbname schema=$schema role=$role"
    log_success "Profil BI User appliqué sur $schema"
}

# Dispatcher : route un profil vers sa fonction d'application de schéma
rbac_apply_profile() {
    local dbname="$1" schema="$2" profile="$3"
    case "$profile" in
        engineer|data_engineer) rbac_apply_engineer "$dbname" "$schema" ;;
        analyst|data_analyst)   rbac_apply_analyst  "$dbname" "$schema" ;;
        bi|bi_user)             rbac_apply_bi_user  "$dbname" "$schema" ;;
        service|svc|admin|db_admin)
            log_error "Profil '$profile' : assignation de rôle uniquement, pas de droits de schéma"
            log_info "→ Utilise RBAC > 4 (Assigner un profil) ou: rbac assign"
            return 1 ;;
        *)
            log_error "Profil inconnu: '$profile'"
            log_info "Profils applicables sur schéma : engineer | analyst | bi"
            return 1 ;;
    esac
}

# Assigne un profil RBAC à un utilisateur
rbac_assign_to_user() {
    local username="$1" profile="$2"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    local role
    case "$profile" in
        engineer|data_engineer) role="$ROLE_DATA_ENGINEER" ;;
        analyst|data_analyst)   role="$ROLE_DATA_ANALYST" ;;
        bi|bi_user)             role="$ROLE_BI_USER" ;;
        service|svc)            role="$ROLE_SERVICE_ACCOUNT" ;;
        admin|db_admin)         role="$ROLE_DB_ADMIN" ;;
        *)
            log_error "Profil inconnu: '$profile'"
            log_info "Profils disponibles: engineer | analyst | bi | service | admin"
            return 1 ;;
    esac

    execute_sql "GRANT \"$role\" TO \"$username\";"
    audit_log "ASSIGN_ROLE" "user=$username role=$role profile=$profile"
    declare -f audit_snapshot_user >/dev/null 2>&1 && audit_snapshot_user "$username" "$PG_DEFAULT_DB"
    log_success "Rôle '${role}' assigné à '$username'"
}

# Révoque un profil RBAC d'un utilisateur
rbac_revoke_from_user() {
    local username="$1" profile="$2"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    local role
    case "$profile" in
        engineer|data_engineer) role="$ROLE_DATA_ENGINEER" ;;
        analyst|data_analyst)   role="$ROLE_DATA_ANALYST" ;;
        bi|bi_user)             role="$ROLE_BI_USER" ;;
        service|svc)            role="$ROLE_SERVICE_ACCOUNT" ;;
        admin|db_admin)         role="$ROLE_DB_ADMIN" ;;
        *) log_error "Profil inconnu: '$profile'"; return 1 ;;
    esac

    confirm "Révoquer le rôle '$role' de '$username' ?" || { log_info "Annulé"; return 0; }
    execute_sql "REVOKE \"$role\" FROM \"$username\";"
    audit_log "REVOKE_ROLE" "user=$username role=$role"
    declare -f audit_snapshot_user >/dev/null 2>&1 && audit_snapshot_user "$username" "$PG_DEFAULT_DB"
    log_success "Rôle '$role' révoqué de '$username'"
}

rbac_list_roles() {
    log_header "RÔLES & MEMBRES"
    execute_sql "
SELECT
    r.rolname                                                           AS \"Rôle\",
    CASE WHEN r.rolcanlogin THEN 'user' ELSE 'group' END               AS \"Type\",
    COALESCE(
        (SELECT string_agg(m.rolname, ', ' ORDER BY m.rolname)
         FROM pg_auth_members am
         JOIN pg_roles m ON m.oid = am.member
         WHERE am.roleid = r.oid),
        '—')                                                            AS \"Membres\"
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg_%'
ORDER BY r.rolcanlogin, r.rolname;"
}

rbac_show_user_roles() {
    local username="$1"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    log_header "RÔLES DE: $username"
    execute_sql "
SELECT r.rolname AS \"Rôle assigné\"
FROM pg_roles u
JOIN pg_auth_members am ON am.member = u.oid
JOIN pg_roles r         ON r.oid = am.roleid
WHERE u.rolname = '$(pg_escape_literal "$username")'
ORDER BY r.rolname;"
}

# Ré-applique tous les profils RBAC sur tous les schémas métier d'une base.
# À exécuter après chaque migration Airflow qui recrée des tables/schémas.
rbac_repair_all() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "RBAC REPAIR-ALL — $dbname"
    log_info "Ré-application des profils sur tous les schémas métier..."

    # Schémas métier : tout sauf pg_catalog, information_schema, pg_toast, public
    local -a schemas=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && schemas+=("$s")
    done < <(execute_sql_list \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast','public')
         ORDER BY schema_name;" "$dbname")

    if (( ${#schemas[@]} == 0 )); then
        log_warn "Aucun schéma métier trouvé dans '$dbname'"
        return 0
    fi

    log_info "Schémas détectés: ${schemas[*]}"

    for schema in "${schemas[@]}"; do
        echo ""
        log_info "── Schéma: $schema ──"

        # Engineer sur tous les schémas (DDL+DML)
        rbac_apply_engineer "$dbname" "$schema"

        # Analyst sur tous les schémas (SELECT)
        rbac_apply_analyst "$dbname" "$schema"

        # BI User uniquement sur mart* (schémas de reporting)
        if [[ "$schema" == mart* || "$schema" == "reporting" || "$schema" == "bi" ]]; then
            rbac_apply_bi_user "$dbname" "$schema"
        fi
    done

    echo ""
    audit_log "RBAC_REPAIR_ALL" "db=$dbname schemas=${schemas[*]}"
    log_success "Permissions restaurées sur ${#schemas[@]} schéma(s)"
}

# =============================================================================
# PERMISSIONS GRANULAIRES
# =============================================================================

perm_grant() {
    local username="$1" dbname="$2" perm_type="${3:-readonly}" schema="${4:-public}"
    validate_identifier "$username"  "nom d'utilisateur" || return 1
    validate_identifier "$dbname"    "nom de base"       || return 1
    validate_identifier "$schema"    "nom de schéma"     || return 1

    log_header "GRANT $perm_type → $username @ $dbname.$schema"
    execute_sql "GRANT CONNECT ON DATABASE \"$dbname\" TO \"$username\";"

    case "$perm_type" in
        readonly|ro)
            execute_sql "GRANT USAGE ON SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT SELECT ON ALL TABLES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT SELECT ON ALL SEQUENCES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
                GRANT SELECT ON TABLES TO \"$username\";" "$dbname"
            ;;
        readwrite|rw)
            execute_sql "GRANT USAGE, CREATE ON SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
                GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"$username\";" "$dbname"
            execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
                GRANT USAGE, SELECT ON SEQUENCES TO \"$username\";" "$dbname"
            ;;
        all)
            execute_sql "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$username\";"
            execute_sql "GRANT ALL PRIVILEGES ON SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA \"$schema\" TO \"$username\";" "$dbname"
            execute_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA \"$schema\"
                GRANT ALL PRIVILEGES ON TABLES TO \"$username\";" "$dbname"
            ;;
        *)
            log_error "Type de permission invalide: '$perm_type'"
            log_info "Types disponibles: readonly | readwrite | all"
            return 1 ;;
    esac

    audit_log "GRANT_PERMISSIONS" "user=$username db=$dbname schema=$schema type=$perm_type"
    declare -f audit_snapshot_user >/dev/null 2>&1 && audit_snapshot_user "$username" "$dbname"
    log_success "Permissions '$perm_type' accordées à '$username' sur $dbname.$schema"
}

perm_grant_table() {
    local username="$1" dbname="$2" schema="$3" table="$4" privs="${5:-SELECT}"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    validate_identifier "$dbname"   "nom de base"       || return 1
    validate_identifier "$schema"   "nom de schéma"     || return 1
    validate_identifier "$table"    "nom de table"      || return 1
    validate_privilege_list "$privs"                    || return 1

    log_header "GRANT TABLE: $privs → $username @ $schema.$table"
    execute_sql "GRANT CONNECT ON DATABASE \"$dbname\" TO \"$username\";"
    execute_sql "GRANT USAGE ON SCHEMA \"$schema\" TO \"$username\";" "$dbname"
    execute_sql "GRANT $privs ON \"$schema\".\"$table\" TO \"$username\";" "$dbname"

    audit_log "GRANT_TABLE" "user=$username db=$dbname schema=$schema table=$table privs=$privs"
    declare -f audit_snapshot_user >/dev/null 2>&1 && audit_snapshot_user "$username" "$dbname"
    log_success "GRANT $privs sur $schema.$table → $username"
}

perm_revoke() {
    local username="$1" dbname="$2" schema="${3:-public}"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    validate_identifier "$dbname"   "nom de base"       || return 1
    validate_identifier "$schema"   "nom de schéma"     || return 1

    log_header "REVOKE ALL — $username @ $dbname.$schema"
    confirm "Révoquer TOUTES les permissions de '$username' sur '$dbname.$schema' ?" \
        || { log_info "Annulé"; return 0; }

    execute_sql "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA \"$schema\" FROM \"$username\";" "$dbname" 2>/dev/null || true
    execute_sql "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA \"$schema\" FROM \"$username\";" "$dbname" 2>/dev/null || true
    execute_sql "REVOKE ALL PRIVILEGES ON SCHEMA \"$schema\" FROM \"$username\";" "$dbname" 2>/dev/null || true
    execute_sql "REVOKE CONNECT ON DATABASE \"$dbname\" FROM \"$username\";" 2>/dev/null || true

    audit_log "REVOKE_PERMISSIONS" "user=$username db=$dbname schema=$schema"
    declare -f audit_snapshot_user >/dev/null 2>&1 && audit_snapshot_user "$username" "$dbname"
    log_success "Permissions révoquées pour '$username' sur '$dbname.$schema'"
}

perm_show() {
    local username="$1" dbname="${2:-$PG_DEFAULT_DB}"
    validate_identifier "$username" "nom d'utilisateur" || return 1

    log_header "PERMISSIONS DE: $username (DB: $dbname)"

    echo -e "\n${WHITE}── Droits sur les bases ──${NC}"
    execute_sql "
SELECT datname AS \"Base\", array_to_string(datacl, ', ') AS \"ACL\"
FROM pg_database
WHERE datacl::text LIKE '%$(pg_escape_literal "$username")%'
ORDER BY datname;"

    echo -e "\n${WHITE}── Rôles assignés ──${NC}"
    execute_sql "
SELECT r.rolname AS \"Rôle\"
FROM pg_roles u
JOIN pg_auth_members am ON am.member = u.oid
JOIN pg_roles r         ON r.oid = am.roleid
WHERE u.rolname = '$(pg_escape_literal "$username")'
ORDER BY r.rolname;"

    echo -e "\n${WHITE}── Droits sur les schémas ──${NC}"
    execute_sql "
SELECT nspname AS \"Schéma\", array_to_string(nspacl, ', ') AS \"ACL\"
FROM pg_namespace
WHERE nspacl::text LIKE '%$(pg_escape_literal "$username")%'
ORDER BY nspname;" "$dbname"

    echo -e "\n${WHITE}── Droits sur les tables ──${NC}"
    execute_sql "
SELECT table_schema AS \"Schéma\", table_name AS \"Table\",
       string_agg(privilege_type, ', ' ORDER BY privilege_type) AS \"Permissions\"
FROM information_schema.table_privileges
WHERE grantee = '$(pg_escape_literal "$username")'
GROUP BY table_schema, table_name
ORDER BY table_schema, table_name;" "$dbname"
}

perm_audit() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "AUDIT PERMISSIONS — $dbname"

    echo -e "\n${WHITE}── Utilisateurs & rôles assignés ──${NC}"
    execute_sql "
SELECT
    u.rolname                                                  AS \"Utilisateur\",
    CASE WHEN u.rolcanlogin THEN 'user' ELSE 'group' END       AS \"Type\",
    COALESCE(string_agg(r.rolname, ', ' ORDER BY r.rolname), '—') AS \"Rôles\",
    CASE WHEN u.rolsuper THEN '⚠ SUPERUSER' ELSE '' END        AS \"Alerte\"
FROM pg_roles u
LEFT JOIN pg_auth_members am ON am.member = u.oid
LEFT JOIN pg_roles r         ON r.oid = am.roleid
WHERE u.rolname NOT LIKE 'pg_%'
GROUP BY u.rolname, u.rolcanlogin, u.rolsuper
ORDER BY u.rolcanlogin DESC, u.rolname;"

    echo -e "\n${WHITE}── ACL sur les schémas ──${NC}"
    execute_sql "
SELECT nspname AS \"Schéma\", array_to_string(nspacl, ', ') AS \"ACL\"
FROM pg_namespace
WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY nspname;" "$dbname"

    echo -e "\n${WHITE}── Droits sur les tables (hors pg_*) ──${NC}"
    execute_sql "
SELECT table_schema AS \"Schéma\", table_name AS \"Table\",
       grantee AS \"Bénéficiaire\",
       string_agg(privilege_type, ', ' ORDER BY privilege_type) AS \"Permissions\"
FROM information_schema.table_privileges
WHERE table_schema NOT IN ('pg_catalog','information_schema')
  AND grantee NOT LIKE 'pg_%'
GROUP BY table_schema, table_name, grantee
ORDER BY table_schema, table_name, grantee;" "$dbname"
}

# =============================================================================
# BACKUP & RESTAURATION
# =============================================================================

backup_db() {
    local dbname="$1" backup_dir="${2:-${SCRIPT_DIR}/backups}"
    validate_identifier "$dbname" "nom de base" || return 1

    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir" 2>/dev/null || true   # best-effort : un répertoire pré-existant non possédé (ex. /tmp) ne doit pas faire échouer le backup
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/${dbname}_${ts}.sql.gz"

    log_header "BACKUP: $dbname → $backup_file"

    if [[ "$USE_SSH" == "ssh" ]]; then
        local ssh_opts=(-p "$SSH_PORT" -o BatchMode=yes)
        [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")
        log_info "Dump via SSH..."
        ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" \
            "PGPASSWORD=$(printf '%q' "$PG_ADMIN_PASSWORD") \
             pg_dump -h localhost -p $PG_PORT \
             -U $(printf '%q' "$PG_ADMIN_USER") \
             -d $(printf '%q' "$dbname") -F plain --no-password" \
            | gzip > "$backup_file"
    else
        PGPASSFILE="$TEMP_PGPASSFILE" pg_dump \
            -h "$PG_HOST" -p "$PG_PORT" \
            -U "$PG_ADMIN_USER" -d "$dbname" \
            -F plain --no-password \
            | gzip > "$backup_file"
    fi

    local size; size=$(du -sh "$backup_file" | cut -f1)
    audit_log "BACKUP" "db=$dbname file=$backup_file size=$size"
    log_success "Backup créé: $backup_file ($size)"
}

restore_db() {
    local dbname="$1" backup_file="$2"
    validate_identifier "$dbname" "nom de base" || return 1
    [[ ! -f "$backup_file" ]] && { log_error "Fichier introuvable: $backup_file"; return 1; }

    log_header "RESTAURATION: $backup_file → $dbname"
    log_warn "Cette opération va ÉCRASER la base '$dbname'"
    confirm "Confirmer la restauration ?" || { log_info "Annulé"; return 0; }

    local sql_file="$backup_file"
    local tmp_cleanup=false
    if [[ "$backup_file" == *.gz ]]; then
        sql_file=$(mktemp "${TMPDIR:-/tmp}/pg_restore_XXXXXX.sql")
        tmp_cleanup=true
        gunzip -c "$backup_file" > "$sql_file"
    fi

    PGPASSFILE="$TEMP_PGPASSFILE" psql \
        -h "$PG_HOST" -p "$PG_PORT" \
        -U "$PG_ADMIN_USER" -d "$dbname" \
        --no-password -v ON_ERROR_STOP=0 \
        -f "$sql_file"

    [[ "$tmp_cleanup" == true ]] && rm -f "$sql_file"
    audit_log "RESTORE" "db=$dbname file=$backup_file"
    log_success "Restauration terminée"
}

# =============================================================================
# MONITORING
# =============================================================================

monitor_stats() {
    log_header "STATISTIQUES"

    echo -e "\n${WHITE}── Taille des bases ──${NC}"
    execute_sql "
SELECT datname     AS \"Base\",
       pg_size_pretty(pg_database_size(datname)) AS \"Taille\",
       numbackends AS \"Connexions actives\"
FROM pg_stat_database
WHERE datname NOT LIKE 'template%'
ORDER BY pg_database_size(datname) DESC;"

    echo -e "\n${WHITE}── Connexions par état ──${NC}"
    execute_sql "
SELECT datname AS \"Base\", usename AS \"Utilisateur\",
       state AS \"État\", count(*) AS \"Nb\"
FROM pg_stat_activity
WHERE datname IS NOT NULL
GROUP BY datname, usename, state
ORDER BY count(*) DESC;"

    echo -e "\n${WHITE}── Tables les plus volumineuses (${PG_DEFAULT_DB}) ──${NC}"
    execute_sql "
SELECT schemaname AS \"Schéma\", tablename AS \"Table\",
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS \"Taille\"
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 10;" "$PG_DEFAULT_DB"
}

monitor_connections() {
    log_header "CONNEXIONS ACTIVES"
    execute_sql "
SELECT pid AS \"PID\",
       usename AS \"Utilisateur\",
       datname AS \"Base\",
       client_addr AS \"Client\",
       state AS \"État\",
       to_char(query_start, 'HH24:MI:SS') AS \"Début\",
       left(query, 70) AS \"Requête\"
FROM pg_stat_activity
WHERE datname IS NOT NULL
ORDER BY query_start DESC NULLS LAST;"
}

monitor_slow_queries() {
    local threshold_ms="${1:-5000}"
    log_header "REQUÊTES LENTES (> ${threshold_ms} ms)"
    execute_sql "
SELECT pid,
       usename AS \"Utilisateur\",
       datname AS \"Base\",
       round(EXTRACT(EPOCH FROM (now() - query_start)) * 1000)::int AS \"Durée ms\",
       state AS \"État\",
       left(query, 80) AS \"Requête\"
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start IS NOT NULL
  AND EXTRACT(EPOCH FROM (now() - query_start)) * 1000 > ${threshold_ms}
ORDER BY query_start;"
}

monitor_locks() {
    log_header "VERROUS ACTIFS"
    execute_sql "
SELECT a.pid,
       a.usename AS \"Utilisateur\",
       a.datname AS \"Base\",
       l.locktype AS \"Type\",
       l.mode AS \"Mode\",
       CASE WHEN l.granted THEN 'Acquis' ELSE 'En attente' END AS \"État\",
       left(a.query, 60) AS \"Requête\"
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE NOT l.granted OR l.mode LIKE '%ExclusiveLock%'
ORDER BY l.granted, a.pid;"
}

monitor_kill_connections() {
    local dbname="$1"
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "FERMETURE CONNEXIONS: $dbname"
    confirm "Fermer toutes les connexions à '$dbname' ?" || { log_info "Annulé"; return 0; }

    execute_sql "
SELECT count(pg_terminate_backend(pid)) AS \"Connexions fermées\"
FROM pg_stat_activity
WHERE datname = '$(pg_escape_literal "$dbname")' AND pid <> pg_backend_pid();"

    audit_log "KILL_CONNECTIONS" "db=$dbname"
    log_success "Connexions fermées sur '$dbname'"
}

# =============================================================================
# SÉLECTEURS INTERACTIFS (PICKERS)
# =============================================================================
# Chaque picker :
#   1. Affiche une liste numérotée des entités disponibles (depuis PG)
#   2. Accepte un numéro OU un nom saisi directement
#   3. Retourne la valeur via stdout
# =============================================================================

# Affiche une liste numérotée et retourne la valeur choisie
# Usage: val=$(_pick "Titre de la liste" "libellé prompt" item1 item2 ...)
# IMPORTANT: tout l'affichage va sur stderr (&2) pour ne pas être avalé par $()
_pick() {
    local title="$1" prompt="$2"; shift 2
    local -a items=("$@")

    if (( ${#items[@]} == 0 )); then
        echo -e "\n  ${YELLOW}[!] Aucun élément disponible — saisie libre${NC}" >&2
        local val
        read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} (saisie libre): ")" val </dev/tty
        echo "$val"
        return
    fi

    echo -e "\n  ${WHITE}${title} :${NC}" >&2
    local i=1
    for item in "${items[@]}"; do
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$item" >&2
        ((i++))
    done
    echo "" >&2

    local sel
    # read depuis /dev/tty pour que le prompt soit toujours visible même dans $()
    read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} (numéro ou nom): ")" sel </dev/tty

    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#items[@]} )); then
        echo "${items[$((sel-1))]}"
    else
        echo "$sel"
    fi
}

# =============================================================================
# MULTI-SÉLECTION
# =============================================================================
#
# Retourne les éléments sélectionnés, un par ligne (stdout).
# Syntaxe utilisateur :
#   "1 3"   → items 1 et 3
#   "1-3"   → items 1, 2, 3 (plage inclusive)
#   "all"   → tous les items
#   "q"     → annuler (return 1)
#
# Usage : raw=$(pick_multi_xxx ...) || { log_info "Annulé"; continue; }
#         while IFS= read -r item; do ... done <<< "$raw"

_pick_multi() {
    local title="$1" prompt="$2"; shift 2
    local -a items=("$@")
    local n=${#items[@]}

    if (( n == 0 )); then
        echo -e "\n  ${YELLOW}[!] Aucun élément disponible${NC}" >&2
        return 1
    fi

    echo -e "\n  ${WHITE}${title} :${NC}" >&2
    local i=1
    for item in "${items[@]}"; do
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$item" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    echo -e "  ${YELLOW}Syntaxe :${NC}  numéros ex: ${BOLD}1 3${NC}  |  plage ex: ${BOLD}1-3${NC}  |  ${BOLD}all${NC}  |  ${BOLD}q${NC} = annuler" >&2
    echo "" >&2

    local sel
    read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} : ")" sel </dev/tty

    [[ "$sel" == "q" || "$sel" == "Q" ]] && return 1

    if [[ "$sel" == "all" || "$sel" == "ALL" ]]; then
        printf '%s\n' "${items[@]}"
        return 0
    fi

    local -a selected=()
    local token
    for token in $sel; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
            local j
            for (( j=from; j<=to; j++ )); do
                (( j >= 1 && j <= n )) && selected+=("${items[$((j-1))]}")
            done
        elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= n )); then
            selected+=("${items[$((token-1))]}")
        fi
    done

    if (( ${#selected[@]} == 0 )); then
        log_error "Aucune sélection valide" >&2
        return 1
    fi

    printf '%s\n' "${selected[@]}"
}

# Sélectionner un utilisateur (rôles avec login)
pick_user() {
    local prompt="${1:-Utilisateur}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT rolname FROM pg_roles
         WHERE rolname NOT LIKE 'pg_%' AND rolcanlogin = true
         ORDER BY rolname;")
    _pick "Utilisateurs disponibles" "$prompt" "${items[@]+"${items[@]}"}"
}

# Sélectionner une base de données
pick_database() {
    local prompt="${1:-Base de données}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT datname FROM pg_database
         WHERE datistemplate = false ORDER BY datname;")
    _pick "Bases disponibles" "$prompt" "${items[@]+"${items[@]}"}"
}

# Sélectionner un schéma dans une base donnée (cascade après pick_database)
pick_schema() {
    local dbname="$1"
    local prompt="${2:-Schéma}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast')
         ORDER BY schema_name;" "$dbname")
    _pick "Schémas de '${dbname}'" "$prompt" "${items[@]+"${items[@]}"}"
}

# Sélectionner une table dans un schéma donné (cascade après pick_schema)
pick_table() {
    local dbname="$1" schema="$2"
    local prompt="${3:-Table}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT table_name FROM information_schema.tables
         WHERE table_schema = '$(pg_escape_literal "$schema")'
           AND table_type IN ('BASE TABLE','VIEW')
         ORDER BY table_name;" "$dbname")
    _pick "Tables de '${schema}' (${dbname})" "$prompt" "${items[@]+"${items[@]}"}"
}

# Sélectionner un profil RBAC (liste statique)
pick_profile() {
    local prompt="${1:-Profil}"
    local -a labels=(
        "engineer   — DDL+DML complet, CREATE, séquences, fonctions"
        "analyst    — SELECT sur schémas analytiques (dwh, mart)"
        "bi         — SELECT sur schéma mart uniquement"
        "service    — Droits minimaux (configurer manuellement)"
        "admin      — Tous les droits sur la base"
    )
    local -a keys=("engineer" "analyst" "bi" "service" "admin")

    echo -e "\n  ${WHITE}Profils RBAC :${NC}" >&2
    local i=1
    for label in "${labels[@]}"; do
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$label" >&2
        ((i++))
    done
    echo "" >&2

    local sel
    read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} (numéro ou nom): ")" sel </dev/tty

    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#keys[@]} )); then
        echo "${keys[$((sel-1))]}"
    else
        echo "$sel"
    fi
}

# Sélectionner un type de permission (liste statique)
pick_perm_type() {
    local prompt="${1:-Type de permission}"
    local -a labels=(
        "readonly   — CONNECT + USAGE + SELECT"
        "readwrite  — CONNECT + USAGE + SELECT/INSERT/UPDATE/DELETE"
        "all        — ALL PRIVILEGES (base + schéma + tables)"
    )
    local -a keys=("readonly" "readwrite" "all")

    echo -e "\n  ${WHITE}Types de permission :${NC}" >&2
    local i=1
    for label in "${labels[@]}"; do
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$label" >&2
        ((i++))
    done
    echo "" >&2

    local sel
    read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} (numéro ou nom): ")" sel </dev/tty

    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#keys[@]} )); then
        echo "${keys[$((sel-1))]}"
    else
        echo "${sel:-readonly}"
    fi
}

# Multi-sélection : schémas d'une base
pick_multi_schema() {
    local dbname="$1"
    local prompt="${2:-Schémas cibles}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast')
         ORDER BY schema_name;" "$dbname")
    _pick_multi "Schémas de '${dbname}'" "$prompt" "${items[@]+"${items[@]}"}"
}

# Multi-sélection : bases de données
pick_multi_database() {
    local prompt="${1:-Bases cibles}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT datname FROM pg_database
         WHERE datistemplate = false ORDER BY datname;")
    _pick_multi "Bases disponibles" "$prompt" "${items[@]+"${items[@]}"}"
}

# Multi-sélection : utilisateurs avec login
pick_multi_user() {
    local prompt="${1:-Utilisateurs cibles}"
    local -a items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(execute_sql_list \
        "SELECT rolname FROM pg_roles
         WHERE rolname NOT LIKE 'pg_%' AND rolcanlogin = true
         ORDER BY rolname;")
    _pick_multi "Utilisateurs disponibles" "$prompt" "${items[@]+"${items[@]}"}"
}

# Multi-sélection : profils RBAC (affiche labels, retourne clés)
pick_multi_profile() {
    local prompt="${1:-Profils}"
    local -a labels=(
        "engineer   — DDL+DML complet, CREATE, séquences, fonctions"
        "analyst    — SELECT sur schémas analytiques (dwh, mart)"
        "bi         — SELECT sur schéma mart uniquement"
        "service    — Droits minimaux (configurer manuellement)"
        "admin      — Tous les droits sur la base"
    )
    local -a keys=("engineer" "analyst" "bi" "service" "admin")
    local n=${#keys[@]}

    echo -e "\n  ${WHITE}Profils RBAC :${NC}" >&2
    local i=1
    for label in "${labels[@]}"; do
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$label" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    echo -e "  ${YELLOW}Syntaxe :${NC}  numéros ex: ${BOLD}1 3${NC}  |  plage ex: ${BOLD}1-3${NC}  |  ${BOLD}all${NC}  |  ${BOLD}q${NC} = annuler" >&2
    echo "" >&2

    local sel
    read -r -p "$(echo -e "  ${WHITE}${prompt}${NC} : ")" sel </dev/tty

    [[ "$sel" == "q" || "$sel" == "Q" ]] && return 1

    if [[ "$sel" == "all" || "$sel" == "ALL" ]]; then
        printf '%s\n' "${keys[@]}"
        return 0
    fi

    local -a selected_keys=()
    local token
    for token in $sel; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
            local j
            for (( j=from; j<=to; j++ )); do
                (( j >= 1 && j <= n )) && selected_keys+=("${keys[$((j-1))]}")
            done
        elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= n )); then
            selected_keys+=("${keys[$((token-1))]}")
        else
            local k
            for k in "${keys[@]}"; do
                [[ "$k" == "$token" ]] && selected_keys+=("$k") && break
            done
        fi
    done

    if (( ${#selected_keys[@]} == 0 )); then
        log_error "Aucune sélection valide" >&2
        return 1
    fi

    printf '%s\n' "${selected_keys[@]}"
}

# =============================================================================
# MENU INTERACTIF
# =============================================================================

_banner() {
    clear 2>/dev/null || true   # ne pas avorter si TERM absent (SSH/CI sans tty)
    echo -e "${CYAN}"
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║     PostgreSQL Admin CLI  v${SCRIPT_VERSION}  —  CICBI           ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${WHITE}Connexion :${NC} ${CYAN}${PG_ADMIN_USER}@${PG_HOST}:${PG_PORT}/${PG_DEFAULT_DB}${NC}"
    printf  "  ${WHITE}Mode      :${NC} ${CYAN}%-10s${NC}  " "$USE_SSH"
    [[ "$USE_SSH" == "ssh" ]] && printf "${WHITE}SSH :${NC} ${CYAN}${SSH_USER}@${SSH_HOST}:${SSH_PORT}${NC}"
    echo ""
    printf  "  ${WHITE}Dry-run   :${NC} ${CYAN}%-10s${NC}  ${WHITE}Verbose :${NC} ${CYAN}%s${NC}\n" "$DRY_RUN" "$VERBOSE"
    echo ""
}

_choice() {
    local prompt="${1:-Choix}"
    local c
    read -r -p "$(echo -e "  ${WHITE}${prompt} :${NC} ")" c
    echo "$c"
}

menu_main() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}MENU PRINCIPAL${NC}"
        echo ""
        echo -e "  ${CYAN}1${NC}  Bases de données"
        echo -e "  ${CYAN}2${NC}  Schémas"
        echo -e "  ${CYAN}3${NC}  Utilisateurs"
        echo -e "  ${CYAN}4${NC}  RBAC / Profils Data"
        echo -e "  ${CYAN}5${NC}  Permissions granulaires"
        echo -e "  ${CYAN}6${NC}  Audit & Rapports"
        echo -e "  ${CYAN}7${NC}  Backup & Restauration"
        echo -e "  ${CYAN}8${NC}  Monitoring"
        echo -e "  ${CYAN}9${NC}  Paramètres & Connexion"
        echo -e "  ${CYAN}10${NC} GitOps / État déclaré"
        echo ""
        echo -e "  ${RED}0${NC}  Quitter"
        echo ""
        local c; c=$(_choice)
        case "$c" in
            1) menu_databases ;;  2) menu_schemas ;;
            3) menu_users ;;      4) menu_rbac ;;
            5) menu_permissions ;; 6) menu_audit ;;
            7) menu_backup ;;    8) menu_monitoring ;;
            9) menu_settings ;;  10) menu_gitops ;;
            0) log_info "À bientôt !"; exit 0 ;;
            *) log_error "Choix invalide: '$c'" ;;
        esac
    done
}

menu_databases() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}1 › BASES DE DONNÉES${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Lister les bases"
        echo -e "  ${CYAN}2${NC}  Créer une base"
        echo -e "  ${CYAN}3${NC}  Supprimer une base  ${RED}[IRRÉVERSIBLE]${NC}"
        echo -e "  ${CYAN}4${NC}  Fermer les connexions actives"
        echo -e "  ${CYAN}5${NC}  Changer le propriétaire (owner)"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) db_list; _press_enter ;;
            2)
                local dn ow
                read -r -p "  Nouveau nom de base     : " dn
                ow=$(pick_user "Propriétaire (vide=${PG_ADMIN_USER})")
                db_create "$dn" "${ow:-$PG_ADMIN_USER}"; _press_enter ;;
            3)
                local dn; dn=$(pick_database "Base à supprimer")
                db_drop "$dn"; _press_enter ;;
            4)
                local dn; dn=$(pick_database "Base cible")
                monitor_kill_connections "$dn"; _press_enter ;;
            5)
                local dn ow
                dn=$(pick_database "Base à modifier")
                ow=$(pick_user "Nouveau propriétaire")
                db_change_owner "$dn" "$ow"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_schemas() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}2 › SCHÉMAS${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Lister les schémas"
        echo -e "  ${CYAN}2${NC}  Créer un schéma"
        echo -e "  ${CYAN}3${NC}  Supprimer un schéma  ${RED}[IRRÉVERSIBLE]${NC}"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1)
                local db; db=$(pick_database "Base de données")
                schema_list "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            2)
                local db sc ow
                db=$(pick_database "Base de données")
                read -r -p "  Nouveau nom du schéma   : " sc
                ow=$(pick_user "Propriétaire (vide=${PG_ADMIN_USER})")
                schema_create "$db" "$sc" "${ow:-$PG_ADMIN_USER}"; _press_enter ;;
            3)
                local db sc cas
                db=$(pick_database "Base de données")
                sc=$(pick_schema "$db" "Schéma à supprimer")
                read -r -p "  Cascade ? (y/N)  : " cas
                [[ "$cas" =~ ^[Yy]$ ]] \
                    && schema_drop "$db" "$sc" "true" \
                    || schema_drop "$db" "$sc" "false"
                _press_enter ;;
            0) return ;;
        esac
    done
}

menu_users() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}3 › UTILISATEURS${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Lister les utilisateurs"
        echo -e "  ${CYAN}2${NC}  Créer un utilisateur"
        echo -e "  ${CYAN}3${NC}  Supprimer un utilisateur  ${RED}[IRRÉVERSIBLE]${NC}"
        echo -e "  ${CYAN}4${NC}  Changer le mot de passe"
        echo -e "  ${CYAN}5${NC}  Verrouiller (NOLOGIN)        ${WHITE}[multi]${NC}"
        echo -e "  ${CYAN}6${NC}  Déverrouiller (LOGIN)        ${WHITE}[multi]${NC}"
        echo -e "  ${CYAN}7${NC}  Définir l'expiration         ${WHITE}[multi]${NC}"
        echo -e "  ${CYAN}8${NC}  Voir les rôles d'un utilisateur"
        echo -e "  ${CYAN}9${NC}  Limiter les connexions (MaxConn)  ${WHITE}[multi]${NC}"
        echo -e "  ${CYAN}10${NC} Rotation des mots de passe échus  ${WHITE}(sécurité)${NC}"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) user_list; _press_enter ;;
            2)
                local un pw pr
                read -r -p "  Nouveau nom d'utilisateur : " un
                read -r -s -p "  Mot de passe (vide=auto)   : " pw; echo ""
                pr=$(pick_profile "Profil à assigner")
                user_create "$un" "$pw" "$pr"; _press_enter ;;
            3)
                local un; un=$(pick_user "Utilisateur à supprimer")
                user_drop "$un"; _press_enter ;;
            4)
                local un pw
                un=$(pick_user "Utilisateur")
                read -r -s -p "  Nouveau mot de passe (vide=auto) : " pw; echo ""
                user_change_password "$un" "$pw"; _press_enter ;;
            5)
                local raw_users un
                raw_users=$(pick_multi_user "Utilisateurs à verrouiller") || { log_info "Annulé"; continue; }
                while IFS= read -r un; do [[ -n "$un" ]] && user_lock "$un"; done <<< "$raw_users"
                _press_enter ;;
            6)
                local raw_users un
                raw_users=$(pick_multi_user "Utilisateurs à déverrouiller") || { log_info "Annulé"; continue; }
                while IFS= read -r un; do [[ -n "$un" ]] && user_unlock "$un"; done <<< "$raw_users"
                _press_enter ;;
            7)
                local raw_users un exp
                raw_users=$(pick_multi_user "Utilisateurs") || { log_info "Annulé"; continue; }
                read -r -p "  Date expiration (YYYY-MM-DD, vide=jamais) : " exp
                while IFS= read -r un; do [[ -n "$un" ]] && user_set_expiry "$un" "$exp"; done <<< "$raw_users"
                _press_enter ;;
            8)
                local un; un=$(pick_user "Utilisateur")
                rbac_show_user_roles "$un"; _press_enter ;;
            9)
                local raw_users un lim
                raw_users=$(pick_multi_user "Utilisateurs") || { log_info "Annulé"; continue; }
                echo -e "  ${YELLOW}Valeurs :${NC}  vide ou -1 = ∞ illimité   0 = bloquer   N = max N connexions"
                read -r -p "  Nouvelle limite à appliquer : " lim
                [[ "$lim" == "q" || "$lim" == "Q" ]] && continue
                while IFS= read -r un; do [[ -n "$un" ]] && user_set_conn_limit "$un" "$lim"; done <<< "$raw_users"
                _press_enter ;;
            10)
                local days
                read -r -p "  Renouveler les mdp plus vieux que (jours, défaut 90) : " days
                security_rotate_due "${days:-90}"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_rbac() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}4 › RBAC / PROFILS DATA${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Lister les rôles"
        echo -e "  ${CYAN}2${NC}  Initialiser les rôles RBAC (1 fois par base)"
        echo -e "  ${CYAN}3${NC}  Appliquer profil(s) sur schéma(s)  ${WHITE}(engineer/analyst/bi × schémas)${NC}"
        echo -e "  ${CYAN}4${NC}  Assigner un profil à un utilisateur"
        echo -e "  ${CYAN}5${NC}  Révoquer un profil d'un utilisateur"
        echo -e "  ${CYAN}6${NC}  ${YELLOW}Réparer toutes les permissions${NC} (après migration Airflow)"
        echo ""
        echo -e "  ${WHITE}Profils :${NC} ${GREEN}engineer${NC} DDL+DML · ${GREEN}analyst${NC} SELECT analytique · ${GREEN}bi${NC} SELECT mart · ${GREEN}service${NC}/${GREEN}admin${NC} (assign uniquement)"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) rbac_list_roles; _press_enter ;;
            2)
                local db; db=$(pick_database "Base de données cible")
                rbac_create_roles "$db"; _press_enter ;;
            3)
                local db raw_profiles raw_sc pr sc
                db=$(pick_database "Base de données")
                raw_profiles=$(pick_multi_profile "Profil(s) à appliquer") || { log_info "Annulé"; continue; }
                raw_sc=$(pick_multi_schema "$db" "Schéma(s) cibles")       || { log_info "Annulé"; continue; }
                while IFS= read -r pr; do
                    [[ -z "$pr" ]] && continue
                    while IFS= read -r sc; do
                        [[ -n "$sc" ]] && rbac_apply_profile "$db" "$sc" "$pr"
                    done <<< "$raw_sc"
                done <<< "$raw_profiles"
                _press_enter ;;
            4)
                local raw_users raw_profiles un pr
                raw_users=$(pick_multi_user "Utilisateurs cibles")    || { log_info "Annulé"; continue; }
                raw_profiles=$(pick_multi_profile "Profils à assigner") || { log_info "Annulé"; continue; }
                while IFS= read -r un; do
                    [[ -z "$un" ]] && continue
                    while IFS= read -r pr; do
                        [[ -n "$pr" ]] && rbac_assign_to_user "$un" "$pr"
                    done <<< "$raw_profiles"
                done <<< "$raw_users"
                _press_enter ;;
            5)
                local raw_users raw_profiles un pr
                raw_users=$(pick_multi_user "Utilisateurs cibles")    || { log_info "Annulé"; continue; }
                raw_profiles=$(pick_multi_profile "Profils à révoquer") || { log_info "Annulé"; continue; }
                while IFS= read -r un; do
                    [[ -z "$un" ]] && continue
                    while IFS= read -r pr; do
                        [[ -n "$pr" ]] && rbac_revoke_from_user "$un" "$pr"
                    done <<< "$raw_profiles"
                done <<< "$raw_users"
                _press_enter ;;
            6)
                local db; db=$(pick_database "Base de données à réparer")
                rbac_repair_all "$db"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_permissions() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}5 › PERMISSIONS GRANULAIRES${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Accorder permissions (par schéma)"
        echo -e "  ${CYAN}2${NC}  Accorder permissions (table précise)"
        echo -e "  ${CYAN}3${NC}  Révoquer permissions  ${RED}[IRRÉVERSIBLE]${NC}"
        echo -e "  ${CYAN}4${NC}  Afficher permissions d'un utilisateur"
        echo -e "  ${WHITE}— Matrice & relations user↔bd —${NC}"
        echo -e "  ${CYAN}5${NC}  Matrice des droits (vue d'ensemble)"
        echo -e "  ${CYAN}6${NC}  Qui peut accéder à une table ? (recherche inversée)"
        echo -e "  ${CYAN}7${NC}  Que peut toucher un utilisateur ? (droits effectifs)"
        echo -e "  ${CYAN}8${NC}  Arbre des rôles d'un utilisateur"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1)
                local raw_users raw_sc db pt un sc
                raw_users=$(pick_multi_user "Utilisateurs cibles")      || { log_info "Annulé"; continue; }
                db=$(pick_database "Base de données")
                raw_sc=$(pick_multi_schema "$db" "Schémas cibles")       || { log_info "Annulé"; continue; }
                pt=$(pick_perm_type "Type de permission")
                while IFS= read -r un; do
                    [[ -z "$un" ]] && continue
                    while IFS= read -r sc; do
                        [[ -n "$sc" ]] && perm_grant "$un" "$db" "${pt:-readonly}" "$sc"
                    done <<< "$raw_sc"
                done <<< "$raw_users"
                _press_enter ;;
            2)
                local un db sc tb pv
                un=$(pick_user "Utilisateur")
                db=$(pick_database "Base de données")
                sc=$(pick_schema "$db" "Schéma")
                tb=$(pick_table "$db" "$sc" "Table cible")
                read -r -p "  Privilèges (ex: SELECT ou SELECT,INSERT) : " pv
                perm_grant_table "$un" "$db" "$sc" "$tb" "${pv:-SELECT}"; _press_enter ;;
            3)
                local raw_users raw_sc db un sc
                raw_users=$(pick_multi_user "Utilisateurs cibles")  || { log_info "Annulé"; continue; }
                db=$(pick_database "Base de données")
                raw_sc=$(pick_multi_schema "$db" "Schémas cibles")   || { log_info "Annulé"; continue; }
                while IFS= read -r un; do
                    [[ -z "$un" ]] && continue
                    while IFS= read -r sc; do
                        [[ -n "$sc" ]] && perm_revoke "$un" "$db" "$sc"
                    done <<< "$raw_sc"
                done <<< "$raw_users"
                _press_enter ;;
            4)
                local un db
                un=$(pick_user "Utilisateur")
                db=$(pick_database "Base de données (vide=${PG_DEFAULT_DB})")
                perm_show "$un" "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            5)
                local db; db=$(pick_database "Base de données")
                perm_matrix "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            6)
                local db sc tb
                db=$(pick_database "Base de données")
                sc=$(pick_schema "$db" "Schéma")
                tb=$(pick_table "$db" "$sc" "Table cible")
                perm_who_can "$db" "$sc" "$tb"; _press_enter ;;
            7)
                local un db
                un=$(pick_user "Utilisateur")
                db=$(pick_database "Base de données")
                perm_what_can "$un" "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            8)
                local un; un=$(pick_user "Utilisateur")
                perm_tree "$un"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_audit() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}6 › AUDIT & RAPPORTS${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Audit complet des permissions"
        echo -e "  ${CYAN}2${NC}  Permissions d'un utilisateur"
        echo -e "  ${CYAN}3${NC}  Consulter les logs d'actions (fichier)"
        echo -e "  ${WHITE}— Traçabilité en base —${NC}"
        echo -e "  ${CYAN}4${NC}  Initialiser l'audit en base (schéma audit)"
        echo -e "  ${CYAN}5${NC}  Rapport d'audit (table action_log)"
        echo -e "  ${CYAN}6${NC}  Générer un rapport HTML"
        echo -e "  ${CYAN}7${NC}  Diff avant/après des droits d'un utilisateur"
        echo -e "  ${WHITE}— Sécurité —${NC}"
        echo -e "  ${CYAN}8${NC}  Audit de sécurité (superusers, expirations, mdp…)"
        echo -e "  ${CYAN}9${NC}  Âge des mots de passe"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1)
                local db; db=$(pick_database "Base de données")
                perm_audit "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            2)
                local un db
                un=$(pick_user "Utilisateur")
                db=$(pick_database "Base de données")
                perm_show "$un" "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            3)
                log_header "LOGS D'ACTIONS"
                local today_log="${LOG_DIR}/audit-$(date +%Y-%m-%d).log"
                if [[ -f "$today_log" ]]; then
                    echo -e "${CYAN}Fichier: $today_log${NC}\n"
                    tail -50 "$today_log"
                else
                    log_warn "Aucun log aujourd'hui (${today_log})"
                    log_info "Logs disponibles:"
                    ls "${LOG_DIR}/"audit-*.log 2>/dev/null || echo "  (aucun)"
                fi
                _press_enter ;;
            4)
                local db; db=$(pick_database "Base hôte de l'audit")
                audit_db_init "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            5)
                local db; db=$(pick_database "Base de l'audit (vide=AUDIT_DB)")
                audit_report "${db:-${AUDIT_DB:-$PG_DEFAULT_DB}}"; _press_enter ;;
            6)
                local db; db=$(pick_database "Base de l'audit (vide=AUDIT_DB)")
                audit_report "${db:-${AUDIT_DB:-$PG_DEFAULT_DB}}" --html; _press_enter ;;
            7)
                local un; un=$(pick_user "Utilisateur")
                audit_diff_user "$un"; _press_enter ;;
            8)
                local db; db=$(pick_database "Base de données")
                security_audit "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            9) security_password_age; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_backup() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}7 › BACKUP & RESTAURATION${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Créer un backup (gzip)        ${WHITE}[multi]${NC}"
        echo -e "  ${CYAN}2${NC}  Restaurer un backup  ${RED}[ÉCRASE LA BASE]${NC}"
        echo -e "  ${CYAN}3${NC}  Vérifier un backup (restauration test, base jetable)"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1)
                local raw_dbs db bd
                raw_dbs=$(pick_multi_database "Bases à sauvegarder") || { log_info "Annulé"; continue; }
                read -r -p "  Répertoire (vide=./backups) : " bd
                while IFS= read -r db; do
                    [[ -n "$db" ]] && backup_db "$db" "${bd:-${SCRIPT_DIR}/backups}"
                done <<< "$raw_dbs"
                _press_enter ;;
            2)
                local db bf
                db=$(pick_database "Base de données cible (restauration)")
                read -r -p "  Fichier de backup (.sql.gz) : " bf
                restore_db "$db" "$bf"; _press_enter ;;
            3)
                local bf
                read -r -p "  Fichier de backup à vérifier (.sql.gz) : " bf
                backup_verify "$bf"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_monitoring() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}8 › MONITORING${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Statistiques générales"
        echo -e "  ${CYAN}2${NC}  Connexions actives"
        echo -e "  ${CYAN}3${NC}  Requêtes lentes"
        echo -e "  ${CYAN}4${NC}  Verrous actifs"
        echo -e "  ${CYAN}5${NC}  Fermer connexions sur une base"
        echo -e "  ${WHITE}— Diagnostic DBA avancé —${NC}"
        echo -e "  ${CYAN}6${NC}  Tableau de bord santé"
        echo -e "  ${CYAN}7${NC}  Bloat (lignes mortes)"
        echo -e "  ${CYAN}8${NC}  Index inutilisés"
        echo -e "  ${CYAN}9${NC}  Top requêtes (pg_stat_statements)"
        echo -e "  ${CYAN}10${NC} Cache hit ratio"
        echo -e "  ${CYAN}11${NC} État autovacuum"
        echo -e "  ${CYAN}12${NC} Transactions longues / idle-in-tx"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) monitor_stats; _press_enter ;;
            2) monitor_connections; _press_enter ;;
            3)
                local ms; read -r -p "  Seuil en ms (vide=5000) : " ms
                monitor_slow_queries "${ms:-5000}"; _press_enter ;;
            4) monitor_locks; _press_enter ;;
            5)
                local db; db=$(pick_database "Base de données")
                monitor_kill_connections "$db"; _press_enter ;;
            6)  local db; db=$(pick_database "Base"); monitor_health "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            7)  local db; db=$(pick_database "Base"); monitor_bloat "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            8)  local db; db=$(pick_database "Base"); monitor_unused_indexes "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            9)  local db; db=$(pick_database "Base"); monitor_top_queries "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            10) local db; db=$(pick_database "Base"); monitor_cache "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            11) local db; db=$(pick_database "Base"); monitor_vacuum "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            12) monitor_long_tx; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_gitops() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}10 › GITOPS / ÉTAT DÉCLARÉ${NC}"; echo ""
        echo -e "  Manifeste : ${CYAN}${STATE_MANIFEST:-<non défini>}${NC}"; echo ""
        echo -e "  ${CYAN}1${NC}  Plan (différences manifeste → base)"
        echo -e "  ${CYAN}2${NC}  Apply (réconciliation)"
        echo -e "  ${CYAN}3${NC}  Drift (objets hors manifeste)"
        echo -e "  ${CYAN}4${NC}  Export de l'état réel → manifeste"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) state_plan; _press_enter ;;
            2) state_apply; _press_enter ;;
            3) state_drift; _press_enter ;;
            4) local db; db=$(pick_database "Base à exporter"); state_export "${db:-$PG_DEFAULT_DB}"; _press_enter ;;
            0) return ;;
        esac
    done
}

menu_settings() {
    while true; do
        _banner
        echo -e "  ${WHITE}${BOLD}9 › PARAMÈTRES${NC}"; echo ""
        echo -e "  ${WHITE}Host    :${NC} ${CYAN}${PG_HOST}:${PG_PORT}${NC}"
        echo -e "  ${WHITE}User    :${NC} ${CYAN}${PG_ADMIN_USER}${NC}"
        echo -e "  ${WHITE}Base    :${NC} ${CYAN}${PG_DEFAULT_DB}${NC}"
        echo -e "  ${WHITE}Mode    :${NC} ${CYAN}${USE_SSH}${NC}"
        [[ "$USE_SSH" == "ssh" ]] && \
            echo -e "  ${WHITE}SSH     :${NC} ${CYAN}${SSH_USER}@${SSH_HOST}:${SSH_PORT}${NC}"
        echo ""
        echo -e "  ${CYAN}1${NC}  Modifier la connexion"
        echo -e "  ${CYAN}2${NC}  Tester la connexion"
        echo -e "  ${CYAN}3${NC}  Basculer dry-run (actuellement: ${CYAN}$DRY_RUN${NC})"
        echo -e "  ${CYAN}4${NC}  Basculer verbose  (actuellement: ${CYAN}$VERBOSE${NC})"
        echo ""; echo -e "  ${YELLOW}0${NC}  ← Retour"; echo ""
        local c; c=$(_choice)
        case "$c" in
            1) _configure_connection ;;
            2) check_connection; _press_enter ;;
            3) [[ "$DRY_RUN"  == true ]] && DRY_RUN=false  || DRY_RUN=true
               log_info "Dry-run → $DRY_RUN" ;;
            4) [[ "$VERBOSE"  == true ]] && VERBOSE=false  || VERBOSE=true
               log_info "Verbose → $VERBOSE" ;;
            0) return ;;
        esac
    done
}

_configure_connection() {
    log_header "CONFIGURATION CONNEXION"
    echo -e "  ${YELLOW}Entrée = conserver la valeur actuelle | q = annuler${NC}"
    echo ""
    local nh np nu npw nd nm

    read -r -p "  Host PostgreSQL (actuel: ${PG_HOST}) : " nh
    [[ "$nh" == "q" || "$nh" == "Q" ]] && log_info "Configuration annulée." && return 0

    read -r -p "  Port            (actuel: ${PG_PORT}) : " np
    [[ "$np" == "q" || "$np" == "Q" ]] && log_info "Configuration annulée." && return 0

    read -r -p "  Utilisateur     (actuel: ${PG_ADMIN_USER}) : " nu
    [[ "$nu" == "q" || "$nu" == "Q" ]] && log_info "Configuration annulée." && return 0

    read -r -s -p "  Mot de passe admin (Entrée pour inchangé) : " npw; echo ""

    read -r -p "  Base par défaut (actuel: ${PG_DEFAULT_DB}) : " nd
    [[ "$nd" == "q" || "$nd" == "Q" ]] && log_info "Configuration annulée." && return 0

    echo "  Mode : 1) local  2) ssh  3) docker  [q pour annuler]"
    read -r -p "  Mode (actuel: ${USE_SSH}) : " nm
    [[ "$nm" == "q" || "$nm" == "Q" ]] && log_info "Configuration annulée." && return 0

    [[ -n "$nh" ]]  && PG_HOST="$nh"
    [[ -n "$np" ]]  && { validate_port "$np" && PG_PORT="$np"; }
    [[ -n "$nu" ]]  && PG_ADMIN_USER="$nu"
    [[ -n "$npw" ]] && PG_ADMIN_PASSWORD="$npw"
    [[ -n "$nd" ]]  && PG_DEFAULT_DB="$nd"

    case "$nm" in
        1) USE_SSH="local" ;;
        2) USE_SSH="ssh"
            local sh sp su sk
            read -r -p "  SSH Host (actuel: ${SSH_HOST}) [q=annuler] : " sh
            [[ "$sh" == "q" || "$sh" == "Q" ]] && log_info "Configuration annulée." && return 0
            read -r -p "  SSH Port (actuel: ${SSH_PORT}) [q=annuler] : " sp
            [[ "$sp" == "q" || "$sp" == "Q" ]] && log_info "Configuration annulée." && return 0
            read -r -p "  SSH User (actuel: ${SSH_USER}) [q=annuler] : " su
            [[ "$su" == "q" || "$su" == "Q" ]] && log_info "Configuration annulée." && return 0
            read -r -p "  SSH Key  (actuel: ${SSH_KEY})  [q=annuler] : " sk
            [[ "$sk" == "q" || "$sk" == "Q" ]] && log_info "Configuration annulée." && return 0
            [[ -n "$sh" ]] && SSH_HOST="$sh"
            [[ -n "$sp" ]] && SSH_PORT="$sp"
            [[ -n "$su" ]] && SSH_USER="$su"
            [[ -n "$sk" ]] && SSH_KEY="$sk" ;;
        3) USE_SSH="docker"
            local dc
            read -r -p "  Conteneur Docker (actuel: ${DOCKER_CONTAINER}) [q=annuler] : " dc
            [[ "$dc" == "q" || "$dc" == "Q" ]] && log_info "Configuration annulée." && return 0
            [[ -n "$dc" ]] && DOCKER_CONTAINER="$dc" ;;
    esac

    setup_pgpassfile

    if check_connection; then
        confirm "Sauvegarder la configuration ?" && save_config
    else
        log_warn "Connexion échouée — configuration non sauvegardée"
    fi
    _press_enter
}

# =============================================================================
# AIDE CLI
# =============================================================================

show_help() {
    cat << HELPEOF
${WHITE}pg-admin.sh v${SCRIPT_VERSION} — PostgreSQL Admin CLI — CICBI${NC}

${CYAN}USAGE:${NC}
  ./${SCRIPT_NAME}                              Mode interactif (menu)
  ./${SCRIPT_NAME} [options] <commande> [args]  Mode CLI

${CYAN}OPTIONS:${NC}
  --dry-run         Affiche le SQL sans exécuter
  --verbose, -v     Logs détaillés (debug)
  --yes, -y         Confirme automatiquement (CI/automation ; ex. state apply)
  --help, -h        Cette aide

${CYAN}BASES DE DONNÉES:${NC}
  db list
  db create       <nom> [owner]
  db drop         <nom>
  db change-owner <nom> <nouveau_owner>

${CYAN}SCHÉMAS:${NC}
  schema list   <db>
  schema create <db> <schema> [owner]
  schema drop   <db> <schema> [cascade]

${CYAN}UTILISATEURS:${NC}
  user list
  user create <user> [password] [profile]
  user drop   <user>
  user passwd <user> [newpassword]
  user lock       <user>
  user unlock     <user>
  user conn-limit <user> [N|-1]   # N connexions max | -1 = ∞ | 0 = bloquer

${CYAN}RBAC — PROFILS DATA:${NC}
  rbac roles                         Lister les rôles
  rbac init  <db>                    Initialiser les rôles (1 fois)
  rbac apply <db> <schema> <profil>  Appliquer un template sur un schéma
  rbac assign <user> <profil>        Assigner un profil
  rbac revoke <user> <profil>        Révoquer un profil

  Profils : ${GREEN}engineer${NC} | ${GREEN}analyst${NC} | ${GREEN}bi${NC} | ${GREEN}service${NC} | ${GREEN}admin${NC}

${CYAN}PERMISSIONS:${NC}
  perm grant       <user> <db> <type> [schema]   readonly|readwrite|all
  perm grant-table <user> <db> <schema> <table> [privs]
  perm revoke      <user> <db> [schema]
  perm show        <user> [db]
  perm audit       [db]

${CYAN}MATRICE & RELATIONS (user ↔ bd):${NC}
  perm matrix   [db]                  Vue d'ensemble user↔bases / user×schémas
  perm who-can  <db> <schema> <table> Qui peut accéder à cette table (effectif)
  perm what-can <user> [db]           Que peut toucher cet utilisateur (effectif)
  perm tree     <user>                Arbre d'appartenance aux rôles

${CYAN}TRAÇABILITÉ / AUDIT EN BASE:${NC}
  audit db-init <db>                  Crée le schéma audit (action_log, acl_snapshot)
  audit report  [db] [--html]        Rapport des actions (texte ou HTML)
  audit diff    <user> [db]           Diff avant/après des droits (2 snapshots)
  (activer l'enregistrement auto : export AUDIT_DB=<db>)

${CYAN}GITOPS / ÉTAT DÉCLARÉ:${NC}
  state plan                          Diff manifeste (desired/state.conf) → base
  state apply                         Réconcilie la base sur le manifeste
  state drift                         Objets présents en base hors manifeste
  state export <db>                   Génère un manifeste depuis l'état réel

${CYAN}BACKUP:${NC}
  backup  <db> [répertoire]
  backup verify <fichier.sql[.gz]>   Restaure dans une base jetable et valide
  restore <db> <fichier.sql.gz>

${CYAN}SÉCURITÉ & ROTATION:${NC}
  security audit        [db]         Superusers, expirations, conn illimitées, sans mdp
  security password-age              Âge des mots de passe (nécessite AUDIT_DB)
  security rotate       <user>       Renouvelle le mdp d'un utilisateur (+ credentials)
  security rotate-due   [jours=90]   Renouvelle tous les mdp échus (exclut l'admin courant)

${CYAN}MONITORING:${NC}
  monitor stats
  monitor connections
  monitor slow [seuil_ms]
  monitor locks
  monitor kill <db>
  ${WHITE}— Diagnostic DBA avancé —${NC}
  monitor health         [db]    Tableau de bord santé (cache, connexions, locks)
  monitor bloat          [db]    Tables avec lignes mortes
  monitor unused-indexes [db]    Index jamais scannés
  monitor index-usage    [db]    Ratio seq scan vs index scan
  monitor top            [db] [n] Top requêtes (pg_stat_statements)
  monitor cache          [db]    Cache hit ratio
  monitor vacuum         [db]    État autovacuum
  monitor long-tx                Transactions longues / idle-in-tx

${CYAN}CONNEXION:${NC}
  test     Tester la connexion
  config   Configurer la connexion

${CYAN}EXEMPLES:${NC}

  # Initialiser le RBAC sur la base analytics
  ./${SCRIPT_NAME} rbac init db_analytics_oscrum

  # Créer un Data Analyst et lui assigner son profil
  ./${SCRIPT_NAME} user create alice "" analyst
  ./${SCRIPT_NAME} rbac assign alice analyst

  # Appliquer les droits analyst sur le schéma dwh
  ./${SCRIPT_NAME} rbac apply db_analytics_oscrum dwh analyst

  # Appliquer les droits engineer sur staging et dwh
  ./${SCRIPT_NAME} rbac apply db_analytics_oscrum staging engineer
  ./${SCRIPT_NAME} rbac apply db_analytics_oscrum dwh engineer

  # Audit complet des permissions
  ./${SCRIPT_NAME} perm audit db_analytics_oscrum

  # Preview SQL (dry-run)
  ./${SCRIPT_NAME} --dry-run perm grant bob db_analytics_oscrum readonly staging

  # Backup de la base de production
  ./${SCRIPT_NAME} backup db_analytics_oscrum /srv/backups

HELPEOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parsing des options globales (avant le sous-command)
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run)     DRY_RUN=true ;;
            --verbose|-v)  VERBOSE=true ;;
            --yes|-y)      ASSUME_YES=true ;;
            --help|-h)     show_help; exit 0 ;;
            *)             args+=("$arg") ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    # Sélection du serveur via servers.conf (si PG_CONFIG_FILE non défini en env)
    [[ -z "${PG_CONFIG_FILE:-}" ]] && _select_server_from_conf

    load_config
    check_requirements
    _test_docker
    setup_pgpassfile

    mkdir -p "$LOG_DIR" "$CREDS_DIR"
    chmod 700 "$CREDS_DIR" 2>/dev/null || true

    # Mode interactif si aucun argument
    if [[ $# -eq 0 ]]; then
        if ! check_connection 2>/dev/null; then
            log_warn "Connexion échouée — le serveur est peut-être inaccessible"
            confirm "Reconfigurer la connexion manuellement ?" && _configure_connection
        fi
        menu_main
        exit 0
    fi

    local cmd="$1"; shift

    # Vérification connexion pour toutes les commandes sauf help/config
    if [[ "$cmd" != "help" && "$cmd" != "config" && "$DRY_RUN" != "true" ]]; then
        check_connection || { log_error "Connexion requise. Lancez: ./${SCRIPT_NAME} config"; exit 1; }
    fi

    case "$cmd" in
        db)
            local sub="${1:-list}"; shift || true
            case "$sub" in
                list)         db_list ;;
                create)       db_create "$@" ;;
                drop)         db_drop "$@" ;;
                change-owner) db_change_owner "$@" ;;
                *)      log_error "Sous-commande inconnue: db $sub"; show_help; exit 1 ;;
            esac ;;
        schema)
            local sub="${1:-list}"; shift || true
            case "$sub" in
                list)   schema_list "$@" ;;
                create) schema_create "$@" ;;
                drop)   schema_drop "$@" ;;
                *)      log_error "Sous-commande inconnue: schema $sub"; exit 1 ;;
            esac ;;
        user)
            local sub="${1:-list}"; shift || true
            case "$sub" in
                list)   user_list ;;
                create) user_create "$@" ;;
                drop)   user_drop "$@" ;;
                passwd)     user_change_password "$@" ;;
                lock)       user_lock "$@" ;;
                unlock)     user_unlock "$@" ;;
                conn-limit) user_set_conn_limit "$@" ;;
                *)          log_error "Sous-commande inconnue: user $sub"; exit 1 ;;
            esac ;;
        rbac)
            local sub="${1:-roles}"; shift || true
            case "$sub" in
                roles)  rbac_list_roles ;;
                init)   rbac_create_roles "$@" ;;
                apply)
                    local db="${1:-}" sc="${2:-public}" profile="${3:-analyst}"
                    [[ -z "$db" ]] && { log_error "Usage: rbac apply <db> <schema> <profile>"; exit 1; }
                    rbac_apply_profile "$db" "$sc" "$profile" ;;
                assign)     rbac_assign_to_user "$@" ;;
                revoke)     rbac_revoke_from_user "$@" ;;
                repair-all) rbac_repair_all "$@" ;;
                *)          log_error "Sous-commande inconnue: rbac $sub"; exit 1 ;;
            esac ;;
        perm)
            local sub="${1:-show}"; shift || true
            case "$sub" in
                grant)       perm_grant "$@" ;;
                grant-table) perm_grant_table "$@" ;;
                revoke)      perm_revoke "$@" ;;
                show)        perm_show "$@" ;;
                audit)       perm_audit "$@" ;;
                matrix)      perm_matrix "$@" ;;
                who-can)     perm_who_can "$@" ;;
                what-can)    perm_what_can "$@" ;;
                tree)        perm_tree "$@" ;;
                *)           log_error "Sous-commande inconnue: perm $sub"; exit 1 ;;
            esac ;;
        backup)
            if [[ "${1:-}" == "verify" ]]; then shift; backup_verify "$@"; else backup_db "$@"; fi ;;
        restore) restore_db "$@" ;;
        security)
            local sub="${1:-audit}"; shift || true
            case "$sub" in
                audit)        security_audit "$@" ;;
                password-age) security_password_age ;;
                rotate)       security_rotate "$@" ;;
                rotate-due)   security_rotate_due "$@" ;;
                *)            log_error "Sous-commande inconnue: security $sub (audit|password-age|rotate|rotate-due)"; exit 1 ;;
            esac ;;
        monitor)
            local sub="${1:-stats}"; shift || true
            case "$sub" in
                stats)       monitor_stats ;;
                connections) monitor_connections ;;
                slow)        monitor_slow_queries "$@" ;;
                locks)       monitor_locks ;;
                kill)        monitor_kill_connections "$@" ;;
                bloat)          monitor_bloat "$@" ;;
                unused-indexes) monitor_unused_indexes "$@" ;;
                index-usage)    monitor_index_usage "$@" ;;
                top)            monitor_top_queries "$@" ;;
                cache)          monitor_cache "$@" ;;
                vacuum)         monitor_vacuum "$@" ;;
                long-tx)        monitor_long_tx "$@" ;;
                health)         monitor_health "$@" ;;
                *)           log_error "Sous-commande inconnue: monitor $sub"; exit 1 ;;
            esac ;;
        audit)
            local sub="${1:-report}"; shift || true
            case "$sub" in
                db-init) audit_db_init "$@" ;;
                report)  audit_report "$@" ;;
                diff)    audit_diff_user "$@" ;;
                *)       log_error "Sous-commande inconnue: audit $sub (db-init|report|diff)"; exit 1 ;;
            esac ;;
        state)
            local sub="${1:-plan}"; shift || true
            case "$sub" in
                plan)   state_plan ;;
                apply)  state_apply ;;
                drift)  state_drift ;;
                export) state_export "$@" ;;
                *)      log_error "Sous-commande inconnue: state $sub (plan|apply|drift|export)"; exit 1 ;;
            esac ;;
        test)   check_connection ;;
        config) _configure_connection ;;
        help)   show_help ;;
        *)
            log_error "Commande inconnue: '$cmd'"
            echo ""
            show_help
            exit 1 ;;
    esac
}

# Chargement du module d'extensions DBA (matrice, audit en base, GitOps, monitoring avancé)
if [[ -f "${SCRIPT_DIR}/pg-admin-ext.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/pg-admin-ext.sh"
fi

main "$@"
