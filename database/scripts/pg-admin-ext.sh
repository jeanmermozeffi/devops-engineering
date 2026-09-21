# =============================================================================
# pg-admin-ext.sh — Extensions DBA pour pg-admin.sh
#
# Ce fichier est sourcé par pg-admin.sh. Il NE DOIT PAS être exécuté seul :
# il dépend des helpers définis dans pg-admin.sh (execute_sql, log_*,
# validate_identifier, audit_log, couleurs, etc.).
#
# Axes ajoutés :
#   1. Matrice des droits & relations user↔bd   → perm matrix / who-can / what-can / tree
#   2. Traçabilité / audit en base               → audit db-init / report / log / diff
#   3. Déclaratif GitOps (plan / apply / drift)  → state plan / apply / drift / export
#   4. Monitoring DBA avancé                      → monitor bloat / unused-idx / top / cache / vacuum / long-tx / health
# =============================================================================

# Schémas système exclus partout
readonly _SYS_SCHEMAS="'pg_catalog','information_schema','pg_toast'"

# Fichier manifeste GitOps + répertoire d'état déclaré
DESIRED_DIR="${DESIRED_DIR:-${SCRIPT_DIR}/desired}"
STATE_MANIFEST="${STATE_MANIFEST:-${DESIRED_DIR}/state.conf}"

# Audit en base : activé si AUDIT_DB est défini (nom de la base hébergeant le schéma audit)
AUDIT_DB="${AUDIT_DB:-}"

# ─────────────────────────────────────────────────────────────────────────────
# Helper : vérifier qu'une table existe (protège has_table_privilege)
# ─────────────────────────────────────────────────────────────────────────────
_table_exists() {
    local db="$1" schema="$2" table="$3"
    local n
    n=$(execute_sql_list "SELECT 1 FROM pg_tables WHERE schemaname='$(pg_escape_literal "$schema")' AND tablename='$(pg_escape_literal "$table")' LIMIT 1;" "$db")
    [[ "$n" == "1" ]]
}

_extension_present() {
    local db="$1" ext="$2"
    local n
    n=$(execute_sql_list "SELECT 1 FROM pg_extension WHERE extname='$(pg_escape_literal "$ext")' LIMIT 1;" "$db")
    [[ "$n" == "1" ]]
}

# =============================================================================
# AXE 1 — MATRICE DES DROITS & RELATIONS USER ↔ BD
# =============================================================================

# Vue d'ensemble : qui est lié à quelle base (CONNECT) + accès par schéma.
perm_matrix() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "MATRICE DES DROITS — relations user ↔ bd ($dbname)"

    echo -e "\n${WHITE}── Utilisateurs ↔ Bases (privilège CONNECT) ──${NC}"
    execute_sql "
SELECT r.rolname AS \"Utilisateur\",
       COALESCE(string_agg(d.datname, ', ' ORDER BY d.datname)
                FILTER (WHERE has_database_privilege(r.rolname, d.datname, 'CONNECT')), '—')
         AS \"Bases accessibles (CONNECT)\",
       CASE WHEN r.rolsuper THEN '⚠ SUPERUSER' ELSE '' END AS \"Alerte\"
FROM pg_roles r
CROSS JOIN pg_database d
WHERE r.rolcanlogin
  AND r.rolname NOT LIKE 'pg_%'
  AND NOT d.datistemplate
  AND d.datname <> 'postgres'
GROUP BY r.rolname, r.rolsuper
ORDER BY r.rolname;"

    echo -e "\n${WHITE}── Utilisateurs × Schémas de '$dbname' (U=USAGE C=CREATE · tables lisibles) ──${NC}"
    execute_sql "
WITH logins AS (
    SELECT rolname FROM pg_roles
    WHERE rolcanlogin AND rolname NOT LIKE 'pg_%'
),
schemas AS (
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ($_SYS_SCHEMAS)
)
SELECT l.rolname AS \"Utilisateur\",
       s.nspname AS \"Schéma\",
       (CASE WHEN has_schema_privilege(l.rolname, s.nspname, 'USAGE')  THEN 'U' ELSE '·' END ||
        CASE WHEN has_schema_privilege(l.rolname, s.nspname, 'CREATE') THEN 'C' ELSE '·' END) AS \"U/C\",
       (SELECT count(*) FROM pg_tables t
        WHERE t.schemaname = s.nspname
          AND has_table_privilege(l.rolname, quote_ident(t.schemaname)||'.'||quote_ident(t.tablename), 'SELECT')
       ) AS \"Tables lisibles\"
FROM logins l
CROSS JOIN schemas s
ORDER BY l.rolname, s.nspname;" "$dbname"
}

