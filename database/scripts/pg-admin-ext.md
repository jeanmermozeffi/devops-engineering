# pg-admin — Extensions DBA (v3.1)

> Complément à [pg-admin.md](pg-admin.md). Décrit les 4 axes ajoutés par
> [`pg-admin-ext.sh`](pg-admin-ext.sh), sourcé automatiquement par `pg-admin.sh`.

| Axe | Commandes | But |
|---|---|---|
| Matrice & relations | `perm matrix` / `who-can` / `what-can` / `tree` | Voir et tracer les liens user↔bd↔table |
| Traçabilité en base | `audit db-init` / `report` / `diff` | Audit structuré, requêtable, avec diff avant/après |
| GitOps déclaratif | `state plan` / `apply` / `drift` / `export` | Gérer les droits comme du code versionné |
| Monitoring DBA | `monitor health` / `bloat` / `top` / `cache` / `vacuum` / … | Diagnostic de santé approfondi |
| Sécurité & rotation | `security audit` / `password-age` / `rotate` / `rotate-due` | Détecter les risques, renouveler les mots de passe |
| Vérification backup | `backup verify` | Prouver qu'un backup est réellement restaurable |

---

## 1. Matrice des droits & relations user ↔ bd

Répond à la question « qui est lié à quelle base, et avec quels droits réels ? ».
Les droits affichés sont **effectifs** : ils tiennent compte de l'héritage de rôles
(via `has_table_privilege`, `has_database_privilege`).

```bash
# Vue d'ensemble : user↔bases (CONNECT) + user×schémas (USAGE/CREATE + tables lisibles)
./pg-admin.sh perm matrix db_analytics_oscrum

# Recherche INVERSÉE : qui peut accéder à cette table ?
./pg-admin.sh perm who-can db_analytics_oscrum marts mart_ventes

# Recherche DIRECTE : que peut toucher cet utilisateur ?
./pg-admin.sh perm what-can alice db_analytics_oscrum

# Arbre d'appartenance aux rôles
./pg-admin.sh perm tree alice
```

En interactif : menu **5 › Permissions granulaires**, options 5 à 8.

---

## 2. Traçabilité / audit en base

En plus du log fichier (`logs/audit-*.log`) et du **miroir JSONL** (`logs/audit-*.jsonl`),
les actions peuvent être enregistrées **dans la base** (schéma `audit`), ce qui les rend
centralisées, requêtables en SQL et résistantes à la perte du poste local.

```bash
# 1. Créer le schéma audit (une fois) — tables action_log + acl_snapshot
./pg-admin.sh audit db-init db_analytics_oscrum

# 2. Activer l'enregistrement automatique pour la session
export AUDIT_DB=db_analytics_oscrum

# 3. Toute action est désormais tracée en base. Consulter :
./pg-admin.sh audit report db_analytics_oscrum
./pg-admin.sh audit report db_analytics_oscrum --html   # → logs/audit-report-*.html

# 4. Diff avant/après des droits d'un utilisateur (2 derniers instantanés)
./pg-admin.sh audit diff alice
```

**Diff avant/après** : à chaque `perm grant/revoke/grant-table` et `rbac assign/revoke`,
un instantané des droits effectifs de l'utilisateur est enregistré dans `audit.acl_snapshot`.
`audit diff` compare les deux derniers → rôles ajoutés (＋) / retirés (－).

Tables créées :

| Table | Contenu |
|---|---|
| `audit.action_log` | ts, os_user, pg_user, client_host, action, target, detail (jsonb), dry_run, success |
| `audit.acl_snapshot` | ts, username, dbname, snapshot (jsonb : rôles + tables accessibles) |

> L'écriture en base est **best-effort** : si `AUDIT_DB` n'est pas défini ou si l'insertion
> échoue, l'action principale n'est jamais bloquée. Désactivé en `--dry-run`.

---

## 3. GitOps — état déclaré (plan / apply / drift)

Gérer les droits comme du code : un manifeste versionné décrit l'état **voulu**,
l'outil calcule le diff (`plan`), applique (`apply`), et détecte les écarts (`drift`).

Manifeste : `desired/state.conf` (voir [state.conf.example](desired/state.conf.example)).

