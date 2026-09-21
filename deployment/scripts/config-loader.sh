#!/bin/bash

# ============================================================================
# Configuration Loader - Charge les variables depuis .devops.yml
# ============================================================================
#
# Ce script est sourcé par tous les scripts de déploiement pour charger
# dynamiquement la configuration depuis le fichier .devops.yml du projet.
#
# Usage:
#   source "$(dirname "$0")/config-loader.sh"
#   load_devops_config
#
# ============================================================================

# ============================================================================
# DÉTECTION AUTOMATIQUE DU PROJET
# ============================================================================

detect_project_root() {
    local current_dir="$1"

    # Remonter jusqu'à trouver .devops.yml ou atteindre la racine
    while [ "$current_dir" != "/" ]; do
        if [ -f "$current_dir/.devops.yml" ]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done

    # Si PROJECT_ROOT est défini (par le CLI devops), l'utiliser
    if [ -n "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/.devops.yml" ]; then
        echo "$PROJECT_ROOT"
        return 0
    fi

    return 1
}

# ============================================================================
# CHARGEMENT DE LA CONFIGURATION
# ============================================================================

load_devops_config() {
    # Déterminer le PROJECT_ROOT
    if [ -z "$PROJECT_ROOT" ]; then
        # Essayer de détecter automatiquement
        PROJECT_ROOT=$(detect_project_root "$(pwd)")

        if [ -z "$PROJECT_ROOT" ]; then
            # Échec de détection, utiliser le répertoire courant
            PROJECT_ROOT="$(pwd)"
        fi
    fi

    export PROJECT_ROOT

    local config_file="$PROJECT_ROOT/.devops.yml"

    # Vérifier si le fichier existe
    if [ ! -f "$config_file" ]; then
        # Mode legacy : ne pas échouer, utiliser les valeurs par défaut
        log_warn "Fichier .devops.yml non trouvé, utilisation des valeurs par défaut" 2>/dev/null || \
            echo "[WARN] Fichier .devops.yml non trouvé, utilisation des valeurs par défaut" >&2
        return 1
    fi

    # Parser "flat" : uniquement les clés top-level "key: value".
    # Les sous-clés YAML imbriquées sont traitées plus bas par get_nested_yaml_value.
    while IFS= read -r line || [ -n "$line" ]; do
        # Ignorer commentaires, lignes vides et blocs imbriqués
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]] ]] && continue
        [[ "$line" != *:* ]] && continue

        key="${line%%:*}"
        value="${line#*:}"
        key=$(echo "$key" | xargs)

        # Nettoyer la valeur (supprimer espaces, quotes, commentaires inline)
        value=$(echo "$value" | sed 's/[[:space:]]#.*$//' | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

        # Ignorer les valeurs vides
        [[ -z "$value" ]] && continue

        # Export des variables connues
        case "$key" in
            # Informations du projet
            project_name)
                export PROJECT_NAME="$value"
                ;;
            compose_project_name)
                export COMPOSE_PROJECT_NAME="$value"
                ;;

            # Docker Registry
            registry_username)
                export REGISTRY_USERNAME="$value"
                ;;
            registry_url)
                export REGISTRY_URL="$value"
                ;;
            image_name)
                export IMAGE_NAME="$value"
                ;;
            registry_token)
                export REGISTRY_TOKEN="$value"
                ;;
            registry_type)
                export REGISTRY_TYPE="$value"
                ;;

            # Git configuration
            git_repo)
                export GIT_REPO="$value"
                ;;
            git_username)
                export GIT_USERNAME="$value"
                ;;
            github_token)
                export GITHUB_TOKEN="$value"
                ;;

            # Branches par environnement
            dev_branch)
                export DEV_BRANCH="$value"
                ;;
            staging_branch)
                export STAGING_BRANCH="$value"
                ;;
            main_branch)
                export MAIN_BRANCH="$value"
                ;;
            prod_branch)
                export PROD_BRANCH="$value"
                ;;
            feature_prefix)
                export FEATURE_PREFIX="$value"
                ;;

            # Ports
            dev_port)
                export DEV_PORT="$value"
                ;;
            staging_port)
                export STAGING_PORT="$value"
                ;;
            prod_port)
                export PROD_PORT="$value"
                ;;
            redis_dev_port)
                export REDIS_DEV_PORT="$value"
                ;;
            redis_staging_port)
                export REDIS_STAGING_PORT="$value"
                ;;
            redis_prod_port)
                export REDIS_PROD_PORT="$value"
                ;;

            # PostgreSQL (si présent)
            postgres_user)
                export POSTGRES_USER="$value"
                ;;
            postgres_password)
                export POSTGRES_PASSWORD="$value"
                ;;
            postgres_db)
                export POSTGRES_DB="$value"
                ;;
            postgres_dev_port)
                export POSTGRES_DEV_PORT="$value"
                ;;
            postgres_staging_port)
                export POSTGRES_STAGING_PORT="$value"
                ;;
            postgres_prod_port)
                export POSTGRES_PROD_PORT="$value"
                ;;

            # Superset ports (si présent)
            superset_dev_port)
                export SUPERSET_DEV_PORT="$value"
                ;;
            superset_staging_port)
                export SUPERSET_STAGING_PORT="$value"
                ;;
            superset_prod_port)
                export SUPERSET_PROD_PORT="$value"
                ;;

            # Type de stack
            stack_type)
                export STACK_TYPE="$value"
                ;;

            # Structure du projet
            deployment_dir)
                export DEPLOYMENT_DIR="$value"
                ;;
            dockerfile_dir)
                export DOCKERFILE_DIR="$value"
                ;;
            runtime_root|project_runtime_root|app_root)
                export PROJECT_RUNTIME_ROOT="$value"
                ;;

            # Configuration application (FastAPI/Python)
            app_source_dir)
                export APP_SOURCE_DIR="$value"
                ;;
            app_dest_dir)
                export APP_DEST_DIR="$value"
                ;;
            requirements_path)
                export REQUIREMENTS_PATH="$value"
                ;;
            app_entrypoint)
                export APP_ENTRYPOINT="$value"
                ;;
            app_python_path)
                export APP_PYTHON_PATH="$value"
                ;;
            workdir)
                export WORKDIR="$value"
                ;;

            # SSH (pour create-deployment-package.sh)
            ssh_host)
                export SSH_HOST="$value"
                ;;
            ssh_user)
                export SSH_USER="$value"
                ;;
            ssh_port)
                export SSH_PORT="$value"
                ;;
            ssh_path)
                export SSH_PATH="$value"
                ;;
            ssh_identity_file)
                export SSH_IDENTITY_FILE="$value"
                ;;

            # Clé de chiffrement des .env (stockée dans .devops.yml pour backup)
            env_encryption_key)
                export ENV_ENCRYPTION_KEY="$value"
                ;;

            # Ignorer les sections et sous-clés YAML
            compose_files|compose_files_registry)
                # Ces sections seront traitées séparément si nécessaire
                ;;

            *)
                # Variables personnalisées : les exporter automatiquement
                # Convertir en MAJUSCULES avec underscores
                local var_name=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                export "$var_name=$value"
                ;;
        esac
    done < "$config_file"

    # Support du format YAML imbriqué (ex: project.name, registry.username)
    # utilisé par les projets récents.
    get_nested_yaml_value() {
        local section="$1"
        local nested_key="$2"
        local file="$3"

        awk -v section="$section" -v nested_key="$nested_key" '
            function trim(s) {
                gsub(/^[ \t]+|[ \t]+$/, "", s)
                return s
            }
            BEGIN { in_section=0 }
            $0 ~ "^[[:space:]]*" section ":[[:space:]]*$" { in_section=1; next }
            in_section && $0 ~ "^[^[:space:]]" { in_section=0 }
            in_section && $0 ~ "^[[:space:]]+" nested_key ":[[:space:]]*" {
                line=$0
                sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
                sub(/[[:space:]]+#.*$/, "", line)
                line=trim(line)
                gsub(/^"|"$/, "", line)
                gsub(/^'\''|'\''$/, "", line)
                print line
                exit
            }
        ' "$file"
    }

    local nested_value=""

    nested_value=$(get_nested_yaml_value "project" "name" "$config_file")
    [ -n "$nested_value" ] && { PROJECT_NAME="$nested_value"; export PROJECT_NAME; }

    nested_value=$(get_nested_yaml_value "project" "label_namespace" "$config_file")
    [ -n "$nested_value" ] && { LABEL_NAMESPACE="$nested_value"; export LABEL_NAMESPACE; }

    nested_value=$(get_nested_yaml_value "registry" "url" "$config_file")
    [ -n "$nested_value" ] && { REGISTRY_URL="$nested_value"; export REGISTRY_URL; }

    nested_value=$(get_nested_yaml_value "registry" "username" "$config_file")
    if [ -z "$nested_value" ]; then
        nested_value=$(get_nested_yaml_value "registry" "registry_username" "$config_file")
    fi
    [ -n "$nested_value" ] && { REGISTRY_USERNAME="$nested_value"; export REGISTRY_USERNAME; }

    nested_value=$(get_nested_yaml_value "registry" "image" "$config_file")
    if [ -z "$nested_value" ]; then
        nested_value=$(get_nested_yaml_value "registry" "image_name" "$config_file")
    fi
    [ -n "$nested_value" ] && { IMAGE_NAME="$nested_value"; export IMAGE_NAME; }

    nested_value=$(get_nested_yaml_value "registry" "type" "$config_file")
    [ -n "$nested_value" ] && { REGISTRY_TYPE="$nested_value"; export REGISTRY_TYPE; }

    nested_value=$(get_nested_yaml_value "registry" "registry_token" "$config_file")
    [ -n "$nested_value" ] && { REGISTRY_TOKEN="$nested_value"; export REGISTRY_TOKEN; }

    nested_value=$(get_nested_yaml_value "git" "repo" "$config_file")
    if [ -z "$nested_value" ]; then
        nested_value=$(get_nested_yaml_value "git" "git_repo" "$config_file")
    fi
    [ -n "$nested_value" ] && { GIT_REPO="$nested_value"; export GIT_REPO; }

    nested_value=$(get_nested_yaml_value "git" "github_token" "$config_file")
    [ -n "$nested_value" ] && { GITHUB_TOKEN="$nested_value"; export GITHUB_TOKEN; }

    nested_value=$(get_nested_yaml_value "git" "git_username" "$config_file")
    [ -n "$nested_value" ] && { GIT_USERNAME="$nested_value"; export GIT_USERNAME; }

    nested_value=$(get_nested_yaml_value "git" "dev_branch" "$config_file")
    [ -n "$nested_value" ] && { DEV_BRANCH="$nested_value"; export DEV_BRANCH; }

    nested_value=$(get_nested_yaml_value "git" "staging_branch" "$config_file")
    [ -n "$nested_value" ] && { STAGING_BRANCH="$nested_value"; export STAGING_BRANCH; }

    nested_value=$(get_nested_yaml_value "git" "prod_branch" "$config_file")
    [ -n "$nested_value" ] && { PROD_BRANCH="$nested_value"; export PROD_BRANCH; }

    nested_value=$(get_nested_yaml_value "server" "host" "$config_file")
    [ -n "$nested_value" ] && { SERVER_HOST="$nested_value"; export SERVER_HOST; }

    nested_value=$(get_nested_yaml_value "server" "user" "$config_file")
    [ -n "$nested_value" ] && { SERVER_USER="$nested_value"; export SERVER_USER; }

    nested_value=$(get_nested_yaml_value "server" "port" "$config_file")
    [ -n "$nested_value" ] && { SERVER_PORT="$nested_value"; export SERVER_PORT; }

    nested_value=$(get_nested_yaml_value "server" "ssh_key" "$config_file")
    [ -n "$nested_value" ] && { SERVER_SSH_KEY="$nested_value"; export SERVER_SSH_KEY; }

    nested_value=$(get_nested_yaml_value "server" "deploy_path" "$config_file")
    [ -n "$nested_value" ] && { SERVER_DEPLOY_PATH="$nested_value"; export SERVER_DEPLOY_PATH; }

    # Orchestrator / Airflow (optionnel)
    nested_value=$(get_nested_yaml_value "orchestrator" "airflow_version" "$config_file")
    [ -n "$nested_value" ] && { AIRFLOW_VERSION="$nested_value"; export AIRFLOW_VERSION; }

    nested_value=$(get_nested_yaml_value "orchestrator" "airflow_base_image" "$config_file")
    [ -n "$nested_value" ] && { AIRFLOW_BASE_IMAGE="$nested_value"; export AIRFLOW_BASE_IMAGE; }

    nested_value=$(get_nested_yaml_value "orchestrator" "airflow_dags_folder_default" "$config_file")
    [ -n "$nested_value" ] && { AIRFLOW_DAGS_FOLDER_DEFAULT="$nested_value"; export AIRFLOW_DAGS_FOLDER_DEFAULT; }

    nested_value=$(get_nested_yaml_value "orchestrator" "airflow_plugins_folder_default" "$config_file")
    [ -n "$nested_value" ] && { AIRFLOW_PLUGINS_FOLDER_DEFAULT="$nested_value"; export AIRFLOW_PLUGINS_FOLDER_DEFAULT; }

    # Normaliser une URL de repo Git en format clonable HTTPS
    normalize_git_repo_url() {
        local repo="$1"
        repo=$(echo "$repo" | xargs)
        [ -z "$repo" ] && { echo ""; return 0; }

        # Alias SSH courant (ex: git@github.com-cicbi:org/repo.git)
        if echo "$repo" | grep -Eq '^git@github\.com[^:]*:'; then
            echo "$repo" | sed -E 's|^git@github\.com[^:]*:|https://github.com/|'
            return 0
        fi

        # Format SSH générique
        if echo "$repo" | grep -Eq '^git@[^:]+:'; then
            echo "$repo" | sed -E 's|^git@([^:]+):|https://\1/|'
            return 0
        fi

        # Format ssh://git@host/org/repo.git
        if echo "$repo" | grep -Eq '^ssh://git@[^/]+/.+'; then
            echo "$repo" | sed -E 's|^ssh://git@([^/]+)/|https://\1/|'
            return 0
        fi

        echo "$repo"
    }

    # ========================================================================
    # DÉFINIR LES VALEURS PAR DÉFAUT
    # ========================================================================

    # Nom du projet
    export PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_ROOT")}"
    export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PROJECT_NAME}"
    export IMAGE_NAME="${IMAGE_NAME:-$PROJECT_NAME}"

    # Registry
    export REGISTRY_TYPE="${REGISTRY_TYPE:-dockerhub}"
    export REGISTRY_URL="${REGISTRY_URL:-docker.io}"
    export REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"

    # Branches
    export DEV_BRANCH="${DEV_BRANCH:-dev}"
    export STAGING_BRANCH="${STAGING_BRANCH:-staging}"
    export MAIN_BRANCH="${MAIN_BRANCH:-main}"
    export PROD_BRANCH="${PROD_BRANCH:-main}"
    export FEATURE_PREFIX="${FEATURE_PREFIX:-feature/}"

    # GIT_REPO: fallback auto depuis le remote Git local si non défini
    if [ -z "$GIT_REPO" ] && command -v git >/dev/null 2>&1; then
        GIT_REPO="$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || true)"
    fi
    GIT_REPO="$(normalize_git_repo_url "$GIT_REPO")"
    export GIT_REPO

    # Ports
    export DEV_PORT="${DEV_PORT:-8001}"
    export STAGING_PORT="${STAGING_PORT:-8002}"
    export PROD_PORT="${PROD_PORT:-8000}"
    export REDIS_DEV_PORT="${REDIS_DEV_PORT:-6379}"
    export REDIS_STAGING_PORT="${REDIS_STAGING_PORT:-6381}"
    export REDIS_PROD_PORT="${REDIS_PROD_PORT:-6380}"

    # Type de stack
    # STACK_TYPE_EXPLICIT distingue une valeur venue de .devops.yml/env (=1) d'un
    # simple repli (=0). detect_stack_type_for_env n'honore le court-circuit sur
    # STACK_TYPE que lorsqu'il est explicite : un repli ne doit pas écraser
    # l'auto-détection basée sur les services compose (ex: streaming-kafka).
    if [ -z "${STACK_TYPE:-}" ]; then
        log_warn "stack_type non défini dans .devops.yml — auto-détection via les services compose (repli: fastapi-redis)" 2>/dev/null || \
            echo "[WARN] stack_type non défini dans .devops.yml — auto-détection via les services compose (repli: fastapi-redis)" >&2
        export STACK_TYPE="fastapi-redis"
        export STACK_TYPE_EXPLICIT=0
    else
        export STACK_TYPE
        export STACK_TYPE_EXPLICIT=1
    fi

    # Structure du projet
    export DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-deployment}"
    export DOCKERFILE_DIR="${DOCKERFILE_DIR:-docker}"

    # Configuration application (FastAPI/Python)
    export APP_SOURCE_DIR="${APP_SOURCE_DIR:-app}"
    export APP_DEST_DIR="${APP_DEST_DIR:-app}"
    export REQUIREMENTS_PATH="${REQUIREMENTS_PATH:-requirements.txt}"
    export APP_ENTRYPOINT="${APP_ENTRYPOINT:-app.main:app}"
    export APP_PYTHON_PATH="${APP_PYTHON_PATH:-}"
    export WORKDIR="${WORKDIR:-/app}"

    # Orchestrator / Airflow (defaults centralisés et surchargeables via .devops.yml/.env/shell)
    export AIRFLOW_VERSION="${AIRFLOW_VERSION:-3.0.4}"
    export AIRFLOW_BASE_IMAGE="${AIRFLOW_BASE_IMAGE:-apache/airflow:${AIRFLOW_VERSION}-python3.11}"
    export AIRFLOW_DAGS_FOLDER_DEFAULT="${AIRFLOW_DAGS_FOLDER_DEFAULT:-/opt/airflow/src/airflow_src/dags}"
    export AIRFLOW_PLUGINS_FOLDER_DEFAULT="${AIRFLOW_PLUGINS_FOLDER_DEFAULT:-/opt/airflow/src/airflow_src/plugins}"

    # Racine d'exécution: certains repos gardent .devops.yml à la racine Git
    # mais placent .env.*, deployment/, dags/, plugins/, etc. sous src/.
    local configured_runtime_root="${PROJECT_RUNTIME_ROOT:-}"
    local configured_deployment_dir="${DEPLOYMENT_DIR:-deployment}"
    if [ -n "$configured_runtime_root" ]; then
        if [[ "$configured_runtime_root" = /* ]]; then
            PROJECT_RUNTIME_ROOT="$configured_runtime_root"
        else
            PROJECT_RUNTIME_ROOT="$PROJECT_ROOT/$configured_runtime_root"
        fi
    else
        PROJECT_RUNTIME_ROOT="$PROJECT_ROOT"
    fi

    if [ "$configured_deployment_dir" = "src/deployment" ] && \
       [ -f "$PROJECT_ROOT/src/deployment/docker-compose.yml" ]; then
        PROJECT_RUNTIME_ROOT="$PROJECT_ROOT/src"
        DEPLOYMENT_DIR="deployment"
    elif [ -f "$PROJECT_ROOT/src/deployment/docker-compose.yml" ] && \
         [ ! -f "$PROJECT_ROOT/$configured_deployment_dir/docker-compose.yml" ]; then
        PROJECT_RUNTIME_ROOT="$PROJECT_ROOT/src"
        DEPLOYMENT_DIR="deployment"
    fi

    export PROJECT_RUNTIME_ROOT
    export DEPLOYMENT_DIR

    # SSH
    export SSH_USER="${SSH_USER:-root}"
    export SSH_PORT="${SSH_PORT:-22}"
    export SSH_PATH="${SSH_PATH:-/srv/$PROJECT_NAME}"

    # Variables calculées
    export DEPLOYMENT_PATH="$PROJECT_RUNTIME_ROOT/$DEPLOYMENT_DIR"
    export DOCKERFILE_PATH="$DEPLOYMENT_PATH/$DOCKERFILE_DIR"

    return 0
}

# ============================================================================
# FONCTION UTILITAIRE : Obtenir la branche Git pour un environnement
# ============================================================================

get_branch_for_env() {
    local env=$1
    case "$env" in
        dev)
            echo "${DEV_BRANCH:-dev}"
            ;;
        staging)
            echo "${STAGING_BRANCH:-staging}"
            ;;
        prod)
            echo "${PROD_BRANCH:-main}"
            ;;
        *)
            echo "main"
            ;;
    esac
}

# ============================================================================
# FONCTION UTILITAIRE : Obtenir le port pour un environnement
# ============================================================================

get_port_for_env() {
    local env=$1
    local service=${2:-api}

    case "$service" in
        api)
            case "$env" in
                dev) echo "${DEV_PORT:-8001}" ;;
                staging) echo "${STAGING_PORT:-8002}" ;;
                prod) echo "${PROD_PORT:-8000}" ;;
                *) echo "8000" ;;
            esac
            ;;
        redis)
            case "$env" in
                dev) echo "${REDIS_DEV_PORT:-6379}" ;;
                staging) echo "${REDIS_STAGING_PORT:-6381}" ;;
                prod) echo "${REDIS_PROD_PORT:-6380}" ;;
                *) echo "6379" ;;
            esac
            ;;
        postgres)
            case "$env" in
                dev) echo "${POSTGRES_DEV_PORT:-5432}" ;;
                staging) echo "${POSTGRES_STAGING_PORT:-5433}" ;;
                prod) echo "${POSTGRES_PROD_PORT:-5434}" ;;
                *) echo "5432" ;;
            esac
            ;;
        prometheus)
            case "$env" in
                dev) echo "${PROMETHEUS_DEV_PORT:-9090}" ;;
                staging) echo "${PROMETHEUS_STAGING_PORT:-9091}" ;;
                prod) echo "${PROMETHEUS_PROD_PORT:-9090}" ;;
                *) echo "9090" ;;
            esac
            ;;
        grafana)
            case "$env" in
                dev) echo "${GRAFANA_DEV_PORT:-3000}" ;;
                staging) echo "${GRAFANA_STAGING_PORT:-3001}" ;;
                prod) echo "${GRAFANA_PROD_PORT:-3000}" ;;
                *) echo "3000" ;;
            esac
            ;;
        superset)
            case "$env" in
                dev) echo "${SUPERSET_DEV_PORT:-8088}" ;;
                staging) echo "${SUPERSET_STAGING_PORT:-8089}" ;;
                prod) echo "${SUPERSET_PROD_PORT:-8088}" ;;
                *) echo "8088" ;;
            esac
            ;;
        *)
            echo "8000"
            ;;
    esac
}

# ============================================================================
# FONCTION UTILITAIRE : Construire le nom de conteneur
# ============================================================================

get_container_name() {
    local env=$1
    local service=$2
    echo "${COMPOSE_PROJECT_NAME:-$PROJECT_NAME}-${service}-${env}"
}

# ============================================================================
# FONCTION UTILITAIRE : Afficher la configuration (debug)
# ============================================================================

show_config() {
    echo "========================================" >&2
    echo "Configuration chargée depuis .devops.yml" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "Projet:" >&2
    echo "  PROJECT_NAME          = $PROJECT_NAME" >&2
    echo "  COMPOSE_PROJECT_NAME  = $COMPOSE_PROJECT_NAME" >&2
    echo "  PROJECT_ROOT          = $PROJECT_ROOT" >&2
    echo "" >&2
    echo "Registry:" >&2
    echo "  REGISTRY_TYPE         = $REGISTRY_TYPE" >&2
    echo "  REGISTRY_URL          = $REGISTRY_URL" >&2
    echo "  REGISTRY_USERNAME     = $REGISTRY_USERNAME" >&2
    echo "  IMAGE_NAME            = $IMAGE_NAME" >&2
    echo "" >&2
    echo "Git:" >&2
    echo "  GIT_REPO              = $GIT_REPO" >&2
    echo "  DEV_BRANCH            = $DEV_BRANCH" >&2
    echo "  STAGING_BRANCH        = $STAGING_BRANCH" >&2
    echo "  PROD_BRANCH           = $PROD_BRANCH" >&2
    echo "" >&2
    echo "Ports:" >&2
    echo "  DEV_PORT              = $DEV_PORT" >&2
    echo "  STAGING_PORT          = $STAGING_PORT" >&2
    echo "  PROD_PORT             = $PROD_PORT" >&2
    echo "" >&2
    echo "Structure:" >&2
    echo "  DEPLOYMENT_DIR        = $DEPLOYMENT_DIR" >&2
    echo "  DOCKERFILE_DIR        = $DOCKERFILE_DIR" >&2
    echo "  DEPLOYMENT_PATH       = $DEPLOYMENT_PATH" >&2
    echo "  DOCKERFILE_PATH       = $DOCKERFILE_PATH" >&2
    echo "========================================" >&2
}

# Export des fonctions pour qu'elles soient disponibles dans les scripts
export -f get_branch_for_env 2>/dev/null || true
export -f get_port_for_env 2>/dev/null || true
export -f get_container_name 2>/dev/null || true
export -f show_config 2>/dev/null || true
