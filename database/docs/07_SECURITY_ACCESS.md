# Sécurité et gestion des accès

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Principes](#1-principes)
2. [Modèle de rôles](#2-modèle-de-rôles)
3. [Comptes de service](#3-comptes-de-service)
4. [Mise en œuvre PostgreSQL](#4-mise-en-œuvre-postgresql)
5. [Équivalents dans les autres moteurs](#5-équivalents-dans-les-autres-moteurs)
6. [Données personnelles et sensibles](#6-données-personnelles-et-sensibles)
7. [Réseau, chiffrement et secrets](#7-réseau-chiffrement-et-secrets)
8. [Sauvegarde et restauration](#8-sauvegarde-et-restauration)
9. [Audit des accès](#9-audit-des-accès)

---

## 1. Principes

1. **Moindre privilège** : chacun reçoit uniquement les droits nécessaires à sa tâche.
2. **Droits donnés à des rôles, jamais à des personnes** : un utilisateur hérite d'un ou plusieurs rôles.
3. **Propriétaire des objets distinct** des comptes qui les utilisent : `owner_<database>` possède les objets ; ni les applications ni Airflow ne sont propriétaires.
4. **Aucun accès en écriture humaine en production** hors procédure d'urgence tracée.
5. **Droits déclarés et versionnés** (GitOps) : l'état voulu est dans `scripts/desired/state.conf` et appliqué par `pg-admin.sh state apply`.
6. **Revue des accès** chaque trimestre (`pg-admin.sh state drift`).

---

## 2. Modèle de rôles

### 2.1 Rôles par profil (existants dans `db-analytics-oscrum`)

| Rôle | Profil | Droits |
|------|--------|--------|
| `role_db_admin` | Administrateur | Tous les droits sur la base |
| `role_data_engineer` | Data engineer | DDL + DML sur `landing`, `staging`, `dwh`, domaines, `marts` |
| `role_data_analyst` | Analyste | `SELECT` sur `dwh`, domaines (couches `dim_`/`fact_`), `marts` ; écriture sur `sandbox` |
| `role_bi_user` | Outil BI, utilisateur métier | `SELECT` sur `marts` uniquement |
| `role_service_account` | Compte technique | Aucun droit par défaut, attribution explicite |

### 2.2 Rôles par domaine (plateforme multi-domaines)

| Rôle | Droits |
|------|--------|
| `role_<domain>_read` | `USAGE` + `SELECT` sur le schéma du domaine |
| `role_<domain>_write` | `role_<domain>_read` + `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` |
| `role_<domain>_owner` | Création d'objets dans le schéma (pipelines de déploiement uniquement) |

Exemple : un analyste finance reçoit `role_data_analyst` + `role_finance_read` ; il ne voit pas `hr`.

### 2.3 Matrice couche × profil

| Schéma | admin | engineer | analyst | bi | Airflow (`svc_airflow`) | Application |
|--------|:-----:|:--------:|:-------:|:--:|:-----------------------:|:-----------:|
| `landing` | ALL | RW | — | — | RW | — |
| `staging` | ALL | RW | — | — | RW | — |
| `dwh` / domaine | ALL | RW | R | — | RW | — |
| `marts` | ALL | RW | R | R | RW | R (API de restitution) |
| `audit` | ALL | R | R | — | W (insertion) | — |
| `sandbox` | ALL | RW | RW | — | — | — |
| Schéma applicatif | ALL | — | — | — | R (réplique) | RW |

---

## 3. Comptes de service

| Compte | Usage | Droits |
|--------|-------|--------|
| `svc_airflow` | DAG d'ingestion et de transformation | Écriture sur les couches analytiques, jamais DDL en production (sauf `tmp_`) |
| `svc_dbt` | Exécution dbt | Création dans les schémas cibles dbt |
| `svc_<app>_api` | Back-end applicatif (FastAPI…) | DML sur le schéma applicatif ; aucun DDL |
| `svc_<app>_migration` | Migrations (Alembic, Flyway) lancées par la CI | DDL sur le schéma applicatif, `SET ROLE owner_<database>` |
| `svc_metabase`, `svc_superset`, `svc_powerbi` | Outils BI | `role_bi_user` |
| `svc_<app>_readonly` | Extraction par Airflow depuis une base applicative | `SELECT` sur les tables extraites, idéalement sur une réplique |

Règles :

- **Un compte par application et par usage**, jamais partagé.
- `CONNECTION LIMIT` défini (ex. 20 pour une API, 10 pour Airflow).
- `statement_timeout` et `idle_in_transaction_session_timeout` définis au niveau du rôle.
- Mot de passe généré (32 caractères), stocké dans le gestionnaire de secrets, **rotation tous les 90 jours**.
- Les connexions Airflow se déclarent dans `config/connections.yaml` avec des variables d'environnement, jamais en clair (voir `docs/DATA_ENGINEERING_BEST_PRACTICES.md` §7 du template Airflow (`airflow-plateforme-template`)).

---

## 4. Mise en œuvre PostgreSQL

```sql
-- Durcissement initial (une fois par base)
REVOKE ALL ON DATABASE analytics FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Propriétaire des objets (pas de LOGIN)
CREATE ROLE owner_analytics NOLOGIN;
CREATE SCHEMA finance AUTHORIZATION owner_analytics;

-- Rôles de domaine
CREATE ROLE role_finance_read NOLOGIN;
CREATE ROLE role_finance_write NOLOGIN IN ROLE role_finance_read;

GRANT CONNECT ON DATABASE analytics TO role_finance_read;
GRANT USAGE ON SCHEMA finance TO role_finance_read;
GRANT SELECT ON ALL TABLES IN SCHEMA finance TO role_finance_read;
GRANT INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA finance TO role_finance_write;

-- Droits sur les objets créés plus tard par le propriétaire
ALTER DEFAULT PRIVILEGES FOR ROLE owner_analytics IN SCHEMA finance
    GRANT SELECT ON TABLES TO role_finance_read;
ALTER DEFAULT PRIVILEGES FOR ROLE owner_analytics IN SCHEMA finance
    GRANT INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO role_finance_write;

-- Compte de service
CREATE ROLE svc_airflow LOGIN CONNECTION LIMIT 10 IN ROLE role_finance_write;
ALTER ROLE svc_airflow SET statement_timeout = '2h';
ALTER ROLE svc_airflow SET idle_in_transaction_session_timeout = '10min';
```

Avec `db-analytics-oscrum`, ces opérations se font via :

```bash
./pg-admin.sh rbac apply db-analytics-oscrum finance engineer
```

Row Level Security (multi-tenant, filtrage par entité) :

```sql
ALTER TABLE billing.invoice ENABLE ROW LEVEL SECURITY;
CREATE POLICY rls_invoice_tenant ON billing.invoice
    USING (tenant_id = current_setting('app.tenant_id')::BIGINT);
```

---

## 5. Équivalents dans les autres moteurs

| Moteur | Rôle groupe | Droits par défaut sur futurs objets | Filtrage par ligne | Masquage |
|--------|-------------|--------------------------------------|--------------------|----------|
| MySQL 8 | `CREATE ROLE` + `SET DEFAULT ROLE` | Droits au niveau `schema.*` | Vues | Vues / plugin Enterprise |
| SQL Server | Rôle de base de données | Droits au niveau `SCHEMA::` | Row-Level Security | Dynamic Data Masking |
| Oracle | `CREATE ROLE` ; utilisateur = schéma | Schema-level privileges (23ai) | VPD / Real Application Security | Data Redaction |
| ClickHouse | `CREATE ROLE` | Droits sur `database.*` | `ROW POLICY` | Vues, fonctions de masquage |
| Snowflake | Rôles d'accès + rôles fonctionnels | `FUTURE GRANTS` | Row access policy | Masking policy, tags |
| BigQuery | IAM (rôles sur projet/dataset/table) | Hérité du dataset | Row-level access policy | Policy tags (Data Catalog) |
| Iceberg | Selon catalogue (Polaris, Unity, Lake Formation, Ranger) | Selon catalogue | Selon moteur | Selon moteur |

---

## 6. Données personnelles et sensibles

### 6.1 Classification

Chaque colonne est classée dans le catalogue et dans le commentaire SQL :

| Niveau | Exemples | Mesures |
|--------|----------|---------|
| `public` | Libellé produit, code pays | Aucune |
| `internal` | Montants agrégés, statuts | Accès authentifié |
| `confidential` | Nom, e-mail, téléphone, adresse | Rôles restreints, masquage hors production |
| `restricted` | Numéro de pièce d'identité, salaire, santé, données bancaires, mots de passe | Chiffrement, accès nominatif et journalisé, pseudonymisation dans le DWH |

```sql
COMMENT ON COLUMN hr.dim_employee.national_id IS '[restricted] Numéro CNI — pseudonymisé';
```

### 6.2 Règles

- **Mots de passe** : jamais stockés, uniquement leur empreinte (Argon2id ou bcrypt), calculée par l'application.
- **Données bancaires** : ne pas les stocker (déléguer au prestataire de paiement) ; sinon, chiffrement et périmètre PCI DSS.
- **DWH** : pseudonymiser les identifiants directs (`sha256(salt || email)`) sauf besoin métier documenté.
- **Hors production** : jeux de données **anonymisés** ou synthétiques ; jamais de copie brute de la production.
- **Droit à l'effacement** : prévoir la procédure (suppression ou anonymisation) dans toutes les couches, y compris `landing` et les archives.
- Respect de la loi ivoirienne n° 2013-450 relative à la protection des données à caractère personnel (ARTCI), et du RGPD pour les personnes concernées dans l'UE.

---

## 7. Réseau, chiffrement et secrets

| Mesure | Règle |
|--------|-------|
| Exposition | Base jamais exposée sur Internet ; accès par réseau privé, VPN ou bastion SSH (mode `ssh` de `pg-admin.sh`) |
| Chiffrement en transit | TLS obligatoire (`sslmode=verify-full` côté client, `hostssl` dans `pg_hba.conf`) |
| Chiffrement au repos | Disque chiffré (LUKS, volume cloud chiffré) ; TDE pour SQL Server et Oracle si exigé |
| Authentification | `scram-sha-256` (PostgreSQL) ; jamais `trust` ni `md5` |
| Secrets | Gestionnaire de secrets ou variables CI protégées ; jamais dans git (`detect-secrets` en pre-commit) |
| Comptes par défaut | `postgres`, `sa`, `root`, `SYSTEM` désactivés pour l'usage courant |

---

## 8. Sauvegarde et restauration

| Élément | Règle |
|---------|-------|
| Méthode | Sauvegarde physique + archivage WAL (PITR) pour PostgreSQL (`pgBackRest`, `barman`) ; `pg_dump` en complément par schéma |
| Fréquence | Complète hebdomadaire, différentielle quotidienne, WAL en continu |
| RPO / RTO cibles | Production : RPO ≤ 15 min, RTO ≤ 4 h (à ajuster par projet) |
| Rétention | 30 jours minimum |
| Emplacement | Hors du serveur de base, sur un autre site ou stockage objet, chiffré |
| **Test de restauration** | **Mensuel**, résultat consigné dans `audit` |
| Commande `db-analytics-oscrum` | `./pg-admin.sh backup <db> [répertoire]` et `./pg-admin.sh restore <db> <fichier.sql.gz>` : sauvegarde **logique**, complémentaire de la sauvegarde physique, pas un substitut au PITR |

Une sauvegarde qui n'a jamais été restaurée n'est pas une sauvegarde.

---

## 9. Audit des accès

- PostgreSQL : extension `pgaudit` sur les schémas `restricted` et pour les commandes DDL et `ROLE`.
- Journaliser les connexions (`log_connections`, `log_disconnections`) et les échecs d'authentification.
- Conserver les journaux d'audit **1 an** hors du serveur de base.
- `db-analytics-oscrum` produit ses propres journaux dans `scripts/logs/audit-*.jsonl` : les centraliser.
