#!/bin/bash

# ============================================================================
# DevOps - Docker Management CLI
# Description: Script avancé de gestion Docker pour environnements Dev & Prod
# Usage: ./deploy.sh <command> <environment> [options]
# ============================================================================

set -e  # Exit on error

# ============================================================================
# CONFIGURATION & COULEURS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger la configuration depuis .devops.yml
source "$SCRIPT_DIR/config-loader.sh"
load_devops_config

# Si PROJECT_ROOT n'est pas défini (ancien comportement), utiliser ../..
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    export PROJECT_ROOT
fi

PROJECT_RUNTIME_ROOT="${PROJECT_RUNTIME_ROOT:-$PROJECT_ROOT}"
export PROJECT_RUNTIME_ROOT

cd "$PROJECT_RUNTIME_ROOT"
DEFAULT_PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_ROOT")}"

# COMPOSE_PROJECT_NAME est maintenant chargé depuis .devops.yml
# Pas de valeur par défaut - utilise celle de config-loader.sh

# ============================================================================
# FONCTIONS D'AFFICHAGE
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_header() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${WHITE}$1${NC}"
    echo -e "${CYAN}========================================${NC}\n"
}

print_separator() {
    echo -e "${CYAN}----------------------------------------${NC}"
}

# ============================================================================
# CONFIGURATION PROFILS REGISTRY
# ============================================================================

# Dossier des profils registry (partagé avec registry.sh)
PROFILES_DIR="$SCRIPT_DIR/.registry-profiles"
CURRENT_PROFILE=""
LAST_PROFILE_FILE="$SCRIPT_DIR/.last-registry-profile"

# Charger le dernier profil utilisé si disponible (UNIQUEMENT les credentials)
if [ -f "$LAST_PROFILE_FILE" ]; then
    CURRENT_PROFILE=$(cat "$LAST_PROFILE_FILE")
    if [ -f "$PROFILES_DIR/${CURRENT_PROFILE}.env" ]; then
        # Charger uniquement les credentials REGISTRY, pas les infos projet
        # GITHUB_TOKEN vient de .devops.yml (spécifique au projet Git)
        local_type=$(grep "^REGISTRY_TYPE=" "$PROFILES_DIR/${CURRENT_PROFILE}.env" 2>/dev/null | cut -d'=' -f2)
        local_token=$(grep "^REGISTRY_TOKEN=" "$PROFILES_DIR/${CURRENT_PROFILE}.env" 2>/dev/null | cut -d'=' -f2)
        local_password=$(grep "^REGISTRY_PASSWORD=" "$PROFILES_DIR/${CURRENT_PROFILE}.env" 2>/dev/null | cut -d'=' -f2)
        [ -n "$local_type" ] && REGISTRY_TYPE="$local_type"
        [ -n "$local_token" ] && REGISTRY_TOKEN="$local_token"
        [ -n "$local_password" ] && REGISTRY_PASSWORD="$local_password"
        # Note: GITHUB_TOKEN n'est PAS chargé depuis le profil
        log_info "Profil registry chargé: $CURRENT_PROFILE" >&2
    fi
fi

# Variables pour docker-compose registry (définies par défaut pour éviter les warnings)
export IMAGE_TAG=${IMAGE_TAG:-""}
export IMAGE_FULL=${IMAGE_FULL:-""}
export ENVIRONMENT=${ENVIRONMENT:-""}

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

# Charger les variables d'environnement
load_env() {
    local env=$1

    # Chercher le fichier .env dans deployment/ ou à la racine
    local env_file
    if [ -f ".env.$env.local" ]; then
        env_file=".env.$env.local"
    elif [ -f ".env.$env" ]; then
        env_file=".env.$env"
    elif [ -f "deployment/.env.$env.local" ]; then
        env_file="deployment/.env.$env.local"
    elif [ -f "deployment/.env.$env" ]; then
        env_file="deployment/.env.$env"
    else
        log_error "Fichier .env.$env(.local) introuvable (cherché dans racine puis deployment/)"
        exit 1
    fi

    log_info "Chargement de $env_file"

    # Charger les variables (ignorer les commentaires et lignes vides)
    while IFS='=' read -r key value; do
        # Ignorer commentaires et lignes vides
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue

        # Supprimer les espaces et quotes
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

        # Exporter la variable
        export "$key=$value"
    done < "$env_file"

    # Normaliser les variables Docker les plus utilisées par docker-compose.
    # Fallback: utiliser la config projet (.devops.yml) quand .env.<env> est incomplet.
    export ENV="${ENV:-$env}"
    if [ -z "${AIRFLOW_ENV_FILE:-}" ]; then
        if [[ "$env_file" == deployment/* ]]; then
            export AIRFLOW_ENV_FILE="${env_file#deployment/}"
        else
            export AIRFLOW_ENV_FILE="../$env_file"
        fi
    fi
    export DOCKER_REGISTRY="${DOCKER_REGISTRY:-${REGISTRY_URL:-docker.io}}"
    export DOCKER_USERNAME="${DOCKER_USERNAME:-${REGISTRY_USERNAME:-}}"
    export IMAGE_NAME="${IMAGE_NAME:-${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}}"

    # Validation explicite pour éviter l'erreur docker "invalid reference format"
    # quand une image est construite avec ".../${DOCKER_USERNAME}/...".
    if [ -z "${DOCKER_USERNAME:-}" ]; then
        if grep -q '\${DOCKER_USERNAME' "deployment/docker-compose.yml" 2>/dev/null \
           || grep -q '\${DOCKER_USERNAME' "deployment/docker-compose.${env}.yml" 2>/dev/null; then
            log_error "DOCKER_USERNAME est vide (ni .env.${env} ni .devops.yml -> REGISTRY_USERNAME)."
            log_error "Définissez DOCKER_USERNAME dans .env.${env} ou REGISTRY_USERNAME dans .devops.yml."
            exit 1
        fi
    fi
}

# ============================================================================
# FONCTIONS GESTION PROFILS REGISTRY
# ============================================================================

# Lister les profils disponibles
registry_list_profiles() {
    log_header "PROFILS REGISTRY DISPONIBLES"

    if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/*.env 2>/dev/null)" ]; then
        log_warn "Aucun profil registry trouvé"
        log_info "Créez un profil avec: ./scripts/registry.sh profile create <nom>"
        return 0
    fi

    echo -e "${CYAN}Projet actuel:${NC} ${WHITE}${REGISTRY_USERNAME:-?}/${IMAGE_NAME:-?}${NC} (depuis .devops.yml)"
    echo ""

    local current_marker=""
    local i=1
    for pfile in "$PROFILES_DIR"/*.env; do
        local pname=$(basename "$pfile" .env)
        if [ "$pname" == "$CURRENT_PROFILE" ]; then
            current_marker=" ${GREEN}(actif)${NC}"
        else
            current_marker=""
        fi

        # Lire le type depuis le profil sans utiliser source
        local ptype=$(grep "^REGISTRY_TYPE=" "$pfile" 2>/dev/null | cut -d'=' -f2)

        echo -e "  ${CYAN}$i)${NC} ${WHITE}$pname${NC}$current_marker"
        echo -e "     Type: ${ptype:-dockerhub}"
        echo ""
        ((i++))
    done
}

# Charger un profil registry (credentials uniquement)
registry_load_profile() {
    local profile_name=$1

    if [ -z "$profile_name" ]; then
        # Mode interactif - afficher une liste numérotée
        log_header "CHARGER UN PROFIL REGISTRY"

        if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/*.env 2>/dev/null)" ]; then
            log_warn "Aucun profil registry trouvé"
            log_info "Créez un profil avec: ./deployment/scripts/registry.sh profile create <nom>"
            return 1
        fi

        echo -e "${CYAN}Projet actuel:${NC} ${WHITE}${REGISTRY_USERNAME:-?}/${IMAGE_NAME:-?}${NC} (depuis .devops.yml)"
        echo ""

        local profiles=()
        local i=1
        for pfile in "$PROFILES_DIR"/*.env; do
            local pname=$(basename "$pfile" .env)
            profiles+=("$pname")

            # Lire le type depuis le profil sans utiliser source
            local ptype=$(grep "^REGISTRY_TYPE=" "$pfile" 2>/dev/null | cut -d'=' -f2)

            # Marquer le profil actif
            local marker=""
            if [ "$pname" == "$CURRENT_PROFILE" ]; then
                marker=" ${GREEN}(actif)${NC}"
            fi

            echo -e "  ${CYAN}$i)${NC} ${WHITE}$pname${NC}$marker"
            echo -e "     Type: ${ptype:-dockerhub}"
            echo ""
            ((i++))
        done

        echo ""
        read -p "Choisissez un profil (1-${#profiles[@]}) ou tapez le nom: " choice

        # Vérifier si c'est un numéro
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
                profile_name="${profiles[$((choice-1))]}"
            else
                log_error "Numéro invalide"
                return 1
            fi
        else
            profile_name="$choice"
        fi
    fi

    local profile_file="$PROFILES_DIR/${profile_name}.env"

    if [ ! -f "$profile_file" ]; then
        log_error "Profil '$profile_name' introuvable"
        return 1
    fi

    # Charger UNIQUEMENT les credentials REGISTRY depuis le profil
    # GITHUB_TOKEN vient de .devops.yml (spécifique au projet Git)
    local temp_type=$(grep "^REGISTRY_TYPE=" "$profile_file" 2>/dev/null | cut -d'=' -f2)
    local temp_token=$(grep "^REGISTRY_TOKEN=" "$profile_file" 2>/dev/null | cut -d'=' -f2)
    local temp_password=$(grep "^REGISTRY_PASSWORD=" "$profile_file" 2>/dev/null | cut -d'=' -f2)

    [ -n "$temp_type" ] && REGISTRY_TYPE="$temp_type"
    [ -n "$temp_token" ] && REGISTRY_TOKEN="$temp_token"
    [ -n "$temp_password" ] && REGISTRY_PASSWORD="$temp_password"
    # Note: GITHUB_TOKEN n'est PAS chargé depuis le profil (vient de .devops.yml)

    CURRENT_PROFILE="$profile_name"
    echo "$profile_name" > "$LAST_PROFILE_FILE"

    log_success "Profil '$profile_name' chargé"
    log_info "Registry: ${REGISTRY_URL}"
    log_info "Image: ${REGISTRY_USERNAME}/${IMAGE_NAME}"
}

# Construire le nom complet de l'image depuis le registry
build_registry_image_name() {
    local env=$1
    local tag=${2:-${env}-latest}

    if [ -z "$REGISTRY_USERNAME" ] || [ -z "$IMAGE_NAME" ]; then
        log_error "Profil registry non chargé. Utilisez: charger-profil"
        return 1
    fi

    local repository
    repository=$(get_registry_repository)

    if [ "$REGISTRY_URL" == "docker.io" ]; then
        echo "${repository}:${tag}"
    else
        echo "${REGISTRY_URL}/${repository}:${tag}"
    fi
}

# Construire le repository registry en évitant les doublons namespace/image.
# Supporte:
# - IMAGE_NAME="cicbi-kafka-platform" + REGISTRY_USERNAME="effijeanmermoz" -> effijeanmermoz/cicbi-kafka-platform
# - IMAGE_NAME="effijeanmermoz/cicbi-kafka-platform"                      -> effijeanmermoz/cicbi-kafka-platform
get_registry_repository() {
    local image_name="${IMAGE_NAME}"

    if [[ "$image_name" == */* ]]; then
        echo "$image_name"
    elif [ -n "$REGISTRY_USERNAME" ]; then
        echo "${REGISTRY_USERNAME}/${image_name}"
    else
        echo "$image_name"
    fi
}