# Recherche inversée : QUI peut accéder à cette table (droits effectifs, via rôles inclus) ?
perm_who_can() {
    local dbname="$1" schema="$2" table="$3"
    validate_identifier "$dbname"  "nom de base"   || return 1
    validate_identifier "$schema"  "nom de schéma" || return 1
    validate_identifier "$table"   "nom de table"  || return 1

    if ! _table_exists "$dbname" "$schema" "$table"; then
        log_error "Table introuvable: $dbname.$schema.$table"
        return 1
    fi

    log_header "QUI PEUT ACCÉDER À $schema.$table ? (droits effectifs, héritage de rôles inclus)"
    execute_sql "
WITH privs(p) AS (
    VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')
)
SELECT r.rolname AS \"Utilisateur/Rôle\",
       CASE WHEN r.rolcanlogin THEN 'login' ELSE 'groupe' END AS \"Type\",
       string_agg(p.p, ', ' ORDER BY p.p)
         FILTER (WHERE has_table_privilege(r.rolname, '$(pg_escape_literal "$schema")'||'.'||'$(pg_escape_literal "$table")', p.p))
         AS \"Privilèges effectifs\"
FROM pg_roles r
CROSS JOIN privs p
WHERE r.rolname NOT LIKE 'pg_%'
GROUP BY r.rolname, r.rolcanlogin
HAVING string_agg(p.p, ',')
       FILTER (WHERE has_table_privilege(r.rolname, '$(pg_escape_literal "$schema")'||'.'||'$(pg_escape_literal "$table")', p.p)) IS NOT NULL
ORDER BY r.rolcanlogin DESC, r.rolname;" "$dbname"
}

# Recherche directe : QUE peut toucher cet utilisateur (objets atteignables, droits effectifs) ?
perm_what_can() {
    local username="$1" dbname="${2:-$PG_DEFAULT_DB}"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    validate_identifier "$dbname"   "nom de base"       || return 1

    log_header "QUE PEUT TOUCHER '$username' ? (droits effectifs sur $dbname)"

    echo -e "\n${WHITE}── Bases (CONNECT) ──${NC}"
    execute_sql "
SELECT d.datname AS \"Base\",
       CASE WHEN has_database_privilege('$(pg_escape_literal "$username")', d.datname, 'CONNECT')
            THEN '✓' ELSE '✗' END AS \"CONNECT\"
FROM pg_database d
WHERE NOT d.datistemplate AND d.datname <> 'postgres'
ORDER BY d.datname;"

    echo -e "\n${WHITE}── Rôles hérités (récursif) ──${NC}"
    execute_sql "
WITH RECURSIVE memberships AS (
    SELECT roleid, member FROM pg_auth_members m
    WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname='$(pg_escape_literal "$username")')
    UNION
    SELECT am.roleid, am.member
    FROM pg_auth_members am
    JOIN memberships ms ON am.member = ms.roleid
)
SELECT DISTINCT r.rolname AS \"Rôle hérité\"
FROM memberships ms JOIN pg_roles r ON r.oid = ms.roleid
ORDER BY r.rolname;"

    echo -e "\n${WHITE}── Tables atteignables ──${NC}"
    execute_sql "
SELECT t.schemaname AS \"Schéma\", t.tablename AS \"Table\",
       array_to_string(ARRAY(
           SELECT p FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p
           WHERE has_table_privilege('$(pg_escape_literal "$username")',
                 quote_ident(t.schemaname)||'.'||quote_ident(t.tablename), p)
       ), ', ') AS \"Privilèges effectifs\"
FROM pg_tables t
WHERE t.schemaname NOT IN ($_SYS_SCHEMAS)
  AND EXISTS (
      SELECT 1 FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p
      WHERE has_table_privilege('$(pg_escape_literal "$username")',
            quote_ident(t.schemaname)||'.'||quote_ident(t.tablename), p)
  )
ORDER BY t.schemaname, t.tablename;" "$dbname"
}

# Arbre d'appartenance aux rôles d'un utilisateur
perm_tree() {
    local username="$1"
    validate_identifier "$username" "nom d'utilisateur" || return 1
    log_header "ARBRE DES RÔLES — $username"
    execute_sql "
WITH RECURSIVE tree AS (
    SELECT r.oid, r.rolname, 0 AS depth
    FROM pg_roles r WHERE r.rolname='$(pg_escape_literal "$username")'
    UNION ALL
    SELECT pr.oid, pr.rolname, t.depth + 1
    FROM tree t
    JOIN pg_auth_members am ON am.member = t.oid
    JOIN pg_roles pr ON pr.oid = am.roleid
)
SELECT repeat('   ', depth) || CASE WHEN depth=0 THEN '● ' ELSE '└─ ' END || rolname AS \"Hiérarchie des rôles\"
FROM tree ORDER BY depth, rolname;"
}

# =============================================================================
# AXE 4 — MONITORING DBA AVANCÉ
# =============================================================================

monitor_bloat() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "ESTIMATION DU BLOAT — $dbname (top 25)"
    execute_sql "
SELECT schemaname AS \"Schéma\", relname AS \"Table\",
       pg_size_pretty(pg_total_relation_size(relid)) AS \"Taille\",
       n_live_tup AS \"Lignes vivantes\",
       n_dead_tup AS \"Lignes mortes\",
       CASE WHEN n_live_tup > 0
            THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)
            ELSE 0 END AS \"% mort\"
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 25;" "$dbname"
}

monitor_unused_indexes() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "INDEX INUTILISÉS (idx_scan = 0) — $dbname"
    execute_sql "
SELECT schemaname AS \"Schéma\", relname AS \"Table\", indexrelname AS \"Index\",
       pg_size_pretty(pg_relation_size(indexrelid)) AS \"Taille\",
       idx_scan AS \"Scans\"
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelid NOT IN (SELECT conindid FROM pg_constraint WHERE contype IN ('p','u'))
ORDER BY pg_relation_size(indexrelid) DESC;" "$dbname"
}

monitor_index_usage() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "UTILISATION DES INDEX — $dbname (ratio scans index vs seq)"
    execute_sql "
