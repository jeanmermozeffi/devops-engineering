#!/bin/bash
# ============================================================================
# Vérification des images Docker d'un projet : ne télécharger que le manquant
# ============================================================================
#
# Lit les fichiers compose du projet (deployment/docker-compose.yml +
# deployment/docker-compose.<env>.yml), en déduit :
#   - les images de base des Dockerfile (FROM, ARG et build-args résolus) ;
#   - les images des services sans build (postgres, redis...).
# Puis indique pour chacune si elle est déjà présente localement.
#
# Usage:
#   images.sh check  [env]              État de chaque image (rien n'est téléchargé)
#   images.sh pull   [env] [--refresh]  Télécharge uniquement les images absentes
#                                       (--refresh : re-pull aussi les tags mobiles, ex. latest)
#   images.sh ensure <image> [...]      Pull d'une image seulement si absente
#                                       (un tag "latest" est toujours re-vérifié)
#
# Variables : PROJECT_RUNTIME_ROOT (défaut: répertoire courant),
#             DEPLOYMENT_DIR (défaut: deployment)
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

RUNTIME_ROOT="${PROJECT_RUNTIME_ROOT:-$(pwd)}"
DEPLOY_DIR="${DEPLOYMENT_DIR:-deployment}"

# Taille lisible d'une image locale, vide si absente.
image_local_size() {
    local size
    size=$(docker image inspect --format '{{.Size}}' "$1" 2>/dev/null) || return 1
    awk -v s="$size" 'BEGIN { if (s >= 1e9) printf "%.1f Go", s/1e9; else printf "%.0f Mo", s/1e6 }'
}

# Un tag mobile peut changer côté registry : sa présence locale ne garantit pas
# qu'il soit à jour. Un tag versionné (3.3.1-python3.12, v1.2.0) est immuable.
is_mobile_tag() {
    local ref="${1%%@*}"
    local tag="latest"
    case "${ref##*/}" in
        *:*) tag="${ref##*:}" ;;
    esac
    case "$tag" in
        latest|stable|main|master|dev|develop|staging|prod|edge|nightly) return 0 ;;
    esac
    return 1
}

# Pull seulement si nécessaire. $2 = "refresh" pour re-vérifier les tags mobiles.
ensure_image() {
    local image=$1
    local mode=${2:-}
    local size
    if size=$(image_local_size "$image"); then
        if is_mobile_tag "$image" && [ "$mode" = "refresh" ]; then
            log_info "Tag mobile, vérification des mises à jour: $image"
            docker pull "$image"
        else
            log_info "Déjà présente, pas de pull: $image ($size)"
        fi
    else
        log_info "Absente, téléchargement: $image"
        docker pull "$image"
    fi
}

# Arguments compose (-f ...) pour l'environnement demandé.
compose_file_args() {
    local env=$1
    local base="$DEPLOY_DIR/docker-compose.yml"
    if [ ! -f "$RUNTIME_ROOT/$base" ]; then
        log_error "Fichier compose introuvable: $RUNTIME_ROOT/$base"
        return 1
    fi
    echo "-f $base"
    if [ -n "$env" ] && [ -f "$RUNTIME_ROOT/$DEPLOY_DIR/docker-compose.$env.yml" ]; then
        echo "-f $DEPLOY_DIR/docker-compose.$env.yml"
    fi
}