# Lister les tags disponibles dans le registry
registry_list_tags() {
    local env=$1

    if [ -z "$REGISTRY_USERNAME" ] || [ -z "$IMAGE_NAME" ]; then
        log_error "Profil registry non chargé"
        return 1
    fi

    log_header "TAGS DISPONIBLES - $env"

    case "${REGISTRY_TYPE:-dockerhub}" in
        dockerhub)
            log_info "Interrogation de Docker Hub..."
            local repository
            repository=$(get_registry_repository)
            local api_url="https://hub.docker.com/v2/repositories/${repository}/tags?page_size=100"

            # Récupérer les tags et leurs dates, filtrer par environnement
            local response
            response=$(curl -s "$api_url")
            if [ -z "$response" ]; then
                log_warn "Réponse vide de Docker Hub"
                return 1
            fi

            local tags
            tags=$(DOCKERHUB_RESPONSE="$response" python3 - "$env" <<'PY'
import json
import os
import sys
from datetime import datetime

env = sys.argv[1]
try:
    data = json.loads(os.environ.get("DOCKERHUB_RESPONSE", "{}"))
except Exception:
    sys.exit(2)
items = data.get("results", [])
out = []
for it in items:
    name = it.get("name", "")
    if not name.startswith(env + "-"):
        continue
    last = it.get("last_updated") or it.get("tag_last_pushed") or ""
    if last:
        try:
            dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
            last = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
        except Exception:
            pass
    if not last:
        last = "date inconnue"
    out.append((name, last))

out.sort(key=lambda x: x[0], reverse=True)
for name, last in out:
    print(f"{name}|{last}")
PY
)
            local parse_status=$?

            if [ $parse_status -ne 0 ]; then
                log_warn "Réponse Docker Hub invalide"
                return 1
            fi

            if [ -z "$tags" ]; then
                log_warn "Aucun tag trouvé pour l'environnement $env"
                return 1
            fi

            echo -e "${CYAN}Tags disponibles pour ${WHITE}$env${NC}:\n"

            local count=1
            echo "$tags" | while IFS='|' read -r tag tag_date; do
                if [[ "$tag" == *"-latest" ]]; then
                    echo -e "  ${GREEN}$count)${NC} ${WHITE}$tag${NC} ${CYAN}(recommandé)${NC} - $tag_date"
                else
                    echo -e "  ${CYAN}$count)${NC} $tag - $tag_date"
                fi
                ((count++))
            done
            ;;

        *)
            log_warn "Listing des tags non implémenté pour: ${REGISTRY_TYPE}"
            ;;
    esac
}

# Vérifier les prérequis
check_requirements() {
    local missing=0

    if ! command -v docker &> /dev/null; then
        log_error "Docker n'est pas installé"
        missing=1
    fi

    if ! command -v docker compose &> /dev/null; then
        log_error "Docker Compose n'est pas installé"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# Valider l'environnement
validate_env() {
    local env=$1
    if [ "$env" != "dev" ] && [ "$env" != "staging" ] && [ "$env" != "prod" ] && [ "$env" != "all" ]; then
        log_error "Environnement invalide: $env (doit être 'dev', 'staging', 'prod' ou 'all')"
        exit 1
    fi
}

get_runtime_subdir() {
    if [ "${PROJECT_RUNTIME_ROOT:-$PROJECT_ROOT}" = "$PROJECT_ROOT" ]; then
        echo ""
    elif [[ "${PROJECT_RUNTIME_ROOT:-}" == "$PROJECT_ROOT/"* ]]; then
        echo "${PROJECT_RUNTIME_ROOT#$PROJECT_ROOT/}"
    else
        echo ""
    fi
}

# Définir un nom de projet Compose cohérent pour l'environnement ciblé.
set_compose_project_name_for_env() {
    local env=$1
    local base_compose_name="${COMPOSE_PROJECT_NAME:-${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}}"
    local known_env

    # Éviter l'accumulation des suffixes lors d'actions successives (dev -> prod).
    for known_env in dev staging prod; do
        if [[ "$base_compose_name" == *"-${known_env}" ]]; then
            base_compose_name="${base_compose_name%-${known_env}}"
            break
        fi
    done

    export COMPOSE_PROJECT_NAME="${base_compose_name}-${env}"
}

# Obtenir le nom du conteneur
get_container_prefix() {
    local env=$1
    local prefix="${PROJECT_NAME:-${COMPOSE_PROJECT_NAME}}"

    if [ -z "$prefix" ]; then
        prefix="app"
    fi

    # Si PROJECT_NAME n'est pas défini, COMPOSE_PROJECT_NAME peut inclure "-$env"
    if [ -z "$PROJECT_NAME" ] && [ -n "$COMPOSE_PROJECT_NAME" ] && [[ "$COMPOSE_PROJECT_NAME" == *"-${env}" ]]; then
        prefix="${COMPOSE_PROJECT_NAME%-${env}}"
    fi

    echo "$prefix"
}

get_container_candidates() {
    local env=$1
    local service=$2
    local prefix
    prefix="$(get_container_prefix "$env")"

    # Convention stricte: ${prefix}-${service}-${env}
    echo "${prefix}-${service}-${env}"
}

get_container_bad_name() {
    local env=$1
    local service=$2
    local prefix
    prefix="$(get_container_prefix "$env")"

    # Convention incorrecte: ${prefix}-${env}-${service}
    echo "${prefix}-${env}-${service}"
}

get_container_name() {
    local env=$1
    local service=$2
    local candidates
    candidates="$(get_container_candidates "$env" "$service")"

    for container in $candidates; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "$container"
            return 0
        fi
    done

    # Fallback: première convention
    echo "${candidates%% *}"
}

# Vérifier si un conteneur est en cours d'exécution
is_container_running() {
    local container=$1
    docker ps --format '{{.Names}}' | grep -q "^${container}$"
}

# Confirmation pour les actions critiques
confirm_action() {
    local message=$1
    local env=$2

    if [ "$env" == "prod" ]; then
        log_warn "$message"
        read -p "Êtes-vous ABSOLUMENT sûr ? Tapez 'yes' pour confirmer: " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Action annulée"
            exit 0
        fi
    else
        read -p "$message (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Action annulée"
            exit 0
        fi
    fi
}

# Déterminer les services à build en ne gardant qu'un service par image.
# Évite les conflits "image already exists" quand plusieurs services partagent la même image.
get_compose_build_targets_by_unique_image() {
    local env=$1
    local workdir=${2:-$(pwd)}

    (
        cd "$workdir" && docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" config 2>/dev/null
    ) | awk '
        function flush_service() {
            if (current_service != "" && has_build == 1) {
                key = (current_image != "" ? current_image : "__NO_IMAGE__:" current_service)
                if (!(key in seen)) {
                    seen[key] = 1
                    out[++count] = current_service
                }
            }
        }

        /^services:[[:space:]]*$/ {
            in_services = 1
            next
        }

        in_services && /^[^[:space:]]/ {
            flush_service()
            in_services = 0
        }

        in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            flush_service()
            current_service = $1
            sub(/:$/, "", current_service)
            has_build = 0
            current_image = ""
            next
        }

        in_services && /^    build:[[:space:]]*$/ {
            has_build = 1
            next
        }

        in_services && /^    image:[[:space:]]*/ {
            current_image = $2
            gsub(/["'\'']/, "", current_image)
            next
        }

        END {
            flush_service()
            for (i = 1; i <= count; i++) {
                print out[i]
            }
        }
    '
}

# Build docker compose en série avec déduplication des images cibles.
run_compose_build() {
    local env=$1
    local no_cache=${2:-false}
    local workdir=${3:-$(pwd)}
    local -a build_targets=()
    local -a compose_cmd=(docker compose --parallel 1 -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" build)

    if [ "$no_cache" == "true" ]; then
        compose_cmd+=("--no-cache")
    fi

    while IFS= read -r service; do
        [ -n "$service" ] && build_targets+=("$service")
    done < <(get_compose_build_targets_by_unique_image "$env" "$workdir" || true)

    if [ ${#build_targets[@]} -gt 0 ]; then
        log_info "Build des services (images uniques): ${build_targets[*]}"
        compose_cmd+=("${build_targets[@]}")
    else
        log_warn "Impossible de déterminer les services à build, fallback sur tous les services"
    fi

    (cd "$workdir" && "${compose_cmd[@]}")
}

# Lister les services déclarés dans docker-compose pour un environnement.
get_compose_services() {
    local env=$1
    local workdir=${2:-$(pwd)}

    (
        cd "$workdir" && docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" config 2>/dev/null
    ) | awk '
        /^services:[[:space:]]*$/ {
            in_services = 1
            next
        }

        in_services && /^[^[:space:]]/ {
            in_services = 0
        }

        in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            service = $1
            sub(/:$/, "", service)
            print service
        }
    '
}

# Détecter le type de stack à partir des services réellement déclarés.
detect_stack_type_for_env() {
    local env=$1
    local workdir=${2:-$(pwd)}
    local services

    # N'honorer STACK_TYPE d'emblée que s'il a été défini explicitement
    # (.devops.yml ou variable d'environnement). Une valeur par défaut posée par
    # config-loader (STACK_TYPE_EXPLICIT=0) ne doit pas court-circuiter
    # l'auto-détection ci-dessous — sinon un projet Kafka sans stack_type serait
    # traité comme « fastapi-redis » (health check HTTP voué à l'échec).
    # Défaut à 1 si le marqueur est absent : préserve l'ancien comportement.
    if [ "${STACK_TYPE_EXPLICIT:-1}" = "1" ]; then
        case "${STACK_TYPE:-}" in
            orchestrator|monitoring|reporting-superset|streaming-kafka|fastapi-redis|fastapi-postgres-redis)
                echo "$STACK_TYPE"
                return 0
                ;;
        esac
    fi

    services="$(get_compose_services "$env" "$workdir" 2>/dev/null | tr '\n' ' ')"

    if echo "$services" | grep -Eq '(^| )prometheus( |$)|(^| )grafana( |$)'; then
        echo "monitoring"
        return 0
    fi

    if echo "$services" | grep -Eq '(^| )superset( |$)|(^| )superset-worker( |$)|(^| )superset-beat( |$)'; then
        echo "reporting-superset"
        return 0
    fi

    if echo "$services" | grep -Eq '(^| )(dim_consumer|fact_consumer)( |$)'; then
        echo "streaming-kafka"
        return 0
    fi

    if echo "$services" | grep -Eq '(^| )(airflow-webserver|airflow-scheduler|airflow-worker|airflow-triggerer|scheduler|triggerer|dag-processor)( |$)'; then
        echo "orchestrator"
        return 0
    fi

    if echo "$services" | grep -Eq '(^| )api( |$)'; then
        if echo "$services" | grep -Eq '(^| )postgres( |$)'; then
            echo "fastapi-postgres-redis"
        else
            echo "fastapi-redis"
        fi
        return 0
    fi

    # Si STACK_TYPE est explicitement défini, le respecter plutôt que de forcer fastapi-redis
    if [ -n "${STACK_TYPE:-}" ]; then
        echo "$STACK_TYPE"
    else
        echo "fastapi-redis"
    fi
}

# ============================================================================
# COMMANDES PRINCIPALES
# ============================================================================

# Arrêter/supprimer un projet Compose en forçant les restes si nécessaire
stop_or_remove_project_containers() {
    local env=$1
    local mode=${2:-stop}

    case "$mode" in
        stop)
            docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" stop 2>/dev/null || true
            ;;
        down)
            docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" down --remove-orphans 2>/dev/null || true
            ;;
        down-volumes)
            docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" down -v --remove-orphans 2>/dev/null || true
            ;;
        *)
            log_error "Mode d'arrêt invalide: $mode"
            return 1
            ;;
    esac

    local running_ids
    running_ids=$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}")
    if [ -n "$running_ids" ]; then
        if [ "$mode" == "stop" ]; then
            log_warn "Arrêt forcé des conteneurs encore actifs..."
            docker stop $running_ids >/dev/null 2>&1 || true
        else
            log_warn "Suppression forcée des conteneurs encore présents..."
            docker rm -f $running_ids >/dev/null 2>&1 || true
        fi
    fi

    if [ "$mode" == "down-volumes" ]; then
        local volume_ids
        volume_ids=$(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}")
        if [ -n "$volume_ids" ]; then
            log_warn "Suppression des volumes du projet ${COMPOSE_PROJECT_NAME}..."
            docker volume rm $volume_ids >/dev/null 2>&1 || true
        fi
    fi
}