SELECT schemaname AS \"Schéma\", relname AS \"Table\",
       seq_scan AS \"Seq scans\", idx_scan AS \"Index scans\",
       CASE WHEN seq_scan + idx_scan > 0
            THEN round(100.0 * idx_scan / (seq_scan + idx_scan), 1)
            ELSE NULL END AS \"% index\"
FROM pg_stat_user_tables
ORDER BY seq_scan DESC
LIMIT 25;" "$dbname"
}

monitor_top_queries() {
    local dbname="${1:-$PG_DEFAULT_DB}" limit="${2:-15}"
    validate_port "$limit" 2>/dev/null || limit=15
    log_header "TOP REQUÊTES (pg_stat_statements) — $dbname"
    if ! _extension_present "$dbname" "pg_stat_statements"; then
        log_warn "Extension pg_stat_statements absente sur '$dbname'."
        log_info  "Pour l'activer : ajouter 'shared_preload_libraries = pg_stat_statements'"
        log_info  "dans postgresql.conf, redémarrer, puis : CREATE EXTENSION pg_stat_statements;"
        return 0
    fi
    execute_sql "
SELECT substring(regexp_replace(query, '\s+', ' ', 'g') for 70) AS \"Requête\",
       calls AS \"Appels\",
       round(total_exec_time::numeric, 1) AS \"Temps total (ms)\",
       round(mean_exec_time::numeric, 2)  AS \"Moy (ms)\",
       round((100 * total_exec_time / NULLIF(sum(total_exec_time) OVER (), 0))::numeric, 1) AS \"% temps\"
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT $limit;" "$dbname"
}

monitor_cache() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "CACHE HIT RATIO — $dbname"
    execute_sql "
SELECT 'Tables (heap)' AS \"Zone\",
       round(100.0 * sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit + heap_blks_read), 0), 2) AS \"% cache\"
FROM pg_statio_user_tables
UNION ALL
SELECT 'Index',
       round(100.0 * sum(idx_blks_hit) / NULLIF(sum(idx_blks_hit + idx_blks_read), 0), 2)
FROM pg_statio_user_indexes;" "$dbname"
    log_info "Cible saine : > 99% sur une base bien dimensionnée."
}

monitor_vacuum() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "ÉTAT AUTOVACUUM / VACUUM — $dbname (tables avec lignes mortes)"
    execute_sql "
SELECT schemaname AS \"Schéma\", relname AS \"Table\",
       n_dead_tup AS \"Mortes\",
       to_char(last_vacuum,      'YYYY-MM-DD HH24:MI') AS \"Dernier VACUUM\",
       to_char(last_autovacuum,  'YYYY-MM-DD HH24:MI') AS \"Dernier AUTOVACUUM\",
       vacuum_count AS \"Nb vacuum\", autovacuum_count AS \"Nb autovac\"
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 25;" "$dbname"
}

monitor_long_tx() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "TRANSACTIONS LONGUES & IDLE-IN-TRANSACTION"
    execute_sql "
SELECT pid AS \"PID\",
       usename AS \"Utilisateur\", datname AS \"Base\", state AS \"État\",
       round(EXTRACT(EPOCH FROM (now() - xact_start)))::int AS \"Durée tx (s)\",
       substring(regexp_replace(query, '\s+', ' ', 'g') for 60) AS \"Requête\"
FROM pg_stat_activity
WHERE state <> 'idle'
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval '30 seconds'
ORDER BY xact_start ASC;"
}

# Tableau de bord santé — synthèse en un coup d'œil
monitor_health() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    log_header "TABLEAU DE BORD SANTÉ — $dbname"
    monitor_cache "$dbname"
    echo -e "\n${WHITE}── Connexions (vs max_connections) ──${NC}"
    execute_sql "
SELECT (SELECT count(*) FROM pg_stat_activity)             AS \"Connexions ouvertes\",
       current_setting('max_connections')                  AS \"Max\",
       (SELECT count(*) FROM pg_stat_activity WHERE state='active')              AS \"Actives\",
       (SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction') AS \"Idle in tx\";"
    echo -e "\n${WHITE}── Top 5 tables par lignes mortes ──${NC}"
    execute_sql "
SELECT schemaname AS \"Schéma\", relname AS \"Table\", n_dead_tup AS \"Mortes\"
FROM pg_stat_user_tables WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC LIMIT 5;" "$dbname"
    echo -e "\n${WHITE}── Verrous en attente ──${NC}"
    execute_sql "
SELECT count(*) AS \"Verrous non accordés (waiting)\"
FROM pg_locks WHERE NOT granted;"
}

# =============================================================================
# AXE 2 — TRAÇABILITÉ / AUDIT EN BASE
# =============================================================================

