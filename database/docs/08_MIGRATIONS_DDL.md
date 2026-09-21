# Migrations et gestion du DDL

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Principes](#1-principes)
2. [Outils par contexte](#2-outils-par-contexte)
3. [Nommage des fichiers de migration](#3-nommage-des-fichiers-de-migration)
4. [Écrire une migration](#4-écrire-une-migration)
5. [Changements sans interruption](#5-changements-sans-interruption)
6. [Déploiement et CI](#6-déploiement-et-ci)
7. [Documentation du schéma](#7-documentation-du-schéma)

---

## 1. Principes

1. **Le schéma est du code** : tout DDL est versionné dans git, revu en merge request, puis appliqué par la CI.
2. **Aucun DDL manuel** en staging ni en production. Une correction d'urgence est rejouée ensuite dans une migration.
3. **Une migration appliquée ne se modifie jamais** : on en écrit une nouvelle.
4. **Migrations idempotentes** quand l'outil ne trace pas l'état (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`).
5. **Même chaîne de migrations** dans tous les environnements : dev → staging → prod.
6. **Chaque migration est réversible** ou déclare explicitement qu'elle ne l'est pas.

---

## 2. Outils par contexte

| Contexte | Outil recommandé | Emplacement |
|----------|------------------|-------------|
| Application Python (FastAPI, Flask) | **Alembic** (SQLAlchemy) | `<app>/migrations/versions/` |
| Application Django | Migrations Django | `<app>/migrations/` |
| Application Java / multi-langage | Flyway ou Liquibase | `db/migration/` |
| Application Node.js | Prisma Migrate, Knex, TypeORM | `prisma/migrations/` |
| Transformations analytiques | **dbt** (les modèles *sont* le DDL) | `include/dbt/<project>/models/` |
| DDL analytique hors dbt (landing, audit, partitions, rôles) | Flyway ou scripts SQL versionnés | `include/sql/ddl/` |
| Droits et rôles PostgreSQL | `db-analytics-oscrum` (`state.conf`) | `scripts/desired/state.conf` |
| ClickHouse | `clickhouse-migrations`, golang-migrate | `db/clickhouse/` |
| Snowflake | schemachange, Terraform (objets de compte) | `db/snowflake/` |
| BigQuery | Terraform (datasets), dbt (tables) | `infra/` |
| Iceberg | dbt / Spark SQL, Terraform (catalogue) | `include/dbt/`, `infra/` |

---

## 3. Nommage des fichiers de migration

Format Flyway / scripts SQL : `V<YYYYMMDDHHMM>__<verb>_<object>.sql`

```text
include/sql/ddl/
├── V202609160900__create_schema_finance.sql
├── V202609160905__create_table_finance_stg_payment.sql
├── V202609160910__create_table_finance_fact_payment.sql
├── V202609171400__add_column_fact_payment_currency_code.sql
├── V202609181000__create_index_fact_payment_customer_key.sql
└── R__grant_finance_roles.sql          # migration répétable (Flyway)
```

| Verbe | Usage |
|-------|-------|
| `create_schema`, `create_table`, `create_view`, `create_index` | Création |
| `add_column`, `add_constraint` | Ajout |
| `alter_column` | Changement de type, de nullabilité ou de valeur par défaut |
| `rename_column`, `rename_table` | Renommage |
| `drop_column`, `drop_table`, `drop_index` | Suppression |
| `backfill` | Migration de données |
| `grant` | Droits |

Alembic : `alembic revision -m "add_column_invoice_currency_code"`, avec un horodatage dans le nom de fichier (`file_template = %%(year)d%%(month).2d%%(day).2d_%%(hour).2d%%(minute).2d_%%(slug)s` dans `alembic.ini`).

---

## 4. Écrire une migration

```sql
-- V202609160910__create_table_finance_fact_payment.sql
-- Ticket : DATA-123
-- Auteur : jean.effi
-- Réversible : oui (DROP TABLE finance.fact_payment)

CREATE TABLE IF NOT EXISTS finance.fact_payment (
    payment_key         BIGINT GENERATED ALWAYS AS IDENTITY,
    payment_date_key    INTEGER       NOT NULL,
    customer_key        BIGINT        NOT NULL,
    payment_method_key  BIGINT        NOT NULL,
    payment_number      VARCHAR(30)   NOT NULL,
    paid_amount         NUMERIC(18,2) NOT NULL,
    currency_code       CHAR(3)       NOT NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    loaded_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    batch_id            VARCHAR(250)  NOT NULL,
    CONSTRAINT pk_fact_payment PRIMARY KEY (payment_key),
    CONSTRAINT uq_fact_payment_payment_number UNIQUE (payment_number)
);

COMMENT ON TABLE finance.fact_payment IS 'Grain : 1 ligne par paiement reçu. Source : Sage.';
COMMENT ON COLUMN finance.fact_payment.paid_amount IS 'Montant encaissé TTC, dans currency_code';
```

Règles :

- **Une migration = un changement logique.** Pas de création de table et de backfill de données dans le même fichier.
- **Toujours schéma-qualifier** les objets (`finance.fact_payment`), ne jamais dépendre du `search_path`.
- **Toujours commenter** tables et colonnes (`COMMENT ON`), en français.
- **Délai de verrouillage** en tête de migration pour ne pas bloquer la production : `SET lock_timeout = '5s';`
- **Migrations de données** par lots, avec reprise possible.
- Tester la montée **et** la descente en local avant la merge request.

---

## 5. Changements sans interruption

Les changements cassants se font en **plusieurs déploiements** (patron *expand / contract*).

| Changement | Étapes |
|------------|--------|
| Ajouter une colonne | `ADD COLUMN` nullable ou avec `DEFAULT` constant (instantané en PostgreSQL 11+) → code → `SET NOT NULL` si besoin (via `CHECK … NOT VALID` puis `VALIDATE`) |
| Renommer une colonne | 1. Ajouter la nouvelle colonne 2. Écrire dans les deux 3. Backfill 4. Lire la nouvelle 5. Arrêter d'écrire l'ancienne 6. Supprimer l'ancienne |
| Changer un type | Même procédure que le renommage (nouvelle colonne) ; éviter `ALTER COLUMN TYPE` qui réécrit la table |
| Supprimer une colonne | 1. Retirer du code (et des `SELECT *`) 2. Déployer 3. `DROP COLUMN` |
| Renommer une table | Nouvelle table + vue de compatibilité avec l'ancien nom pendant une version |
| Créer un index sur une grande table | `CREATE INDEX CONCURRENTLY` (PostgreSQL), `ONLINE = ON` (SQL Server, Oracle), `ALGORITHM=INPLACE, LOCK=NONE` (MySQL) |
| Ajouter une FK | `ADD CONSTRAINT … NOT VALID` puis `VALIDATE CONSTRAINT` |
| Ajouter une contrainte d'unicité | `CREATE UNIQUE INDEX CONCURRENTLY` puis `ADD CONSTRAINT … UNIQUE USING INDEX` |

Opérations **interdites** en production sans fenêtre de maintenance : `VACUUM FULL`, `CLUSTER`, `ALTER TABLE … SET TABLESPACE`, `ALTER COLUMN TYPE` sur une grande table, `CREATE INDEX` sans `CONCURRENTLY`.

Moteurs analytiques :

- **Snowflake / BigQuery** : `ALTER TABLE ADD COLUMN` et le renommage sont instantanés ; un changement de type se fait par recréation (`CREATE OR REPLACE TABLE … AS SELECT`) dans une fenêtre dédiée.
- **ClickHouse** : `ALTER TABLE … ADD COLUMN` est instantané ; `MODIFY COLUMN` et `UPDATE`/`DELETE` sont des *mutations* asynchrones et coûteuses. Surveiller `system.mutations`.
- **Iceberg** : ajout, renommage, suppression et élargissement de type sont des opérations de métadonnées. Ne jamais réutiliser le nom d'une colonne supprimée pour une donnée différente sans vérifier les lecteurs.

---

## 6. Déploiement et CI

| Étape | Contrôle |
|-------|----------|
| Pre-commit | `sqlfluff lint` (dialecte du projet), validation des noms (`orchestration.db.naming`) |
| Merge request | Revue par un pair avec la [CHECKLIST.md](CHECKLIST.md) ; revue DBA pour tout changement en production sur une table > 1 Go |
| CI | Application des migrations sur une base éphémère (conteneur), puis tests |
| Staging | Application automatique, contrôle de la durée d'exécution |
| Production | Application par la CI avec le compte `svc_<app>_migration`, après sauvegarde vérifiée |
| Après déploiement | `ANALYZE` des tables modifiées, vérification des journaux |

Exemple de configuration `sqlfluff` (`.sqlfluff`) :

```ini
[sqlfluff]
dialect = postgres
templater = jinja
max_line_length = 120

[sqlfluff:rules:capitalisation.keywords]
capitalisation_policy = upper

[sqlfluff:rules:capitalisation.identifiers]
extended_capitalisation_policy = lower
```

---

## 7. Documentation du schéma

- **Commentaires SQL** sur chaque table et colonne : la base est la première source de documentation.
- **Diagramme** généré (SchemaSpy, dbdocs, DBeaver, `dbt docs`) à chaque version, jamais dessiné à la main puis oublié.
- **Catalogue de données** (OpenMetadata, DataHub) : propriétaire, domaine, classification, lignage.
- **Changelog** : chaque migration notable est citée dans le `CHANGELOG.md` du projet.