# Déployer un environnement
cmd_deploy() {
    local env=$1
    local no_cache=${2:-false}
    local use_git=${3:-false}
    local from_registry=${4:-false}
    local registry_version=${5:-latest}
    local custom_branch=${6:-}
    local use_local=${7:-false}
    local use_reload=${8:-auto}
    local supports_fastapi_reload=false

    validate_env "$env"
    load_env "$env"

    # Déterminer la branche cible si elle n'est pas explicitement fournie
    if [ -z "${GIT_BRANCH:-}" ]; then
        case "$env" in
            dev)
                GIT_BRANCH="${BRANCH:-${DEV_BRANCH:-dev}}"
                ;;
            staging)
                GIT_BRANCH="${BRANCH:-${STAGING_BRANCH:-staging}}"
                ;;
            prod)
                GIT_BRANCH="${BRANCH:-${PROD_BRANCH:-main}}"
                ;;
            *)
                GIT_BRANCH="${BRANCH:-${DEV_BRANCH:-dev}}"
                ;;
        esac
    fi

    # Override GIT_BRANCH si une branche custom est spécifiée
    if [ -n "$custom_branch" ]; then
        log_info "Utilisation de la branche personnalisée: $custom_branch"
        GIT_BRANCH="$custom_branch"
    fi

    log_header "DÉPLOIEMENT - Environnement: $env"
    set_compose_project_name_for_env "$env"

    # DEV: activer le hot-reload uniquement pour les stacks FastAPI
    if [ "$env" == "dev" ]; then
        # Exclure d'abord les stacks non-FastAPI connues — avant toute lecture des services compose
        case "${STACK_TYPE:-}" in
            orchestrator|monitoring|reporting-superset|streaming-kafka)
                : # supports_fastapi_reload reste false
                ;;
            *)
                local services_list
                services_list="$(get_compose_services "$env" "$(pwd)" 2>/dev/null | tr '\n' ' ')"
                if echo "$services_list" | grep -Eq '(^| )api( |$)'; then
                    supports_fastapi_reload=true
                elif [[ "${STACK_TYPE:-}" == fastapi-* ]]; then
                    supports_fastapi_reload=true
                fi
                ;;
        esac

        if [ "$supports_fastapi_reload" == "true" ]; then
            local resolved_reload="$use_reload"

            if [ "$resolved_reload" == "auto" ]; then
                if [ "$use_local" == "true" ] && [ -t 0 ]; then
                    read -p "Activer le mode hot-reload FastAPI en DEV ? (Y/n): " reload_choice
                    case "$reload_choice" in
                        n|N|no|NO)
                            resolved_reload="false"
                            ;;
                        *)
                            resolved_reload="true"
                            ;;
                    esac
                else
                    # Valeur par défaut pour les usages non-interactifs
                    resolved_reload="true"
                fi
            fi

            if [ "$resolved_reload" != "true" ] && [ "$resolved_reload" != "false" ]; then
                log_error "Valeur invalide pour le mode reload: $resolved_reload (attendu: true/false/auto)"
                exit 1
            fi

            export FASTAPI_HOT_RELOAD="$resolved_reload"
        else
            # Stack non-FastAPI: ne pas poser la question, ignorer les flags reload
            if [ "$use_reload" != "auto" ]; then
                log_warn "Option --reload/--no-reload ignorée: stack non-FastAPI détectée en DEV"
            fi
            unset FASTAPI_HOT_RELOAD
        fi
    fi

    # Confirmation pour la production
    if [ "$env" == "prod" ]; then
        confirm_action "Vous êtes sur le point de déployer en PRODUCTION" "$env"
    fi

    # Méthode de déploiement
    if [ "$use_local" == "true" ]; then
        log_info "Mode: Build depuis fichiers locaux (répertoire actuel)"
        log_warn "📁 Déploiement depuis les fichiers locaux actuels"
        log_info "Répertoire: $(pwd)"
        log_info "Branche Git actuelle: $(git branch --show-current 2>/dev/null || echo 'inconnue')"
        if [ "$env" == "dev" ] && [ "$supports_fastapi_reload" == "true" ] && [ "${FASTAPI_HOT_RELOAD:-true}" == "true" ]; then
            log_info "Mode hot-reload DEV actif: changements rechargés automatiquement sans redéploiement"
        elif [ "$env" == "dev" ] && [ "$supports_fastapi_reload" == "true" ]; then
            log_warn "Mode hot-reload DEV désactivé: un restart/redeploy sera nécessaire après changement de code"
        fi

        log_info "Construction de l'image depuis les fichiers locaux..."
        run_compose_build "$env" "$no_cache" "$(pwd)"

    elif [ "$from_registry" == "true" ]; then
        log_info "Mode: Pull depuis le registry Docker"
        log_info "Version: $registry_version"

        # Appeler le script registry pour pull
        if [ -f "$SCRIPT_DIR/registry.sh" ]; then
            bash "$SCRIPT_DIR/registry.sh" pull "$env" "$registry_version"
        else
            log_error "Script registry.sh introuvable"
            exit 1
        fi
    else
        # Build local
        if [ "$use_git" == "true" ]; then
            log_info "Mode: Build avec clone Git (branche: $GIT_BRANCH)"

            # Vérifier que le Dockerfile .git existe
            local dockerfile="deployment/docker/Dockerfile.${env}.git"
            if [ ! -f "$dockerfile" ]; then
                log_error "Dockerfile $dockerfile introuvable"
                exit 1
            fi

            # Utiliser docker build directement (pas docker compose)
            # car on veut utiliser un Dockerfile différent
            local build_args_list=()
            if [ "$no_cache" == "true" ]; then
                build_args_list+=("--no-cache")
            fi

            # Ajouter les build args pour Git
            build_args_list+=("--build-arg" "GIT_BRANCH=$GIT_BRANCH")
            build_args_list+=("--build-arg" "BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
            build_args_list+=("--build-arg" "VCS_REF=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')")

            if [ -n "$GITHUB_TOKEN" ]; then
                build_args_list+=("--build-arg" "GITHUB_TOKEN=$GITHUB_TOKEN")
            fi

            # Nom de l'image selon l'environnement
            local image_name="${PROJECT_NAME}-${env}:latest"

            log_info "Construction de l'image avec clone Git..."
            docker build \
                -f "$dockerfile" \
                -t "$image_name" \
                "${build_args_list[@]}" \
                .

        else
            log_info "Mode: Build local avec clone temporaire"
            log_info "Branche à déployer: $GIT_BRANCH"

            # Créer un dossier temporaire pour le clone
            local temp_dir="/tmp/${PROJECT_NAME}-deploy-$(date +%s)"
            log_info "Clonage temporaire dans: $temp_dir"

            # Obtenir l'URL du repo et la convertir en HTTPS si SSH
            local git_remote=$(git config --get remote.origin.url)

            # Convertir SSH en HTTPS
            if [[ "$git_remote" =~ ^git@github\.com.*:(.*)\.git$ ]]; then
                local repo_path="${BASH_REMATCH[1]}"
                git_remote="https://github.com/${repo_path}.git"
                log_info "URL convertie en HTTPS: $git_remote"

                # Utiliser le token si disponible
                if [ -n "$GITHUB_TOKEN" ]; then
                    git_remote="https://oauth2:${GITHUB_TOKEN}@github.com/${repo_path}.git"
                    log_info "Utilisation du token GitHub pour l'authentification"
                fi
            elif [[ "$git_remote" =~ ^git@github\.com-.*:(.*)\.git$ ]]; then
                # Cas spécial pour git@github.com-jeff:
                local repo_path=$(echo "$git_remote" | sed -E 's/^git@github\.com-[^:]+:(.*)\.git$/\1/')
                git_remote="https://github.com/${repo_path}.git"
                log_info "URL convertie en HTTPS: $git_remote"

                # Utiliser le token si disponible
                if [ -n "$GITHUB_TOKEN" ]; then
                    git_remote="https://oauth2:${GITHUB_TOKEN}@github.com/${repo_path}.git"
                    log_info "Utilisation du token GitHub pour l'authentification"
                fi
            fi

            # Clone de la branche spécifique
            log_info "Clonage de $git_remote..."
            if git clone --branch "$GIT_BRANCH" --depth 1 "$git_remote" "$temp_dir"; then
                log_success "Branche $GIT_BRANCH clonée avec succès"
            else
                log_error "Échec du clonage de la branche $GIT_BRANCH"
                log_error "Si le repo est privé, ajoutez GITHUB_TOKEN dans .env.$env"
                exit 1
            fi

            local temp_workdir="$temp_dir"
            local runtime_subdir
            runtime_subdir="$(get_runtime_subdir)"
            if [ -n "$runtime_subdir" ] && [ -d "$temp_dir/$runtime_subdir" ]; then
                temp_workdir="$temp_dir/$runtime_subdir"
            fi

            # Copier le dossier deployment du projet actuel vers la même racine
            # d'exécution dans le clone temporaire.
            log_info "Copie de la configuration de déploiement..."
            rm -rf "$temp_workdir/deployment"
            cp -r "deployment" "$temp_workdir/deployment"

            log_info "Construction de l'image depuis le clone temporaire..."
            run_compose_build "$env" "$no_cache" "$temp_workdir"

            # Nettoyer le clone temporaire
            log_info "Nettoyage du clone temporaire..."
            rm -rf "$temp_dir"
            log_success "Clone temporaire supprimé"
        fi
    fi

    # Arrêt des anciens conteneurs
    log_info "Arrêt des anciens conteneurs..."

    # Arrêter les conteneurs existants (détection via compose, fallback sur STACK_TYPE)
    local containers=()
    while IFS= read -r service; do
        [ -n "$service" ] && containers+=("$service")
    done < <(get_compose_services "$env" "$(pwd)" || true)

    if [ ${#containers[@]} -eq 0 ]; then
        case "${STACK_TYPE:-fastapi-redis}" in
            monitoring)
                containers=("prometheus" "grafana" "cadvisor" "node-exporter" "postgres" "postgres-exporter")
                ;;
            reporting-superset)
                containers=("superset" "superset-init" "superset-worker" "superset-beat" "db" "redis")
                ;;
            fastapi-postgres-redis)
                containers=("api" "redis" "postgres")
                ;;
            streaming-kafka)
                containers=("dim_consumer" "fact_consumer" "redis")
                ;;
            orchestrator)
                containers=("airflow-webserver" "airflow-scheduler" "airflow-worker" "airflow-triggerer" "postgres" "redis")
                ;;
            *)
                containers=("api" "redis")
                ;;
        esac
    fi

    # Refuser la convention ${prefix}-${env}-${service}
    local bad_containers=()
    for service in "${containers[@]}"; do
        local bad_name
        bad_name="$(get_container_bad_name "$env" "$service")"
        if docker ps -a --format '{{.Names}}' | grep -q "^${bad_name}$"; then
            bad_containers+=("$bad_name")
        fi
    done
    if [ ${#bad_containers[@]} -gt 0 ]; then
        log_error "Convention de nommage invalide détectée: ${bad_containers[*]}"
        log_error "Attendu: $(get_container_prefix "$env")-<service>-$env"
        log_error "Corrigez les docker-compose pour utiliser PROJECT_NAME + service + env, puis supprimez ces conteneurs"
        exit 1
    fi

    for service in "${containers[@]}"; do
        local container
        container="$(get_container_candidates "$env" "$service")"
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            log_warn "Arrêt et suppression du conteneur existant: $container"
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        else
            log_warn "Aucun conteneur existant à supprimer pour le service: $service"
        fi
    done

    # Utiliser docker compose down pour nettoyer proprement
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" down 2>/dev/null || true

    # Démarrage
    log_info "Démarrage des conteneurs..."
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" up -d

    # Attendre le démarrage
    log_info "Attente du démarrage des services..."
    sleep 5

    # Health check
    cmd_health "$env"

    # Afficher les logs récents
    log_info "Derniers logs:"
    print_separator
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" logs --tail=20
    print_separator

    log_success "Déploiement terminé avec succès!"
}

# Démarrer les conteneurs
cmd_start() {
    local env=$1
    validate_env "$env"
    load_env "$env"
    set_compose_project_name_for_env "$env"

    log_header "DÉMARRAGE - Environnement: $env"
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" up -d
    log_success "Conteneurs démarrés"
    cmd_status "$env"
}

# Arrêter les conteneurs
cmd_stop() {
    local env=$1
    local mode=${2:-stop}
    validate_env "$env"
    load_env "$env"
    set_compose_project_name_for_env "$env"

    if [ "$mode" == "ask" ]; then
        local remove_containers
        local remove_volumes

        read -p "Supprimer aussi les conteneurs (docker down) ? (y/n): " remove_containers
        if [ "$remove_containers" == "y" ] || [ "$remove_containers" == "Y" ]; then
            read -p "Supprimer aussi les volumes (ATTENTION: perte de données) ? (y/n): " remove_volumes
            if [ "$remove_volumes" == "y" ] || [ "$remove_volumes" == "Y" ]; then
                mode="down-volumes"
            else
                mode="down"
            fi
        else
            mode="stop"
        fi
    fi

    if [ "$env" == "prod" ]; then
        case "$mode" in
            down-volumes)
                confirm_action "Arrêter et SUPPRIMER conteneurs + volumes de PRODUCTION ?" "$env"
                ;;
            down)
                confirm_action "Arrêter et SUPPRIMER les conteneurs de PRODUCTION ?" "$env"
                ;;
            *)
                confirm_action "Arrêter l'environnement de PRODUCTION ?" "$env"
                ;;
        esac
    fi

    log_header "ARRÊT - Environnement: $env"
    log_info "Projet Compose ciblé: ${COMPOSE_PROJECT_NAME}"

    case "$mode" in
        down-volumes)
            log_warn "Mode: suppression des conteneurs, réseaux et volumes"
            ;;
        down)
            log_info "Mode: suppression des conteneurs et réseaux"
            ;;
        *)
            log_info "Mode: arrêt simple (conteneurs conservés)"
            ;;
    esac

    stop_or_remove_project_containers "$env" "$mode"

    local still_running
    still_running=$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" --format '{{.Names}}')
    if [ -n "$still_running" ]; then
        log_warn "Des conteneurs sont encore actifs: $(echo "$still_running" | tr '\n' ' ')"
    else
        log_success "Conteneurs arrêtés"
    fi
}

