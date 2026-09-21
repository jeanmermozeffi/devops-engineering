# Guide de gestion des bases de données

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

Ce dossier est la **référence unique** du pôle Data pour concevoir, nommer, typer, sécuriser et faire évoluer une base de données. Il s'applique à :

- **Bases analytiques** : Data Warehouse, data marts, lakehouse (PostgreSQL, ClickHouse, Snowflake, BigQuery, Apache Iceberg).
- **Bases applicatives** (OLTP) : back-ends FastAPI, Django, Spring, NestJS, etc. (PostgreSQL, MySQL/MariaDB, SQL Server, Oracle).
- **Bases sources** que nous lisons sans les maîtriser : ces documents servent alors à anticiper les pièges de types et de limites lors de l'extraction.

La même documentation est maintenue dans le template Airflow `airflow-plateforme-template` (dossier `src/docs/database/`). Toute modification doit être reportée des deux côtés.

---

## Navigation

| Je veux… | Lire… |
|----------|-------|
| Nommer une base, un schéma, une table, une colonne, un index | [01_NAMING.md](01_NAMING.md) |
| Organiser les couches et les domaines, modéliser un DWH ou une base applicative | [02_ARCHITECTURE_LAYERS.md](02_ARCHITECTURE_LAYERS.md) |
| Choisir le bon type de colonne, convertir entre SGBD | [03_DATA_TYPES.md](03_DATA_TYPES.md) |
| Connaître les limites techniques et les plafonds internes (colonnes max…) | [04_LIMITS_BY_DBMS.md](04_LIMITS_BY_DBMS.md) |
| Définir clés, index et contraintes | [05_KEYS_INDEXES_CONSTRAINTS.md](05_KEYS_INDEXES_CONSTRAINTS.md) |
| Partitionner, optimiser, gérer la rétention | [06_PARTITIONING_PERFORMANCE.md](06_PARTITIONING_PERFORMANCE.md) |
| Gérer les rôles, les droits et les données personnelles | [07_SECURITY_ACCESS.md](07_SECURITY_ACCESS.md) |
| Versionner et déployer le DDL (migrations) | [08_MIGRATIONS_DDL.md](08_MIGRATIONS_DDL.md) |
| Vérifier une table avant de la créer | [CHECKLIST.md](CHECKLIST.md) |
| Partir d'un modèle DDL | [templates/](templates/) |

---

## Les 10 règles à retenir

1. **Anglais, `snake_case`, minuscules, sans accent ni guillemets** pour tous les objets. Le français reste la langue de la documentation et des commentaires (`COMMENT ON`).
2. **Nom complet = `<schema>.<table>`**. Le schéma est soit un **domaine métier** (`finance`, `hr`, `sales`, `billing`), soit une **couche transverse** (`landing`, `staging`, `dwh`, `marts`, `audit`).
3. **Tables analytiques préfixées par leur rôle** : `raw_`, `stg_`, `int_`, `dim_`, `fact_`, `bridge_`, `agg_`, `mart_`, `snp_`, `audit_`. Exemple : `finance.fact_payment`.
4. **Tables applicatives sans préfixe**, au **singulier** : `billing.invoice`, `auth.user_account`.
5. **Identifiants de 30 caractères au plus** (plafond interne portable). Au-delà, la base peut tronquer silencieusement (PostgreSQL à 63 octets).
6. **Montants en décimal exact** (`NUMERIC(18,2)` ou `NUMERIC(19,4)`), jamais en `FLOAT`/`REAL`.
7. **Horodatages en UTC avec fuseau** (`TIMESTAMPTZ`) et suffixe `_at`. Les dates sans heure utilisent le suffixe `_date`.
8. **Chaque table possède une clé primaire** (clé technique `<entity>_id` ou `<entity>_key` en DWH) **et les colonnes techniques standard** (`created_at`, `updated_at`, `loaded_at`, `batch_id`).
9. **Aucun DDL manuel en staging ni en prod** : tout passe par une migration versionnée et revue.
10. **Moindre privilège** : les applications et Airflow utilisent des comptes de service dédiés, jamais le propriétaire des objets.

---

## Vérification automatique

Les règles de nommage sont vérifiables avec le module Python `orchestration/db/naming.py` du template Airflow (`validate_table_name`, `validate_column_name`). Il ne dépend que de la bibliothèque standard : il peut être copié tel quel dans un autre projet.

---

## Sources officielles

Les limites techniques citées ont été vérifiées le 16 septembre 2026 dans :

- PostgreSQL : <https://www.postgresql.org/docs/current/limits.html>
- MySQL 8.4 : <https://dev.mysql.com/doc/refman/8.4/en/column-count-limit.html>, <https://dev.mysql.com/doc/refman/8.4/en/identifier-length.html>
- SQL Server : <https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server>
- Oracle : <https://docs.oracle.com/en/database/oracle/oracle-database/23/refrn/logical-database-limits.html>
- Snowflake : <https://docs.snowflake.com/en/sql-reference/data-types-text>
- BigQuery : <https://cloud.google.com/bigquery/quotas>, <https://cloud.google.com/bigquery/docs/schemas>
- ClickHouse : <https://clickhouse.com/docs/en/sql-reference/data-types>
- Apache Iceberg : <https://iceberg.apache.org/spec/>