# Même résolution que load_env() de deploy.sh : variables exigées par le compose
# (${VAR:?...}) et versions d'images (AIRFLOW_VERSION...). À appeler dans un sous-shell.
load_env_file() {
    local env=$1 env_file="" candidate key value
    [ -z "$env" ] && return 0
    for candidate in ".env.$env.local" ".env.$env" "$DEPLOY_DIR/.env.$env.local" "$DEPLOY_DIR/.env.$env"; do
        if [ -f "$RUNTIME_ROOT/$candidate" ]; then
            env_file="$candidate"
            break
        fi
    done
    [ -z "$env_file" ] && return 0
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        export "$key=$value"
    done < "$RUNTIME_ROOT/$env_file"
    export ENV="${ENV:-$env}"
    if [ -z "${AIRFLOW_ENV_FILE:-}" ]; then
        case "$env_file" in
            "$DEPLOY_DIR"/*) export AIRFLOW_ENV_FILE="${env_file#"$DEPLOY_DIR"/}" ;;
            *) export AIRFLOW_ENV_FILE="../$env_file" ;;
        esac
    fi
}

# Liste "type<TAB>image<TAB>services" à partir de la config compose résolue.
list_project_images() {
    local env=$1
    local files
    files=$(compose_file_args "$env" | tr '\n' ' ') || return 1
    # shellcheck disable=SC2086
    (cd "$RUNTIME_ROOT" && load_env_file "$env" && docker compose $files config --format json) | python3 -c '
import json, os, re, sys

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(1)  # docker compose config a échoué (message déjà affiché)
cfg = json.loads(raw)
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")

def expand(value, env):
    def repl(m):
        name = m.group(1) or m.group(3)
        default = m.group(2)
        val = env.get(name)
        return val if val not in (None, "") else (default or "")
    for _ in range(5):  # défauts imbriqués: ${A:-${B}}
        new = VAR.sub(repl, value)
        if new == value:
            break
        value = new
    return value

def base_images(dockerfile, build_args):
    try:
        lines = open(dockerfile, encoding="utf-8").read().replace("\\\n", " ").splitlines()
    except OSError:
        return []
    args, stages, images, seen_from = {}, set(), [], False
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        word = line.split(None, 1)[0].upper()
        if word == "ARG" and not seen_from:
            for decl in line.split()[1:]:
                name, _, default = decl.partition("=")
                args[name] = build_args.get(name) or expand(default.strip("\"\x27"), {**args})
        elif word == "FROM":
            seen_from = True
            parts = [p for p in line.split()[1:] if not p.startswith("--")]
            if not parts:
                continue
            image = expand(parts[0], {**args, **build_args})
            if len(parts) >= 3 and parts[1].upper() == "AS":
                stages.add(parts[2].lower())
            if image and image.lower() not in stages and image != "scratch":
                images.append(image)
    return images

found = {}
services = cfg.get("services") or {}
# Images produites par un build du projet : construites, jamais pullées.
built = {svc["image"] for svc in services.values() if svc.get("build") and svc.get("image")}
for name, svc in services.items():
    build = svc.get("build")
    if build:
        ctx = build.get("context", ".")
        df = build.get("dockerfile", "Dockerfile")
        path = df if os.path.isabs(df) else os.path.join(ctx, df)
        args = {k: ("" if v is None else str(v)) for k, v in (build.get("args") or {}).items()}
        for img in base_images(path, args):
            found.setdefault(("base", img), []).append(name)
    elif svc.get("image") and svc["image"] not in built:
        found.setdefault(("service", svc["image"]), []).append(name)

for (kind, img), services in sorted(found.items(), key=lambda kv: (kv[0][0], kv[0][1])):
    print("\t".join([kind, img, ",".join(sorted(set(services)))]))
'
}

cmd_check() {
    local env=$1
    local action=${2:-check}
    local refresh=${3:-}
    local list present=0 missing=0 failed=0
    list=$(list_project_images "$env") || { log_error "Lecture de la config compose impossible"; return 1; }

    if [ -z "$list" ]; then
        log_warn "Aucune image trouvée dans la configuration compose"
        return 0
    fi

    echo -e "${WHITE}Images du projet${env:+ ($env)} :${NC}"
    while IFS="$(printf '\t')" read -r kind image services; do
        [ -z "$image" ] && continue
        local label="base de $services"
        [ "$kind" = "service" ] && label="service $services"
        local size
        if size=$(image_local_size "$image"); then
            present=$((present + 1))
            local note=""
            is_mobile_tag "$image" && note=" ${YELLOW}(tag mobile)${NC}"
            echo -e "  ${GREEN}✓ présente${NC}  $image  ${CYAN}$size${NC}  [$label]$note"
            if [ "$action" = "pull" ] && [ "$refresh" = "refresh" ] && is_mobile_tag "$image"; then
                docker pull "$image" || failed=$((failed + 1))
            fi
        else
            missing=$((missing + 1))
            echo -e "  ${RED}✗ absente${NC}   $image  [$label]"
            if [ "$action" = "pull" ]; then
                docker pull "$image" || failed=$((failed + 1))
            fi
        fi
    done <<EOF
$list
EOF

    echo ""
    if [ "$action" = "pull" ]; then
        log_info "$present déjà présente(s), $missing téléchargée(s)$([ $failed -gt 0 ] && echo ", $failed en échec")"
        [ $failed -eq 0 ]
    else
        log_info "$present présente(s), $missing absente(s)"
        [ $missing -gt 0 ] && log_info "Télécharger uniquement les absentes : devops images pull${env:+ $env}"
        return 0
    fi
}

usage() {
    sed -n '13,20p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    local action=${1:-check}
    shift || true
    case "$action" in
        check)
            cmd_check "${1:-}" check
            ;;
        pull)
            local env="" refresh=""
            for arg in "$@"; do
                case "$arg" in
                    --refresh) refresh="refresh" ;;
                    *) env="$arg" ;;
                esac
            done
            cmd_check "$env" pull "$refresh"
            ;;
        ensure)
            [ $# -eq 0 ] && { usage; exit 1; }
            local image
            for image in "$@"; do
                ensure_image "$image" refresh
            done
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            log_error "Action inconnue: $action"
            usage
            exit 1
            ;;
    esac
}

main "$@"