# Redémarrer les conteneurs
cmd_restart() {
    local env=$1
    local service=$2
    validate_env "$env"
    load_env "$env"
    set_compose_project_name_for_env "$env"

    log_header "REDÉMARRAGE - Environnement: $env"

    if [ -n "$service" ]; then
        log_info "Redémarrage du service: $service"
        docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" restart "$service"
    else
        docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" restart
    fi

    log_success "Redémarrage terminé"
    cmd_status "$env"
}

# Afficher les logs
cmd_logs() {
    local env=$1
    local service=$2
    local lines=${3:-50}
    local follow=${4:-false}

    validate_env "$env"
    load_env "$env"
    set_compose_project_name_for_env "$env"

    log_header "LOGS - Environnement: $env"

    local log_cmd="docker compose -f deployment/docker-compose.yml -f deployment/docker-compose.$env.yml logs --tail=$lines"

    if [ "$follow" == "true" ]; then
        log_cmd="$log_cmd -f"
    fi

    if [ -n "$service" ]; then
        log_cmd="$log_cmd $service"
    fi

    eval "$log_cmd"
}

# Afficher le statut
cmd_status() {
    local env=$1

    if [ "$env" == "all" ]; then
        log_header "STATUT - Tous les environnements"
        echo ""
        echo -e "${WHITE}=== DEV ===${NC}"
        docker compose -f deployment/docker-compose.dev.yml ps
        echo ""
        echo -e "${WHITE}=== PROD ===${NC}"
        docker compose -f deployment/docker-compose.prod.yml ps
        echo ""
        echo -e "${WHITE}=== NGINX ===${NC}"
        docker ps --filter "name=${PROJECT_NAME}-nginx-proxy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        validate_env "$env"
        load_env "$env"
        set_compose_project_name_for_env "$env"
        log_header "STATUT - Environnement: $env"
        docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" ps
    fi

    echo ""
    log_info "Utilisation des ressources:"
    local prefix="${COMPOSE_PROJECT_NAME:-${PROJECT_NAME}}"
    local stats_containers
    stats_containers="$(docker ps --filter "name=${prefix}" --format "{{.Names}}" 2>/dev/null || true)"
    if [ -n "$stats_containers" ]; then
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $stats_containers
    else
        log_info "Aucun conteneur en cours pour ${prefix}"
    fi
}