```ini
user   alice   profile=analyst conn_limit=5
user   svc_etl profile=service
assign alice   analyst
apply  db_analytics_oscrum dwh   analyst
apply  db_analytics_oscrum marts bi
```

```bash
# Générer un manifeste depuis l'état réel (bootstrap)
./pg-admin.sh state export db_analytics_oscrum     # → desired/state.exported.conf

# Voir ce qui changerait, sans rien modifier
./pg-admin.sh state plan

# Réconcilier la base sur le manifeste (idempotent, demande confirmation)
./pg-admin.sh state apply

# Détecter la dérive : users login en base mais absents du manifeste (utile en CI)
./pg-admin.sh state drift
```

Surcharger le chemin du manifeste : `STATE_MANIFEST=/chemin/state.conf ./pg-admin.sh state plan`.
En interactif : menu **10 › GitOps / État déclaré**.

---

## 4. Monitoring DBA avancé

Diagnostic de santé approfondi, lecture seule.

```bash
./pg-admin.sh monitor health          # tableau de bord (cache, connexions, locks, top dead)
./pg-admin.sh monitor bloat           # tables avec lignes mortes (% mort)
./pg-admin.sh monitor unused-indexes  # index jamais scannés (à supprimer ?)
./pg-admin.sh monitor index-usage     # ratio seq scan vs index scan
./pg-admin.sh monitor top db 20       # top requêtes (pg_stat_statements)
./pg-admin.sh monitor cache           # cache hit ratio (cible > 99%)
./pg-admin.sh monitor vacuum          # état autovacuum / dernier vacuum
./pg-admin.sh monitor long-tx         # transactions > 30s / idle-in-transaction
```

> `monitor top` nécessite l'extension `pg_stat_statements`
> (`shared_preload_libraries` + `CREATE EXTENSION`). Le script le signale si absente.

En interactif : menu **8 › Monitoring**, options 6 à 12.

---

## 5. Sécurité & rotation des mots de passe

```bash
# Audit des configurations à risque (pas besoin d'AUDIT_DB)
./pg-admin.sh security audit db_analytics_oscrum
#   → superusers, comptes sans expiration, connexions illimitées, comptes sans mot de passe

# Suivi de l'âge des mots de passe (nécessite l'audit en base)
export AUDIT_DB=db_analytics_oscrum
./pg-admin.sh security password-age

# Renouveler un mot de passe (nouveau mdp généré + credentials sauvegardés)
./pg-admin.sh security rotate alice

# Renouveler en masse tous les mdp échus (> 90 j ou jamais enregistrés)
./pg-admin.sh --yes security rotate-due 90
```

- La date de rotation est enregistrée dans `audit.password_rotation` à chaque `user passwd`
  ou `security rotate` (si `AUDIT_DB` est défini).
- `rotate-due` **exclut l'admin courant** (`PG_ADMIN_USER`) pour ne pas casser la session.
- Les nouveaux credentials sont écrits dans `.credentials/<user>_*.txt` (chmod 600).

En interactif : menu **6 › Audit** (options 8/9), menu **3 › Utilisateurs** (option 10 = rotation des échus).

## 6. Vérification de restauration des backups

> Un backup non testé n'est pas un backup. `backup verify` le restaure dans une base
> **jetable**, contrôle le contenu, puis la supprime.

```bash
./pg-admin.sh backup verify /tmp/db_analytics_oscrum_20260605_001512.sql.gz
```

Sortie : nombre de schémas/tables restaurés + nombre d'erreurs psql, puis verdict
**VALIDE** / **SUSPECT**. La base temporaire `verify_<timestamp>` est toujours supprimée
à la fin. Quelques erreurs de *rôle/ownership* sont normales (le dump référence des rôles
absents de l'instance de test) — le verdict se base sur le nombre de tables réellement restaurées.

En interactif : menu **7 › Backup**, option 3.

## Sécurité — rappel

Les fichiers de secrets du dépôt (`.devops.yml`, `.env`, `acces.json`) sont désormais
couverts par le `.gitignore` racine et passés en `chmod 600`. Des modèles publics
`*.example` sont fournis. **Pensez à révoquer/régénérer** tout token qui a été exposé en clair.

---

*pg-admin-ext.sh — extensions v3.1 — CICBI*