# Crée le schéma audit et ses tables dans la base cible.
audit_db_init() {
    local dbname="${1:-$AUDIT_DB}"
    [[ -z "$dbname" ]] && { log_error "Usage: audit db-init <db>"; return 1; }
    validate_identifier "$dbname" "nom de base" || return 1
    log_header "INITIALISATION AUDIT EN BASE — $dbname"
    execute_sql "
CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.action_log (
    id          bigserial PRIMARY KEY,
    ts          timestamptz NOT NULL DEFAULT now(),
    os_user     text,
    pg_user     text NOT NULL DEFAULT current_user,
    client_host inet DEFAULT inet_client_addr(),
    action      text NOT NULL,
    target      text,
    detail      jsonb,
    dry_run     boolean NOT NULL DEFAULT false,
    success     boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS idx_action_log_ts     ON audit.action_log (ts DESC);
CREATE INDEX IF NOT EXISTS idx_action_log_action ON audit.action_log (action);
CREATE INDEX IF NOT EXISTS idx_action_log_target ON audit.action_log (target);

CREATE TABLE IF NOT EXISTS audit.acl_snapshot (
    id        bigserial PRIMARY KEY,
    ts        timestamptz NOT NULL DEFAULT now(),
    username  text NOT NULL,
    dbname    text NOT NULL,
    snapshot  jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_acl_snapshot_user ON audit.acl_snapshot (username, ts DESC);

CREATE TABLE IF NOT EXISTS audit.password_rotation (
    username     text PRIMARY KEY,
    last_rotated timestamptz NOT NULL DEFAULT now(),
    rotated_by   text NOT NULL DEFAULT current_user
);
" "$dbname"
    log_success "Schéma 'audit' prêt sur '$dbname' (tables action_log, acl_snapshot)."
    log_info "Activez l'enregistrement automatique avec : export AUDIT_DB=$dbname"
}

# Échappe une valeur pour un littéral JSON entre guillemets (utilisé pour le detail).
_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Enregistre une action dans audit.action_log (best-effort, jamais bloquant).
# Appelée par le wrapper audit_log() patché dans pg-admin.sh.
audit_db_record() {
    [[ -z "$AUDIT_DB" ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0
    local action="$1" details="${2:-}"
    local who; who=$(whoami 2>/dev/null || echo unknown)
    local detail_json="{\"raw\":\"$(_json_escape "$details")\"}"
    execute_sql "
INSERT INTO audit.action_log (os_user, action, target, detail)
VALUES ('$(pg_escape_literal "$who")',
        '$(pg_escape_literal "$action")',
        NULLIF('$(pg_escape_literal "$details")',''),
        '$(pg_escape_literal "$detail_json")'::jsonb);" "$AUDIT_DB" >/dev/null 2>&1 || true
}

# Capture un instantané des droits effectifs d'un user (pour le diff avant/après).
# Appelé en fin de perm_grant/perm_revoke/rbac_assign/... (un point d'ancrage par changement).
audit_snapshot_user() {
    [[ -z "$AUDIT_DB" ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0
    local username="$1" dbname="${2:-$PG_DEFAULT_DB}"
    execute_sql "
INSERT INTO audit.acl_snapshot (username, dbname, snapshot)
SELECT '$(pg_escape_literal "$username")', '$(pg_escape_literal "$dbname")',
  jsonb_build_object(
    'roles', COALESCE((SELECT jsonb_agg(r.rolname ORDER BY r.rolname)
                       FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid
                       WHERE am.member=(SELECT oid FROM pg_roles WHERE rolname='$(pg_escape_literal "$username")')), '[]'::jsonb),
    'tables', COALESCE((SELECT jsonb_object_agg(t.schemaname||'.'||t.tablename, privs)
                        FROM (
                           SELECT schemaname, tablename,
                             array_to_string(ARRAY(SELECT p FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p
                               WHERE has_table_privilege('$(pg_escape_literal "$username")',
                                     quote_ident(schemaname)||'.'||quote_ident(tablename), p)), ',') AS privs
                           FROM pg_tables WHERE schemaname NOT IN ($_SYS_SCHEMAS)
                        ) t WHERE t.privs <> ''), '{}'::jsonb)
  );" "$AUDIT_DB" >/dev/null 2>&1 || true
}

# Diff entre les deux derniers instantanés d'un utilisateur (avant/après).
audit_diff_user() {
    local username="$1" dbname="${2:-$AUDIT_DB}"
    [[ -z "$AUDIT_DB" ]] && { log_error "AUDIT_DB non défini. Lancez d'abord: audit db-init <db>"; return 1; }
    validate_identifier "$username" "nom d'utilisateur" || return 1
    log_header "DIFF AVANT/APRÈS — $username (2 derniers instantanés)"
    execute_sql "
WITH snaps AS (
    SELECT id, ts, snapshot,
           row_number() OVER (ORDER BY ts DESC) AS rn
    FROM audit.acl_snapshot
    WHERE username='$(pg_escape_literal "$username")'
)
SELECT
  (SELECT to_char(ts,'YYYY-MM-DD HH24:MI:SS') FROM snaps WHERE rn=2) AS \"Avant\",
  (SELECT to_char(ts,'YYYY-MM-DD HH24:MI:SS') FROM snaps WHERE rn=1) AS \"Après\";
" "$AUDIT_DB"
    echo -e "\n${WHITE}── Rôles ajoutés (+) / retirés (-) ──${NC}"
    execute_sql "
WITH snaps AS (
    SELECT snapshot, row_number() OVER (ORDER BY ts DESC) AS rn
    FROM audit.acl_snapshot WHERE username='$(pg_escape_literal "$username")'
),
before AS (SELECT jsonb_array_elements_text(snapshot->'roles') AS role FROM snaps WHERE rn=2),
after  AS (SELECT jsonb_array_elements_text(snapshot->'roles') AS role FROM snaps WHERE rn=1)
SELECT '＋ '||role AS \"Changement de rôle\" FROM after  WHERE role NOT IN (SELECT role FROM before)
UNION ALL
SELECT '－ '||role               FROM before WHERE role NOT IN (SELECT role FROM after);
" "$AUDIT_DB"
}

# Rapport d'audit (depuis la base). Format texte par défaut, HTML si --html.
audit_report() {
    local dbname="${1:-$AUDIT_DB}" fmt="${2:-text}"
    [[ -z "$dbname" ]] && { log_error "Usage: audit report <db> [--html]"; return 1; }
    [[ "$fmt" == "--html" ]] && fmt="html"

    if [[ "$fmt" == "html" ]]; then
        local out="${SCRIPT_DIR}/logs/audit-report-$(date +%Y%m%d_%H%M%S).html"
        mkdir -p "${SCRIPT_DIR}/logs"
        {
            echo "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Audit $dbname</title>"
            echo "<style>body{font-family:system-ui,sans-serif;margin:2rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:6px 10px;font-size:13px}th{background:#1f2937;color:#fff;text-align:left}tr:nth-child(even){background:#f9fafb}h1{color:#1f2937}</style></head><body>"
            echo "<h1>Rapport d'audit — $dbname</h1><p>Généré le $(date '+%Y-%m-%d %H:%M:%S')</p>"
        } > "$out"
        execute_sql "
SELECT '<table><tr><th>Date</th><th>OS user</th><th>PG user</th><th>Action</th><th>Cible</th><th>Détail</th></tr>' ||
       string_agg(
         '<tr><td>'||to_char(ts,'YYYY-MM-DD HH24:MI:SS')||'</td><td>'||COALESCE(os_user,'')||
         '</td><td>'||pg_user||'</td><td>'||action||'</td><td>'||COALESCE(target,'')||
         '</td><td>'||COALESCE(detail->>'raw','')||'</td></tr>', '' ORDER BY ts DESC) ||
       '</table>'
FROM (SELECT * FROM audit.action_log ORDER BY ts DESC LIMIT 500) s;" "$dbname" -t -A >> "$out" 2>/dev/null
        echo "</body></html>" >> "$out"
        log_success "Rapport HTML généré : $out"
        return 0
    fi

    log_header "RAPPORT D'AUDIT — $dbname (100 dernières actions)"
    execute_sql "
SELECT to_char(ts,'MM-DD HH24:MI') AS \"Date\",
       os_user AS \"OS\", pg_user AS \"PG user\",
       action AS \"Action\", COALESCE(target,'') AS \"Cible\",
       COALESCE(detail->>'raw','') AS \"Détail\"
FROM audit.action_log
ORDER BY ts DESC
LIMIT 100;" "$dbname"
}

# =============================================================================
# AXE 3 — DÉCLARATIF GITOPS (plan / apply / drift / export)
# =============================================================================
#
# Manifeste : desired/state.conf — format ligne, versionnable en git.
#   user   <name> [profile=<p>] [login=true|false] [conn_limit=N]
#   assign <name> <profile>
#   apply  <db> <schema> <profile>      # engineer|analyst|bi (idempotent)
#
# Exemple :
#   user   alice profile=analyst conn_limit=5
#   user   svc_etl login=false
#   assign alice analyst
#   apply  db_analytics_oscrum dwh   analyst
#   apply  db_analytics_oscrum mart bi
# =============================================================================

_state_check_manifest() {
    if [[ ! -f "$STATE_MANIFEST" ]]; then
        log_error "Manifeste introuvable: $STATE_MANIFEST"
        log_info  "Créez-le, ou générez-le depuis l'état réel : ./pg-admin.sh state export <db>"
        return 1
    fi
}

# Itère les directives du manifeste (ignore commentaires/lignes vides).
# Usage : _state_each <callback>  → appelle callback avec les champs de chaque ligne.
_state_each() {
    local cb="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                    # retire commentaire en fin de ligne
        line="$(echo "$line" | xargs 2>/dev/null || true)"  # trim
        [[ -z "$line" ]] && continue
        # shellcheck disable=SC2086
        "$cb" $line || true   # une directive en échec ne stoppe pas la réconciliation
    done < "$STATE_MANIFEST"
}

# Extrait une option clé=valeur d'une liste d'arguments (ex: profile=analyst).
_state_opt() {
    local key="$1"; shift
    local kv
    for kv in "$@"; do
        [[ "$kv" == "$key="* ]] && { echo "${kv#*=}"; return 0; }
    done
    echo ""
}

# Callback de planification : compare une directive à l'état réel.
_state_plan_line() {
    local kind="$1"; shift
    case "$kind" in
        user)
            local name="$1"; shift
            validate_identifier "$name" "user manifeste" >/dev/null 2>&1 || { echo "  ${RED}✗ user invalide: $name${NC}"; return; }
            local exists; exists=$(execute_sql_list "SELECT 1 FROM pg_roles WHERE rolname='$(pg_escape_literal "$name")';")
            if [[ "$exists" != "1" ]]; then
                echo -e "  ${GREEN}＋ CREATE USER${NC} $name"
            else
                local want_limit; want_limit=$(_state_opt conn_limit "$@")
                if [[ -n "$want_limit" ]]; then
                    local cur; cur=$(execute_sql_list "SELECT rolconnlimit FROM pg_roles WHERE rolname='$(pg_escape_literal "$name")';")
                    [[ "$cur" != "$want_limit" ]] && echo -e "  ${YELLOW}~ ALTER${NC} $name conn_limit $cur → $want_limit"
                fi
                : # sinon : conforme
            fi ;;
        assign)
            local name="$1" profile="$2"
            local role; role=$(_profile_to_role "$profile")
            [[ -z "$role" ]] && { echo -e "  ${RED}✗ profil inconnu: $profile${NC}"; return; }
            local member; member=$(execute_sql_list "
SELECT 1 FROM pg_auth_members am
JOIN pg_roles u ON u.oid=am.member JOIN pg_roles r ON r.oid=am.roleid
WHERE u.rolname='$(pg_escape_literal "$name")' AND r.rolname='$(pg_escape_literal "$role")';")
            [[ "$member" != "1" ]] && echo -e "  ${GREEN}＋ GRANT${NC} $role → $name (profil $profile)" ;;
        apply)
            echo -e "  ${CYAN}↻ ENSURE${NC} apply ${1:-?}.${2:-?} (${3:-?})  ${WHITE}(idempotent)${NC}" ;;
        *)
            echo -e "  ${YELLOW}? directive inconnue: $kind${NC}" ;;
    esac
    return 0
}

_profile_to_role() {
    case "$1" in
        engineer) echo "$ROLE_DATA_ENGINEER" ;;
        analyst)  echo "$ROLE_DATA_ANALYST" ;;
        bi)       echo "$ROLE_BI_USER" ;;
        service)  echo "$ROLE_SERVICE_ACCOUNT" ;;
        admin)    echo "$ROLE_DB_ADMIN" ;;
        *)        echo "" ;;
    esac
}