# Health check
cmd_health() {
    local env=$1
    validate_env "$env"

    load_env "$env"
    local effective_stack_type
    effective_stack_type="$(detect_stack_type_for_env "$env" "$(pwd)")"
    log_info "Type de stack détecté: ${effective_stack_type}"

    # Adapter le health check selon le type de stack détecté
    case "$effective_stack_type" in
        monitoring)
            local prom_port=$(get_port_for_env "$env" "prometheus")
            local graf_port=$(get_port_for_env "$env" "grafana")

            log_info "Health check Prometheus (port $prom_port)..."
            for i in {1..10}; do
                if curl -sf "http://localhost:$prom_port/-/healthy" > /dev/null 2>&1; then
                    log_success "Prometheus operationnel sur le port $prom_port"
                    break
                else
                    if [ $i -eq 10 ]; then
                        log_error "Prometheus ne repond pas apres 10 tentatives"
                    else
                        log_warn "Tentative $i/10... (attente 3s)"
                        sleep 3
                    fi
                fi
            done

            log_info "Health check Grafana (port $graf_port)..."
            for i in {1..10}; do
                if curl -sf "http://localhost:$graf_port/api/health" > /dev/null 2>&1; then
                    log_success "Grafana operationnel sur le port $graf_port"
                    return 0
                else
                    if [ $i -eq 10 ]; then
                        log_error "Grafana ne repond pas apres 10 tentatives"
                        return 1
                    fi
                    log_warn "Tentative $i/10... (attente 3s)"
                    sleep 3
                fi
            done
            ;;
        reporting-superset)
            local superset_port=$(get_port_for_env "$env" "superset")

            log_info "Health check Superset (port $superset_port)..."
            for i in {1..15}; do
                if curl -sf "http://localhost:$superset_port/health" > /dev/null 2>&1; then
                    log_success "Superset operationnel sur le port $superset_port"
                    return 0
                else
                    if [ $i -eq 15 ]; then
                        log_error "Superset ne repond pas apres 15 tentatives"
                        return 1
                    fi
                    log_warn "Tentative $i/15... (attente 5s)"
                    sleep 5
                fi
            done
            ;;
        streaming-kafka)
            # Pour les stacks Kafka/streaming, pas d'endpoint HTTP : vérifier l'état des conteneurs Docker
            log_info "Health check des consumers Kafka (état Docker)..."
            local all_healthy=true
            local project_prefix="${PROJECT_NAME}-"

            for container in $(docker ps --filter "name=${project_prefix}" --filter "name=-${env}" --format '{{.Names}}' 2>/dev/null); do
                local status
                status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no-healthcheck")
                # Certains conteneurs sans healthcheck renvoient "<no value>" ou vide.
                # On normalise vers "no-healthcheck" pour ne pas les marquer en erreur.
                status="$(echo "$status" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -n 1)"
                if [ -z "$status" ] || [[ "$status" == *"no value"* ]]; then
                    status="no-healthcheck"
                fi
                local running
                running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")
                if [ "$running" = "true" ]; then
                    if [ "$status" = "healthy" ] || [ "$status" = "no-healthcheck" ]; then
                        log_success "Conteneur $container: en cours d'exécution ($status)"
                    else
                        log_warn "Conteneur $container: état=$status"
                        all_healthy=false
                    fi
                else
                    log_error "Conteneur $container: non démarré"
                    all_healthy=false
                fi
            done

            if [ "$all_healthy" = "true" ]; then
                log_success "Tous les consumers Kafka sont opérationnels"
                return 0
            else
                log_warn "Certains conteneurs ne sont pas dans un état sain — vérifiez avec: docker ps"
                return 1
            fi
            ;;
        orchestrator)
            local airflow_port
            case "$env" in
                staging) airflow_port="${AIRFLOW_STAGING_PORT:-${STAGING_PORT:-8081}}" ;;
                prod)    airflow_port="${AIRFLOW_PROD_PORT:-${PROD_PORT:-8082}}" ;;
                *)       airflow_port="${AIRFLOW_DEV_PORT:-${DEV_PORT:-8080}}" ;;
            esac
            local airflow_health_url="${AIRFLOW_API_HEALTHCHECK_URL:-http://localhost:$airflow_port/health}"
            local airflow_health_max_attempts="${API_HEALTH_MAX_ATTEMPTS:-20}"
            local airflow_health_sleep="${API_HEALTH_SLEEP_SECONDS:-5}"

            if [[ "$airflow_health_url" != http://* && "$airflow_health_url" != https://* ]]; then
                airflow_health_url="http://localhost:$airflow_port$airflow_health_url"
            fi

            if [[ "$airflow_health_url" =~ ^https?://(localhost|127\.0\.0\.1|api):8080(/.*)?$ ]]; then
                local health_path="${BASH_REMATCH[2]:-/health}"
                airflow_health_url="http://localhost:$airflow_port$health_path"
            fi

            log_info "Health check Airflow: $airflow_health_url"
            for i in $(seq 1 "$airflow_health_max_attempts"); do
                if curl -sf "$airflow_health_url" > /dev/null 2>&1; then
                    log_success "Airflow opérationnel: $airflow_health_url"
                    return 0
                else
                    if [ "$i" -eq "$airflow_health_max_attempts" ]; then
                        log_error "Airflow ne répond pas après $airflow_health_max_attempts tentatives"
                        return 1
                    fi
                    log_warn "Tentative $i/$airflow_health_max_attempts... (attente ${airflow_health_sleep}s)"
                    sleep "$airflow_health_sleep"
                fi
            done
            ;;
        *)
            local port=$(get_port_for_env "$env" "api")
            local healthcheck_url="${AIRFLOW_API_HEALTHCHECK_URL:-http://localhost:$port/health}"
            local api_health_max_attempts="${API_HEALTH_MAX_ATTEMPTS:-20}"
            local api_health_sleep_seconds="${API_HEALTH_SLEEP_SECONDS:-3}"

            if [[ "$healthcheck_url" != http://* && "$healthcheck_url" != https://* ]]; then
                healthcheck_url="http://localhost:$port$healthcheck_url"
            fi

            if [[ "$healthcheck_url" =~ ^https?://(localhost|127\.0\.0\.1|api):8080(/.*)?$ ]]; then
                local health_path="${BASH_REMATCH[2]:-/health}"
                healthcheck_url="http://localhost:$port$health_path"
            fi

            log_info "Health check de l'API: $healthcheck_url"
            for i in $(seq 1 "$api_health_max_attempts"); do
                if curl -sf "$healthcheck_url" > /dev/null; then
                    log_success "API operationnelle: $healthcheck_url"
                    return 0
                else
                    if [ "$i" -eq "$api_health_max_attempts" ]; then
                        log_error "L'API ne repond pas apres $api_health_max_attempts tentatives"
                        return 1
                    fi
                    log_warn "Tentative $i/$api_health_max_attempts... (attente ${api_health_sleep_seconds}s)"
                    sleep "$api_health_sleep_seconds"
                fi
            done
            ;;
    esac
}

# Accéder au shell d'un conteneur
cmd_shell() {
    local env=$1
    local service=${2:-"api"}
    validate_env "$env"

    local container=$(get_container_name "$env" "$service")

    if ! is_container_running "$container"; then
        log_error "Le conteneur $container n'est pas en cours d'exécution"
        exit 1
    fi

    log_info "Connexion au conteneur: $container"
    docker exec -it "$container" /bin/bash || docker exec -it "$container" /bin/sh
}

# Reconstruire les images
cmd_rebuild() {
    local env=$1
    local no_cache=${2:-true}
    validate_env "$env"
    load_env "$env"

    if [ "$env" == "prod" ]; then
        confirm_action "Reconstruire les images de PRODUCTION ?" "$env"
    fi

    log_header "RECONSTRUCTION - Environnement: $env"

    run_compose_build "$env" "$no_cache" "$(pwd)"
    log_success "Images reconstruites"
}

# Nettoyer les ressources Docker
cmd_clean() {
    local env=$1
    local deep=${2:-false}
    local project="${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"

    log_header "NETTOYAGE - Projet: $project"

    if [ "$env" != "all" ]; then
        validate_env "$env"
        load_env "$env"
        set_compose_project_name_for_env "$env"
        confirm_action "Nettoyer l'environnement $env du projet $project ?" "$env"

        log_info "Arrêt et suppression des conteneurs $env..."
        docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" down -v
    else
        confirm_action "Nettoyer TOUS les environnements du projet $project ?" "prod"

        log_info "Arrêt et suppression de tous les conteneurs du projet..."
        for e in dev staging prod; do
            if [ -f "deployment/docker-compose.$e.yml" ]; then
                log_info "Nettoyage environnement $e..."
                docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$e.yml" down -v 2>/dev/null || true
            fi
        done
    fi

    # Supprimer uniquement les images du projet (filtrées par label ou nom)
    log_info "Suppression des images du projet $project..."
    docker images --filter "label=project=${project}" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E "^${IMAGE_NAME:-$project}:" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null || true

    # Supprimer les volumes orphelins du projet
    log_info "Suppression des volumes orphelins du projet $project..."
    docker volume ls --filter "name=${project}" -q 2>/dev/null | xargs -r docker volume rm 2>/dev/null || true

    # Supprimer les réseaux orphelins du projet
    log_info "Suppression des réseaux orphelins du projet $project..."
    docker network ls --filter "name=${project}" -q 2>/dev/null | xargs -r docker network rm 2>/dev/null || true

    if [ "$deep" == "true" ]; then
        confirm_action "Supprimer aussi le cache de build Docker pour le projet $project ?" "prod"
        log_warn "Nettoyage du cache de build..."
        docker builder prune -f 2>/dev/null || true
    fi

    log_success "Nettoyage du projet $project terminé"
}


# Nettoyer les conteneurs avec une convention de nommage invalide
cmd_cleanup_bad_names() {
    local env=$1

    if [ -z "$env" ]; then
        log_error "Environnement requis"
        echo "Usage: ./deploy.sh cleanup-bad-names <dev|staging|prod>"
        exit 1
    fi

    validate_env "$env"
    load_env "$env"

    log_header "NETTOYAGE NOMMAGE - Environnement: $env"
    confirm_action "Supprimer les conteneurs avec un nommage invalide ?" "$env"

    local containers=()
    while IFS= read -r service; do
        [ -n "$service" ] && containers+=("$service")
    done < <(get_compose_services "$env" "$(pwd)" || true)

    if [ ${#containers[@]} -eq 0 ]; then
        case "${STACK_TYPE:-fastapi-redis}" in
            monitoring)
                containers=("prometheus" "grafana" "cadvisor" "node-exporter" "postgres" "postgres-exporter")
                ;;
            reporting-superset)
                containers=("superset" "superset-init" "superset-worker" "superset-beat" "db" "redis")
                ;;
            fastapi-postgres-redis)
                containers=("api" "redis" "postgres")
                ;;
            streaming-kafka)
                containers=("dim_consumer" "fact_consumer" "redis")
                ;;
            orchestrator)
                containers=("airflow-webserver" "airflow-scheduler" "airflow-worker" "airflow-triggerer" "postgres" "redis")
                ;;
            *)
                containers=("api" "redis")
                ;;
        esac
    fi

    local removed=false
    for service in "${containers[@]}"; do
        local bad_name
        bad_name="$(get_container_bad_name "$env" "$service")"
        if docker ps -a --format '{{.Names}}' | grep -q "^${bad_name}$"; then
            log_warn "Suppression du conteneur mal nommé: $bad_name"
            docker stop "$bad_name" 2>/dev/null || true
            docker rm "$bad_name" 2>/dev/null || true
            removed=true
        fi
    done

    if [ "$removed" = false ]; then
        log_info "Aucun conteneur avec un nommage invalide trouvé"
    else
        log_success "Nettoyage terminé"
    fi
}

# Backup Redis
cmd_backup() {
    local env=$1
    validate_env "$env"

    local container=$(get_container_name "$env" "redis")
    local backup_dir="./backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/redis-${env}-${timestamp}.rdb"

    mkdir -p "$backup_dir"

    log_header "BACKUP REDIS - Environnement: $env"

    if ! is_container_running "$container"; then
        log_error "Le conteneur Redis $container n'est pas en cours d'exécution"
        exit 1
    fi

    log_info "Création d'un snapshot Redis..."
    docker exec "$container" redis-cli SAVE

    log_info "Copie du fichier de sauvegarde..."
    docker cp "$container:/data/dump.rdb" "$backup_file"

    log_success "Backup créé: $backup_file"
    ls -lh "$backup_file"
}

# Restaurer Redis
cmd_restore() {
    local env=$1
    local backup_file=$2

    validate_env "$env"
    set_compose_project_name_for_env "$env"

    if [ ! -f "$backup_file" ]; then
        log_error "Fichier de backup introuvable: $backup_file"
        exit 1
    fi

    confirm_action "Restaurer Redis depuis $backup_file ?" "$env"

    local container=$(get_container_name "$env" "redis")

    log_header "RESTAURATION REDIS - Environnement: $env"

    # Arrêter Redis
    log_info "Arrêt de Redis..."
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" stop redis

    # Copier le backup
    log_info "Copie du fichier de backup..."
    docker cp "$backup_file" "$container:/data/dump.rdb"

    # Redémarrer Redis
    log_info "Redémarrage de Redis..."
    docker compose -f "deployment/docker-compose.yml" -f "deployment/docker-compose.$env.yml" start redis

    log_success "Restauration terminée"
}

# Voir les statistiques en temps réel
cmd_stats() {
    log_header "STATISTIQUES DOCKER"
    local prefix="${COMPOSE_PROJECT_NAME:-${PROJECT_NAME}}"
    docker stats $(docker ps --filter "name=${prefix}" --format "{{.Names}}")
}

# Exécuter une commande dans un conteneur
cmd_exec() {
    local env=$1
    local service=${2:-"api"}
    shift 2
    local command="$@"

    validate_env "$env"

    local container=$(get_container_name "$env" "$service")

    if ! is_container_running "$container"; then
        log_error "Le conteneur $container n'est pas en cours d'exécution"
        exit 1
    fi

    log_info "Exécution de la commande dans $container: $command"
    docker exec -it "$container" $command
}

# Gestion Nginx
cmd_nginx() {
    local action=$1

    case "$action" in
        start)
            log_info "Démarrage de Nginx..."
            docker compose -f deployment/docker-compose.nginx.yml up -d
            log_success "Nginx démarré"
            ;;
        stop)
            log_info "Arrêt de Nginx..."
            docker compose -f deployment/docker-compose.nginx.yml down
            log_success "Nginx arrêté"
            ;;
        restart)
            log_info "Redémarrage de Nginx..."
            docker compose -f deployment/docker-compose.nginx.yml restart
            log_success "Nginx redémarré"
            ;;
        reload)
            log_info "Rechargement de la configuration Nginx..."
            docker exec ${PROJECT_NAME}-nginx-proxy nginx -s reload
            log_success "Configuration rechargée"
            ;;
        test)
            log_info "Test de la configuration Nginx..."
            docker exec ${PROJECT_NAME}-nginx-proxy nginx -t
            ;;
        logs)
            local lines=${2:-50}
            docker compose -f deployment/docker-compose.nginx.yml logs --tail="$lines" -f
            ;;
        *)
            log_error "Action Nginx invalide: $action"
            echo "Actions disponibles: start, stop, restart, reload, test, logs"
            exit 1
            ;;
    esac
}

# ============================================================================
# MENU INTERACTIF
# ============================================================================

show_interactive_menu() {
    clear
    local title="${PROJECT_NAME:-DevOps} - Docker Management System"
    local padding=$(( (55 - ${#title}) / 2 ))
    local left_pad=$(printf '%*s' $padding '')
    local right_pad=$(printf '%*s' $(( 55 - ${#title} - padding )) '')

    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${left_pad}${WHITE}${title}${NC}${right_pad}  ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${WHITE}Gestion des environnements:${NC}"
    echo "  1) Déployer DEV (fichiers locaux + hot-reload)"
    echo "  2) Déployer DEV (clone temporaire)"
    echo "  3) Déployer DEV (clone Git dans Docker)"
    echo "  4) Déployer PROD (clone temporaire)"
    echo "  5) Déployer PROD (clone Git dans Docker)"
    echo "  6) Déployer depuis Registry"
    echo "  7) Statut complet"
    echo ""
    echo -e "${WHITE}Actions rapides:${NC}"
    echo "  8) Démarrer un environnement"
    echo "  9) Arrêter un environnement"
    echo " 10) Redémarrer un environnement"
    echo " 11) Voir les logs"
    echo " 12) Accéder au shell"
    echo ""
    echo -e "${WHITE}Maintenance:${NC}"
    echo " 13) Backup Redis"
    echo " 14) Restaurer Redis"
    echo " 15) Reconstruire les images"
    echo " 16) Nettoyer Docker"
    echo ""
    echo -e "${WHITE}Nginx & Registry:${NC}"
    echo " 17) Gérer Nginx"
    echo " 18) Créer une release (Registry)"
    echo ""
    echo -e "${WHITE}Profils Registry:${NC}"
    echo " 19) Lister les profils registry"
    echo " 20) Charger un profil registry"
    echo " 21) Lister les tags disponibles"
    echo ""
    echo "  0) Quitter"
    echo ""
    read -p "Choisissez une option: " choice

    case $choice in
        1)
            # Déployer DEV (fichiers locaux)
            log_info "Déploiement DEV depuis les fichiers locaux..."
            log_warn "⚠️  Les fichiers du répertoire actuel seront utilisés (hot-reload automatique ensuite)"
            cmd_deploy "dev" false false false "latest" "" true
            ;;
        2)
            # Déployer DEV (clone temporaire)
            read -p "Branche à déployer (laisser vide pour utiliser celle du .env): " branch
            cmd_deploy "dev" false false false "latest" "$branch" false
            ;;
        3)
            # Déployer DEV (clone Git dans Docker)
            read -p "Branche à déployer (laisser vide pour utiliser celle du .env): " branch
            cmd_deploy "dev" false true false "latest" "$branch" false
            ;;
        4)
            # Déployer PROD (clone temporaire)
            read -p "Branche à déployer (laisser vide pour utiliser celle du .env): " branch
            cmd_deploy "prod" false false false "latest" "$branch" false
            ;;
        5)
            # Déployer PROD (clone Git dans Docker)
            read -p "Branche à déployer (laisser vide pour utiliser celle du .env): " branch
            cmd_deploy "prod" false true false "latest" "$branch" false
            ;;
        6)
            # Déployer depuis Registry
            log_header "DÉPLOIEMENT DEPUIS REGISTRY"

            # Vérifier qu'un profil est chargé
            if [ -z "$CURRENT_PROFILE" ]; then
                log_warn "Aucun profil registry chargé"
                echo ""
                registry_list_profiles
                echo ""
                read -p "Charger un profil? (y/n): " load_profile
                if [ "$load_profile" == "y" ]; then
                    registry_load_profile
                else
                    log_error "Un profil registry est requis"
                    read -p "Appuyez sur Entrée pour continuer..."
                    continue
                fi
            fi

            echo ""
            log_info "Profil actif: ${WHITE}${CURRENT_PROFILE}${NC}"
            log_info "Registry: ${REGISTRY_URL}"
            log_info "Image: ${REGISTRY_USERNAME}/${IMAGE_NAME}"
            echo ""

            # Sélection de l'environnement
            echo -e "${CYAN}Environnements disponibles:${NC}"
            echo "  1) dev     - Environnement de développement"
            echo "  2) staging - Environnement de pré-production"
            echo "  3) prod    - Environnement de production"
            echo ""
            read -p "Choisissez l'environnement (1=dev, 2=staging, 3=prod): " env_choice

            case "$env_choice" in
                1) env="dev" ;;
                2) env="staging" ;;
                3) env="prod" ;;
                *)
                    log_error "Choix invalide"
                    read -p "Appuyez sur Entrée pour continuer..."
                    continue
                    ;;
            esac

            echo ""

            # Récupérer les tags disponibles
            local repository
            repository=$(get_registry_repository)
            local api_url="https://hub.docker.com/v2/repositories/${repository}/tags?page_size=100"
            local response
            response=$(curl -s "$api_url")
            local tags
            tags=$(DOCKERHUB_RESPONSE="$response" python3 - "$env" <<'PY'
import json
import os
import sys
from datetime import datetime

env = sys.argv[1]
try:
    data = json.loads(os.environ.get("DOCKERHUB_RESPONSE", "{}"))
except Exception:
    sys.exit(2)
items = data.get("results", [])
out = []
for it in items:
    name = it.get("name", "")
    if not name.startswith(env + "-"):
        continue
    last = it.get("last_updated") or it.get("tag_last_pushed") or ""
    if last:
        try:
            dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
            last = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
        except Exception:
            pass
    if not last:
        last = "date inconnue"
    out.append((name, last))

out.sort(key=lambda x: x[0], reverse=True)
for name, last in out:
    print(f"{name}|{last}")
PY
)
            local parse_status=$?
            if [ $parse_status -ne 0 ]; then
                log_warn "Réponse Docker Hub invalide"
                version="${env}-latest"
            fi

            if [ -z "$tags" ]; then
                log_warn "Aucun tag trouvé, utilisation de ${env}-latest"
                version="${env}-latest"
            else
                echo -e "${CYAN}Tags disponibles pour ${WHITE}$env${NC}:\n"

                # Afficher les tags avec numérotation
                local tags_array=()
                local count=1
                while IFS='|' read -r tag tag_date; do
                    tags_array+=("$tag")
                    if [[ "$tag" == *"-latest" ]]; then
                        echo -e "  ${GREEN}$count)${NC} ${WHITE}$tag${NC} ${CYAN}(recommandé)${NC} - $tag_date"
                    elif [[ "$tag" =~ -v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo -e "  ${GREEN}$count)${NC} ${CYAN}$tag${NC} - $tag_date"
                    else
                        echo -e "  ${GREEN}$count)${NC} $tag - $tag_date"
                    fi
                    ((count++))
                done <<< "$tags"

                echo ""
                read -p "Choisissez un tag (1-${#tags_array[@]}) ou Entrée pour ${env}-latest: " tag_choice

                # Si vide, utiliser latest
                if [ -z "$tag_choice" ]; then
                    version="${env}-latest"
                # Si c'est un numéro
                elif [[ "$tag_choice" =~ ^[0-9]+$ ]]; then
                    if [ "$tag_choice" -ge 1 ] && [ "$tag_choice" -le "${#tags_array[@]}" ]; then
                        version="${tags_array[$((tag_choice-1))]}"
                    else
                        log_error "Numéro invalide"
                        read -p "Appuyez sur Entrée pour continuer..."
                        continue
                    fi
                # Sinon c'est un nom de tag
                else
                    version="$tag_choice"
                fi
            fi

            # Construire le nom complet de l'image
            image_full=$(build_registry_image_name "$env" "$version")

            if [ -z "$image_full" ]; then
                log_error "Impossible de construire le nom de l'image"
                read -p "Appuyez sur Entrée pour continuer..."
                continue
            fi

            echo ""
            log_info "Image à déployer: ${WHITE}${image_full}${NC}"
            echo ""
            read -p "Confirmer le déploiement? (yes/n): " confirm

            if [ "$confirm" != "yes" ]; then
                log_info "Déploiement annulé"
                read -p "Appuyez sur Entrée pour continuer..."
                continue
            fi

            # Déployer avec docker compose registry
            export ENVIRONMENT=$env
            export IMAGE_TAG=$version
            export IMAGE_FULL=$image_full
            export COMPOSE_PROJECT_NAME="${PROJECT_NAME:-akiliya-vision-core-backend}-${env}"

            cd deployment

            log_info "Arrêt des conteneurs existants..."
            docker compose -f docker-compose.registry.yml -f docker-compose.${env}-registry.yml down || true

            # Version déjà présente localement : pas de nouveau pull (tag "latest" re-vérifié)
            bash "$SCRIPT_DIR/images.sh" ensure "$image_full"

            log_info "Démarrage des services..."
            docker compose -f docker-compose.registry.yml -f docker-compose.${env}-registry.yml up -d

            cd ..

            sleep 2
            log_success "Déploiement terminé!"
            echo ""
            docker compose -f deployment/docker-compose.registry.yml -f deployment/docker-compose.${env}-registry.yml ps

            echo ""
            read -p "Appuyez sur Entrée pour continuer..."
            ;;
        7)
            cmd_status "all"
            ;;
        8)
            read -p "Environnement (dev/prod): " env
            cmd_start "$env"
            ;;
        9)
            read -p "Environnement (dev/prod): " env
            cmd_stop "$env" "ask"
            ;;
        10)
            read -p "Environnement (dev/prod): " env
            cmd_restart "$env"
            ;;
        11)
            read -p "Environnement (dev/prod): " env
            read -p "Suivre les logs en temps réel ? (y/n): " follow
            if [ "$follow" == "y" ]; then
                cmd_logs "$env" "" 50 "true"
            else
                cmd_logs "$env" "" 100 "false"
            fi
            ;;
        12)
            read -p "Environnement (dev/prod): " env
            cmd_shell "$env"
            ;;
        13)
            read -p "Environnement (dev/prod): " env
            cmd_backup "$env"
            ;;
        14)
            read -p "Environnement (dev/prod): " env
            read -p "Chemin du fichier de backup: " backup_file
            cmd_restore "$env" "$backup_file"
            ;;
        15)
            read -p "Environnement (dev/prod): " env
            cmd_rebuild "$env"
            ;;
        16)
            read -p "Environnement (dev/prod/all): " env
            read -p "Nettoyage profond ? (y/n): " deep
            cmd_clean "$env" $([ "$deep" == "y" ] && echo "true" || echo "false")
            ;;
        17)
            read -p "Action (start/stop/restart/reload/test/logs): " action
            cmd_nginx "$action"
            ;;
        18)
            # Créer une release (Registry)
            read -p "Environnement (dev/prod): " env
            read -p "Version (laisser vide pour génération auto): " version
            if [ -f "$SCRIPT_DIR/registry.sh" ]; then
                if [ -n "$version" ]; then
                    bash "$SCRIPT_DIR/registry.sh" release "$env" "$version"
                else
                    bash "$SCRIPT_DIR/registry.sh" release "$env"
                fi
            else
                log_error "Script registry.sh introuvable"
            fi
            ;;
        19)
            # Lister les profils registry
            registry_list_profiles
            echo ""
            read -p "Appuyez sur Entrée pour continuer..."
            ;;
        20)
            # Charger un profil registry
            registry_load_profile
            echo ""
            read -p "Appuyez sur Entrée pour continuer..."
            ;;
        21)
            # Lister les tags disponibles
            if [ -z "$CURRENT_PROFILE" ]; then
                log_error "Aucun profil registry chargé"
                echo ""
                read -p "Charger un profil? (y/n): " load_profile
                if [ "$load_profile" == "y" ]; then
                    registry_load_profile
                else
                    echo ""
                    read -p "Appuyez sur Entrée pour continuer..."
                    continue
                fi
            fi

            echo ""
            echo -e "${CYAN}Environnements:${NC}"
            echo "  1) dev"
            echo "  2) prod"
            echo ""
            read -p "Choisissez l'environnement (1-2): " env_choice

            case "$env_choice" in
                1) env="dev" ;;
                2) env="prod" ;;
                *)
                    log_error "Choix invalide"
                    echo ""
                    read -p "Appuyez sur Entrée pour continuer..."
                    continue
                    ;;
            esac

            echo ""
            registry_list_tags "$env"
            echo ""
            read -p "Appuyez sur Entrée pour continuer..."
            ;;
        0)
            log_info "Au revoir!"
            exit 0
            ;;
        *)
            log_error "Option invalide"
            ;;
    esac

    echo ""
    read -p "Appuyez sur Entrée pour continuer..."
    show_interactive_menu
}