# Applique le template d'un profil sur un schéma (dispatcher unifié).
# Seuls engineer|analyst|bi ont un template applicable à un schéma.
rbac_apply_profile() {
    local db="$1" schema="$2" profile="$3"
    case "$profile" in
        engineer) rbac_apply_engineer "$db" "$schema" ;;
        analyst)  rbac_apply_analyst  "$db" "$schema" ;;
        bi)       rbac_apply_bi_user   "$db" "$schema" ;;
        service|admin)
            log_warn "Profil '$profile' non applicable par template sur un schéma."
            log_info  "  → 'service' : droits à accorder manuellement (perm grant-table)."
            log_info  "  → 'admin'   : à assigner à un utilisateur (rbac assign), pas à un schéma." ;;
        *) log_error "Profil inconnu: '$profile' (engineer|analyst|bi)" ;;
    esac
    return 0
}

state_plan() {
    _state_check_manifest || return 1
    log_header "PLAN — différences manifeste → état réel"
    echo -e "${WHITE}Manifeste:${NC} $STATE_MANIFEST\n"
    local tmp; tmp=$(mktemp)
    _state_each _state_plan_line > "$tmp" 2>&1 || true
    if [[ -s "$tmp" ]]; then
        cat "$tmp"
    else
        log_success "Aucune différence — l'état réel est conforme au manifeste."
    fi
    rm -f "$tmp"
}

state_apply() {
    _state_check_manifest || return 1
    log_header "APPLY — réconciliation manifeste → base"
    confirm "Appliquer le manifeste $STATE_MANIFEST sur ${PG_HOST}:${PG_PORT} ?" || { log_info "Annulé"; return 0; }
    _state_each _state_apply_line
    audit_log "STATE_APPLY" "manifest=$STATE_MANIFEST"
    log_success "Réconciliation terminée."
}

_state_apply_line() {
    local kind="$1"; shift
    case "$kind" in
        user)
            local name="$1"; shift
            local profile; profile=$(_state_opt profile "$@")
            local limit;   limit=$(_state_opt conn_limit "$@")
            local exists;  exists=$(execute_sql_list "SELECT 1 FROM pg_roles WHERE rolname='$(pg_escape_literal "$name")';")
            [[ "$exists" != "1" ]] && user_create "$name" "" "${profile:-}"
            [[ -n "$limit" ]] && user_set_conn_limit "$name" "$limit" ;;
        assign)
            rbac_assign_to_user "$1" "$2" ;;
        apply)
            rbac_apply_profile "$1" "$2" "${3:-}" ;;
    esac
    return 0
}

# Détection de dérive : objets présents en base mais absents du manifeste.
state_drift() {
    _state_check_manifest || return 1
    log_header "DRIFT — utilisateurs/droits hors manifeste"

    # Construire la liste des users gérés depuis le manifeste
    local managed; managed=$(grep -E '^[[:space:]]*user[[:space:]]' "$STATE_MANIFEST" 2>/dev/null \
        | awk '{print $2}' | sort -u)
    echo -e "\n${WHITE}── Utilisateurs login présents en base mais ABSENTS du manifeste ──${NC}"
    local live; live=$(execute_sql_list "
SELECT rolname FROM pg_roles
WHERE rolcanlogin AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;")
    local found=false u
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if ! grep -qx "$u" <<< "$managed"; then
            echo -e "  ${YELLOW}⚠ non géré:${NC} $u"
            found=true
        fi
    done <<< "$live"
    [[ "$found" == false ]] && log_success "Aucune dérive utilisateur détectée."
}

# Export de l'état réel vers un manifeste (bootstrap).
state_export() {
    local dbname="${1:-$PG_DEFAULT_DB}"
    validate_identifier "$dbname" "nom de base" || return 1
    mkdir -p "$DESIRED_DIR"
    local out="${DESIRED_DIR}/state.exported.conf"
    log_header "EXPORT état réel → $out"
    {
        echo "# Manifeste généré depuis l'état réel de $dbname le $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Vérifiez puis renommez en state.conf pour le gérer en GitOps."
        echo ""
        echo "# --- Utilisateurs (login) ---"
        execute_sql_list "
SELECT 'user   '||rolname||
       CASE WHEN rolconnlimit >= 0 THEN ' conn_limit='||rolconnlimit ELSE '' END
FROM pg_roles WHERE rolcanlogin AND rolname NOT LIKE 'pg_%' ORDER BY rolname;"
        echo ""
        echo "# --- Assignations de rôles ---"
        execute_sql_list "
SELECT 'assign '||u.rolname||' '||
       CASE r.rolname
         WHEN '$ROLE_DATA_ENGINEER' THEN 'engineer'
         WHEN '$ROLE_DATA_ANALYST'  THEN 'analyst'
         WHEN '$ROLE_BI_USER'       THEN 'bi'
         WHEN '$ROLE_SERVICE_ACCOUNT' THEN 'service'
         WHEN '$ROLE_DB_ADMIN'      THEN 'admin'
         ELSE '# '||r.rolname END
FROM pg_auth_members am
JOIN pg_roles u ON u.oid=am.member
JOIN pg_roles r ON r.oid=am.roleid
WHERE u.rolcanlogin AND u.rolname NOT LIKE 'pg_%'
ORDER BY u.rolname;"
    } > "$out"
    log_success "État exporté : $out"
    log_info "Relisez-le, puis : mv $out $STATE_MANIFEST"
}

# =============================================================================
# AXE 5 — SÉCURITÉ & ROTATION DES MOTS DE PASSE
# =============================================================================

# Enregistre la date de rotation d'un mot de passe (appelé depuis user_change_password).
audit_record_rotation() {
    [[ -z "$AUDIT_DB" ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0
    local u="$1"
    execute_sql "
INSERT INTO audit.password_rotation (username, last_rotated, rotated_by)
VALUES ('$(pg_escape_literal "$u")', now(), current_user)
ON CONFLICT (username) DO UPDATE SET last_rotated = now(), rotated_by = current_user;" \
        "$AUDIT_DB" >/dev/null 2>&1 || true
}

# Audit de sécurité : configurations à risque.
security_audit() {
    local db="${1:-$PG_DEFAULT_DB}"
    validate_identifier "$db" "nom de base" || return 1
    log_header "AUDIT DE SÉCURITÉ — $db"

    echo -e "\n${WHITE}── Superusers (à limiter au strict minimum) ──${NC}"
    execute_sql "
SELECT rolname AS \"Superuser\"
FROM pg_roles WHERE rolsuper AND rolname NOT LIKE 'pg_%' ORDER BY rolname;"

    echo -e "\n${WHITE}── Comptes login SANS date d'expiration ──${NC}"
    execute_sql "
SELECT rolname AS \"Utilisateur\"
FROM pg_roles
WHERE rolcanlogin AND rolvaliduntil IS NULL AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;"

    echo -e "\n${WHITE}── Comptes login avec connexions ILLIMITÉES (conn_limit = -1) ──${NC}"
    execute_sql "
SELECT rolname AS \"Utilisateur\"
FROM pg_roles
WHERE rolcanlogin AND rolconnlimit = -1 AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;"

    echo -e "\n${WHITE}── Comptes login SANS mot de passe (best-effort, superuser requis) ──${NC}"
    execute_sql "
SELECT rolname AS \"Utilisateur\"
FROM pg_authid
WHERE rolcanlogin AND rolpassword IS NULL AND rolname NOT LIKE 'pg_%'
ORDER BY rolname;" 2>/dev/null || log_warn "Lecture de pg_authid impossible (privilège superuser requis)."
}

# Âge des mots de passe (nécessite l'audit en base).
security_password_age() {
    [[ -z "$AUDIT_DB" ]] && { log_error "AUDIT_DB requis : ./pg-admin.sh audit db-init <db> puis export AUDIT_DB=<db>"; return 1; }
    log_header "ÂGE DES MOTS DE PASSE (suivi via l'outil)"
    execute_sql "
SELECT r.rolname AS \"Utilisateur\",
       COALESCE(to_char(pr.last_rotated,'YYYY-MM-DD'),'— jamais —') AS \"Dernière rotation\",
       CASE WHEN pr.last_rotated IS NULL THEN NULL
            ELSE EXTRACT(day FROM now() - pr.last_rotated)::int END AS \"Âge (j)\",
       CASE WHEN pr.last_rotated IS NULL                              THEN '⚠ inconnu'
            WHEN pr.last_rotated < now() - interval '90 days'         THEN '⚠ échu (>90j)'
            ELSE 'ok' END AS \"Statut\"
FROM pg_roles r
LEFT JOIN audit.password_rotation pr ON pr.username = r.rolname
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg_%'
ORDER BY pr.last_rotated NULLS FIRST, r.rolname;" "$AUDIT_DB"
}

# Rotation du mot de passe d'un utilisateur (nouveau mdp généré + credentials sauvegardés).
security_rotate() {
    local u="$1"
    validate_identifier "$u" "nom d'utilisateur" || return 1
    local pw; pw=$(generate_password 24)
    user_change_password "$u" "$pw"          # déclenche l'enregistrement de rotation + audit_log
    _save_credentials "$u" "$pw" "(rotation $(date +%Y-%m-%d))"
    log_success "Mot de passe de '$u' renouvelé."
}

# Rotation en masse des mots de passe échus (> N jours, ou jamais enregistrés).
security_rotate_due() {
    local days="${1:-90}"
    [[ -z "$AUDIT_DB" ]] && { log_error "AUDIT_DB requis : audit db-init <db> puis export AUDIT_DB=<db>"; return 1; }
    [[ "$days" =~ ^[0-9]+$ ]] || { log_error "Nombre de jours invalide: '$days'"; return 1; }

    log_header "ROTATION DES MOTS DE PASSE ÉCHUS (> ${days} j ou jamais enregistrés)"
    # On exclut l'admin courant pour ne pas casser la session en cours.
    local due; due=$(execute_sql_list "
SELECT r.rolname
FROM pg_roles r
LEFT JOIN audit.password_rotation pr ON pr.username = r.rolname
WHERE r.rolcanlogin
  AND r.rolname NOT LIKE 'pg_%'
  AND r.rolname <> '$(pg_escape_literal "$PG_ADMIN_USER")'
  AND (pr.last_rotated IS NULL OR pr.last_rotated < now() - make_interval(days => $days))
ORDER BY r.rolname;" "$AUDIT_DB")

    if [[ -z "$due" ]]; then
        log_success "Aucun mot de passe échu (admin courant '$PG_ADMIN_USER' exclu)."
        return 0
    fi
    echo -e "${WHITE}Comptes concernés :${NC}"
    echo "$due" | sed 's/^/  • /'
    local count; count=$(grep -c . <<< "$due")
    confirm "Renouveler ${count} mot(s) de passe ?" || { log_info "Annulé"; return 0; }

    local u
    while IFS= read -r u; do [[ -n "$u" ]] && security_rotate "$u"; done <<< "$due"
    audit_log "ROTATE_DUE" "days=$days count=$count"
    log_success "Rotation terminée pour $count compte(s). Credentials dans .credentials/"
}

# =============================================================================
# AXE 6 — VÉRIFICATION DE RESTAURATION DES BACKUPS
# =============================================================================
#
# Restaure un dump dans une base jetable, contrôle le contenu, puis la supprime.
# Prouve qu'un backup est réellement restaurable (un backup non testé n'est pas un backup).

backup_verify() {
    local backup_file="${1:-}"
    [[ -z "$backup_file" ]] && { log_error "Usage: backup verify <fichier.sql[.gz]>"; return 1; }
    [[ ! -f "$backup_file" ]] && { log_error "Fichier introuvable: $backup_file"; return 1; }

    local tmpdb="verify_$(date +%Y%m%d_%H%M%S)"
    log_header "VÉRIFICATION DU BACKUP — $(basename "$backup_file")"
    log_info "Base temporaire jetable : $tmpdb"

    if ! execute_sql "CREATE DATABASE \"$tmpdb\";" >/dev/null 2>&1; then
        log_error "Impossible de créer la base temporaire $tmpdb"; return 1
    fi

    # Décompression si nécessaire
    local sql_file="$backup_file" tmp_cleanup=false
    if [[ "$backup_file" == *.gz ]]; then
        sql_file=$(mktemp "${TMPDIR:-/tmp}/verify_XXXXXX.sql"); tmp_cleanup=true
        gunzip -c "$backup_file" > "$sql_file"
    fi

    # Restauration tolérante (ON_ERROR_STOP=0 : on ignore le bruit propriété/role)
    local err_log; err_log=$(mktemp)
    if [[ "$USE_SSH" == "ssh" ]]; then
        _psql_ssh    "$tmpdb" -v ON_ERROR_STOP=0 < "$sql_file" >/dev/null 2>"$err_log" || true
    elif [[ "$USE_SSH" == "docker" ]]; then
        _psql_docker "$tmpdb" -v ON_ERROR_STOP=0 < "$sql_file" >/dev/null 2>"$err_log" || true
    else
        _psql_local  "$tmpdb" -v ON_ERROR_STOP=0 < "$sql_file" >/dev/null 2>"$err_log" || true
    fi
    [[ "$tmp_cleanup" == true ]] && rm -f "$sql_file"

    # Contrôles
    local nschemas ntables errcount
    nschemas=$(execute_sql_list "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT IN ($_SYS_SCHEMAS);" "$tmpdb")
    ntables=$(execute_sql_list  "SELECT count(*) FROM information_schema.tables  WHERE table_schema  NOT IN ($_SYS_SCHEMAS);" "$tmpdb")
    errcount=$(grep -ciE 'ERROR|FATAL' "$err_log" 2>/dev/null || true)
    rm -f "$err_log"

    echo ""
    echo -e "  Schémas restaurés : ${WHITE}${nschemas:-0}${NC}"
    echo -e "  Tables restaurées : ${WHITE}${ntables:-0}${NC}"
    echo -e "  Erreurs psql      : ${WHITE}${errcount:-0}${NC}"

    # Nettoyage de la base jetable
    execute_sql "DROP DATABASE \"$tmpdb\";" >/dev/null 2>&1 \
        || log_warn "Nettoyage : échec DROP $tmpdb (à supprimer manuellement)."

    if [[ "${ntables:-0}" -gt 0 ]]; then
        audit_log "BACKUP_VERIFY_OK" "file=$backup_file tables=$ntables errors=${errcount:-0}"
        log_success "Backup VALIDE — restauration réussie (${ntables} tables, ${errcount:-0} erreur(s))."
        return 0
    else
        audit_log "BACKUP_VERIFY_FAIL" "file=$backup_file"
        log_error "Backup SUSPECT — aucune table restaurée. Inspectez le fichier."
        return 1
    fi
}