# ============================================================================
# AIDE
# ============================================================================

show_help() {
    echo -e "${WHITE}${PROJECT_NAME:-DevOps} - Docker Management CLI${NC}"
    echo ""
    echo -e "${CYAN}USAGE:${NC}"
    echo "    ./deploy.sh <command> [arguments] [options]"
    echo "    ./deploy.sh                              # Mode interactif"
    echo ""
    echo -e "${CYAN}COMMANDES:${NC}"
    echo ""
    echo -e "${WHITE}Déploiement:${NC}"
    echo "    deploy <env>                   Déployer un environnement (dev/prod)"
    echo "        --no-cache                 Construire sans cache"
    echo "        --use-local                Build depuis fichiers locaux (sans clone, hot-reload en dev)"
    echo "        --use-git                  Clone depuis Git dans le build"
    echo "        --reload                   Forcer le hot-reload en dev (stack FastAPI uniquement)"
    echo "        --no-reload                Désactiver le hot-reload en dev (stack FastAPI uniquement)"
    echo "        --from-registry [version]  Pull depuis le registry Docker"
    echo "        --branch <branch>          Déployer une branche spécifique"
    echo "        (Par défaut: clone temporaire de la branche depuis .env)"
    echo ""
    echo -e "${WHITE}Gestion des conteneurs:${NC}"
    echo "    start <env>                    Démarrer les conteneurs"
    echo "    stop <env> [options]           Arrêter les conteneurs"
    echo "        --remove, --down           Supprimer aussi les conteneurs/réseaux"
    echo "        --remove-volumes, -v       Supprimer aussi les volumes"
    echo "        --ask                      Demander le mode de suppression"
    echo "    restart <env> [service]        Redémarrer les conteneurs ou un service"
    echo "    status [env]                   Afficher le statut (env: dev/prod/all)"
    echo "    stats                          Statistiques en temps réel"
    echo "    health <env>                   Vérifier la santé de l'API"
    echo ""
    echo -e "${WHITE}Logs & Debug:${NC}"
    echo "    logs <env> [service] [lines]   Afficher les logs"
    echo "        -f, --follow               Suivre les logs en temps réel"
    echo "    shell <env> [service]          Accéder au shell (service: api/redis)"
    echo "    exec <env> <service> <cmd>     Exécuter une commande"
    echo ""
    echo -e "${WHITE}Maintenance:${NC}"
    echo "    rebuild <env>                  Reconstruire les images"
    echo "        --cache                    Utiliser le cache"
    echo "    clean <env>                    Nettoyer (env: dev/prod/all)"
    echo "    cleanup-bad-names <env>         Supprimer les conteneurs mal nommes"
    echo "        --deep                     Nettoyage profond"
    echo "    backup <env>                   Backup Redis"
    echo "    restore <env> <file>           Restaurer Redis"
    echo ""
    echo -e "${WHITE}Nginx:${NC}"
    echo "    nginx <action>                 Gérer Nginx"
    echo "        Actions: start, stop, restart, reload, test, logs"
    echo ""
    echo -e "${CYAN}EXEMPLES:${NC}"
    echo "    # Déploiement depuis fichiers locaux (rapide pour le dev + hot-reload)"
    echo "    ./deploy.sh deploy dev --use-local"
    echo ""
    echo "    # Déploiement avec clone temporaire (par défaut, branche du .env)"
    echo "    ./deploy.sh deploy dev"
    echo "    ./deploy.sh deploy prod --no-cache"
    echo ""
    echo "    # Déployer une branche spécifique (clone temporaire)"
    echo "    ./deploy.sh deploy dev --branch feature/CICBI-01-gestion-utilisateurs-api"
    echo "    ./deploy.sh deploy prod --branch release/v1.2.0"
    echo ""
    echo "    # Déploiement avec clone Git dans Docker"
    echo "    ./deploy.sh deploy dev --use-git"
    echo "    ./deploy.sh deploy prod --use-git --branch main"
    echo ""
    echo "    # Déploiement depuis le registry"
    echo "    ./deploy.sh deploy dev --from-registry"
    echo "    ./deploy.sh deploy prod --from-registry v1.2.3"
    echo ""
    echo "    # Autres commandes"
    echo "    ./deploy.sh logs dev -f"
    echo "    ./deploy.sh shell prod api"
    echo "    ./deploy.sh backup prod"
    echo "    ./deploy.sh cleanup-bad-names dev"
    echo "    ./deploy.sh nginx reload"
    echo "    ./deploy.sh status all"
    echo ""
    echo -e "${CYAN}WORKFLOWS RECOMMANDÉS:${NC}"
    echo ""
    echo -e "    ${WHITE}1. Développement rapide (fichiers locaux - NOUVEAU!):${NC}"
    echo "       # Un seul deploy, puis modifications locales rechargees automatiquement"
    echo "       # Les changements de code FastAPI ne necessitent plus de redeploiement"
    echo "       ./deploy.sh deploy dev --use-local"
    echo "       ./deploy.sh logs dev -f"
    echo ""
    echo -e "    ${WHITE}2. Développement (clone temporaire):${NC}"
    echo "       # Reste sur votre branche actuelle (ex: feature/CICBI-05)"
    echo "       # Clone temporairement la branche à déployer, puis la supprime"
    echo "       ./deploy.sh deploy dev --branch feature/CICBI-01-gestion-utilisateurs-api"
    echo ""
    echo -e "    ${WHITE}3. Développement (build avec Git clone dans Docker):${NC}"
    echo "       # Clone depuis Git directement dans l'image Docker"
    echo "       ./deploy.sh deploy dev --use-git --branch develop"
    echo ""
    echo -e "    ${WHITE}4. Production (avec registry et versioning):${NC}"
    echo "       # Sur la machine de build/CI:"
    echo "       cd deployment/scripts"
    echo "       ./registry.sh release prod v1.2.3"
    echo ""
    echo "       # Sur le serveur de production:"
    echo "       ./deploy.sh deploy prod --from-registry v1.2.3"
    echo ""
    echo -e "${CYAN}ENVIRONNEMENTS:${NC}"
    echo "    dev      Environnement de développement"
    echo "    staging  Environnement de pré-production"
    echo "    prod     Environnement de production"
    echo "    all      Tous les environnements"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Vérifier les prérequis
    check_requirements

    # Si aucun argument, mode interactif
    if [ $# -eq 0 ]; then
        show_interactive_menu
        exit 0
    fi

    # Parser la commande
    COMMAND=$1
    shift

    case "$COMMAND" in
        deploy)
            ENV=${1:-""}
            if [ -z "$ENV" ]; then
                log_error "Environnement requis"
                echo "Usage: ./deploy.sh deploy <dev|prod> [--no-cache] [--use-local] [--use-git] [--reload|--no-reload] [--from-registry [version]] [--branch <branch>]"
                exit 1
            fi
            NO_CACHE=false
            USE_GIT=false
            FROM_REGISTRY=false
            REGISTRY_VERSION="latest"
            CUSTOM_BRANCH=""
            USE_LOCAL=false
            RELOAD_MODE="auto"
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --no-cache)
                        NO_CACHE=true
                        ;;
                    --use-local)
                        USE_LOCAL=true
                        ;;
                    --use-git)
                        USE_GIT=true
                        ;;
                    --reload)
                        RELOAD_MODE="true"
                        ;;
                    --no-reload)
                        RELOAD_MODE="false"
                        ;;
                    --from-registry)
                        FROM_REGISTRY=true
                        # Vérifier si une version est spécifiée
                        if [ $# -gt 1 ] && [[ ! "$2" =~ ^-- ]]; then
                            shift
                            REGISTRY_VERSION="$1"
                        fi
                        ;;
                    --branch)
                        if [ $# -gt 1 ]; then
                            shift
                            CUSTOM_BRANCH="$1"
                        else
                            log_error "L'option --branch nécessite un nom de branche"
                            exit 1
                        fi
                        ;;
                esac
                shift
            done
            cmd_deploy "$ENV" "$NO_CACHE" "$USE_GIT" "$FROM_REGISTRY" "$REGISTRY_VERSION" "$CUSTOM_BRANCH" "$USE_LOCAL" "$RELOAD_MODE"
            ;;
        start)
            cmd_start "${1:-}"
            ;;
        stop)
            ENV=${1:-""}
            STOP_MODE="stop"
            shift 2>/dev/null || true
            while [ $# -gt 0 ]; do
                case "$1" in
                    --remove|--down)
                        STOP_MODE="down"
                        ;;
                    --remove-volumes|-v)
                        STOP_MODE="down-volumes"
                        ;;
                    --ask)
                        STOP_MODE="ask"
                        ;;
                    *)
                        log_error "Option invalide pour stop: $1"
                        echo "Usage: ./deploy.sh stop <env> [--remove|--down] [--remove-volumes|-v] [--ask]"
                        exit 1
                        ;;
                esac
                shift
            done
            cmd_stop "$ENV" "$STOP_MODE"
            ;;
        restart)
            cmd_restart "${1:-}" "${2:-}"
            ;;
        logs)
            ENV=${1:-""}
            SERVICE=${2:-""}
            LINES=${3:-50}
            FOLLOW=false
            shift 2 2>/dev/null || shift 1 2>/dev/null || true
            while [ $# -gt 0 ]; do
                case "$1" in
                    -f|--follow) FOLLOW=true ;;
                    *) LINES=$1 ;;
                esac
                shift
            done
            cmd_logs "$ENV" "$SERVICE" "$LINES" "$FOLLOW"
            ;;
        status)
            cmd_status "${1:-all}"
            ;;
        stats)
            cmd_stats
            ;;
        health)
            cmd_health "${1:-}"
            ;;
        shell)
            cmd_shell "${1:-}" "${2:-api}"
            ;;
        exec)
            ENV=${1:-""}
            SERVICE=${2:-"api"}
            shift 2
            cmd_exec "$ENV" "$SERVICE" "$@"
            ;;
        rebuild)
            ENV=${1:-""}
            CACHE=false
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --cache) CACHE=true ;;
                esac
                shift
            done
            cmd_rebuild "$ENV" $([ "$CACHE" == "true" ] && echo "false" || echo "true")
            ;;
        clean)
            ENV=${1:-"all"}
            DEEP=false
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --deep) DEEP=true ;;
                esac
                shift
            done
            cmd_clean "$ENV" "$DEEP"
            ;;
        cleanup-bad-names)
            cmd_cleanup_bad_names "${1:-}"
            ;;
        backup)
            cmd_backup "${1:-}"
            ;;
        restore)
            cmd_restore "${1:-}" "${2:-}"
            ;;
        nginx)
            cmd_nginx "${1:-}" "${2:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Commande inconnue: $COMMAND"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Lancer le script
main "$@"
