# Partitionnement, performance et rétention

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Quand partitionner](#1-quand-partitionner)
2. [Partitionnement par moteur](#2-partitionnement-par-moteur)
3. [Écriture de requêtes performantes](#3-écriture-de-requêtes-performantes)
4. [Maintenance](#4-maintenance)
5. [Rétention et archivage](#5-rétention-et-archivage)
6. [Supervision](#6-supervision)

---

## 1. Quand partitionner

Partitionner **seulement si au moins une condition est vraie** (seuils détaillés dans [04_LIMITS_BY_DBMS.md §4](04_LIMITS_BY_DBMS.md#4-seuils-de-volumétrie)) :

- la table dépasse 50 millions de lignes ou 20 Go ;
- les requêtes filtrent presque toujours sur la même colonne (date de l'événement) ;
- des données doivent être purgées ou archivées par période ;
- les chargements remplacent une période entière (`DELETE` + `INSERT` d'une journée).

Un partitionnement inutile **ralentit** les requêtes qui ne filtrent pas sur la clé.

| Stratégie | Clé typique | Usage |
|-----------|-------------|-------|
| Par intervalle (range) | Date de l'événement (`paid_at`, `event_date`) | Faits, journaux, audit — cas le plus courant |
| Par liste | `country_code`, `tenant_id` | Petit nombre de valeurs stables |
| Par hachage | `customer_id` | Répartition uniforme sans critère temporel |

Granularité : **mois** par défaut ; **jour** au-delà de ~10 Go par mois ; **année** en dessous de ~1 Go par mois.

---

## 2. Partitionnement par moteur

### PostgreSQL

```sql
CREATE TABLE finance.fact_payment (
    payment_key      BIGINT GENERATED ALWAYS AS IDENTITY,
    paid_at          TIMESTAMPTZ   NOT NULL,
    customer_key     BIGINT        NOT NULL,
    paid_amount      NUMERIC(18,2) NOT NULL,
    loaded_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    batch_id         VARCHAR(250)  NOT NULL,
    CONSTRAINT pk_fact_payment PRIMARY KEY (payment_key, paid_at)
) PARTITION BY RANGE (paid_at);

CREATE TABLE finance.fact_payment_p2026_09
    PARTITION OF finance.fact_payment
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

CREATE TABLE finance.fact_payment_default
    PARTITION OF finance.fact_payment DEFAULT;
```

- La clé de partition **fait partie de la clé primaire**.
- Partitions nommées `<table>_pYYYY_MM` (ou `_pYYYY_MM_DD`, `_pYYYY`) et `<table>_default`.
- Créer les partitions **à l'avance** (3 mois) avec `pg_partman` ou un DAG de maintenance. Une partition `DEFAULT` pleine empêche d'attacher la bonne partition plus tard : la surveiller.
- Archiver = `ALTER TABLE … DETACH PARTITION … CONCURRENTLY`.

### MySQL

- `PARTITION BY RANGE COLUMNS (paid_date)`. La clé de partition doit faire partie de **toutes** les clés uniques.
- Les FK ne sont pas supportées sur les tables partitionnées InnoDB.

### SQL Server

- Fonction + schéma de partition (`pf_monthly`, `ps_monthly`), index cluster columnstore aligné sur le schéma de partition.
- Purge par `TRUNCATE TABLE … WITH (PARTITIONS (n))` ou `SWITCH`.

### Oracle

- Partitionnement par intervalle automatique : `PARTITION BY RANGE (paid_at) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))`.
- Index **locaux** de préférence (maintenance par partition).
- Le partitionnement est une option payante de l'édition Enterprise : vérifier la licence.

### ClickHouse

```sql
CREATE TABLE finance.fact_payment
(
    paid_at       DateTime64(6, 'UTC'),
    customer_id   UInt64,
    payment_type  LowCardinality(String),
    paid_amount   Decimal(18, 2),
    loaded_at     DateTime64(6, 'UTC') DEFAULT now64(6)
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(paid_at)
ORDER BY (customer_id, paid_at)
TTL toDateTime(paid_at) + INTERVAL 5 YEAR;
```

- Partition **mensuelle** au plus fin : le partitionnement sert à la gestion (purge, TTL), pas à accélérer les requêtes. C'est `ORDER BY` qui accélère.
- Moins de 1 000 partitions par table ; insérer par lots (≥ 10 000 lignes ou ≥ 1 seconde entre les lots) pour éviter l'erreur `Too many parts`.

### Snowflake

- Micro-partitionnement automatique. Définir une **clé de clustering** seulement pour les tables > 1 To avec des filtres récurrents ; suivre `SYSTEM$CLUSTERING_INFORMATION`.

### BigQuery

- `PARTITION BY DATE(paid_at)` + `CLUSTER BY customer_id, payment_type`.
- Activer `require_partition_filter = TRUE` sur les grandes tables pour interdire les scans complets (coût).
- 10 000 partitions maximum : partition quotidienne = ~27 ans.

### Apache Iceberg

```sql
CREATE TABLE finance.fact_payment (
    paid_at       TIMESTAMP,
    customer_id   BIGINT,
    paid_amount   DECIMAL(18, 2)
)
USING iceberg
PARTITIONED BY (days(paid_at), bucket(16, customer_id))
TBLPROPERTIES ('format-version' = '2', 'write.target-file-size-bytes' = '268435456');
```

- Partitionnement **caché** : les requêtes filtrent sur `paid_at`, pas sur une colonne dérivée.
- La spécification de partition peut évoluer sans réécrire les données.

---

## 3. Écriture de requêtes performantes

| Règle | À faire | À éviter |
|-------|---------|----------|
| Colonnes explicites | `SELECT payment_id, paid_amount` | `SELECT *` (surtout en moteur colonne) |
| Filtre « sargable » | `WHERE paid_at >= '2026-09-01' AND paid_at < '2026-10-01'` | `WHERE DATE(paid_at) = '2026-09-01'`, `WHERE YEAR(paid_at) = 2026` |
| Types cohérents | Comparer `BIGINT` à `BIGINT` | Conversion implicite `VARCHAR` ↔ `INTEGER` qui désactive l'index |
| Existence | `WHERE EXISTS (…)` | `WHERE id IN (SELECT …)` sur un très grand ensemble ; `COUNT(*) > 0` |
| Pagination | Par clé (`WHERE id > :last_id ORDER BY id LIMIT 50`) | `OFFSET 100000` |
| Agrégation | Filtrer **avant** de joindre et d'agréger | `HAVING` pour un filtre qui pourrait être dans `WHERE` |
| Mises à jour massives | `MERGE` / `INSERT … ON CONFLICT` par lot | Boucle ligne à ligne |
| Chargement en masse | `COPY` (PostgreSQL), `LOAD DATA` (MySQL), `BULK INSERT`/`bcp` (SQL Server), SQL*Loader / `executemany` (Oracle) | `INSERT` unitaire |
| Transactions OLTP | Courtes | Appels réseau pendant une transaction ouverte |
| ORM | Chargement groupé (`selectinload`) | Requêtes N+1 |

Toujours vérifier le plan d'exécution (`EXPLAIN ANALYZE`, plan d'exécution réel SQL Server, `EXPLAIN PLAN` Oracle, `EXPLAIN indexes = 1` ClickHouse, *Query Profile* Snowflake, estimation d'octets BigQuery).

---

## 4. Maintenance

| Moteur | Opération | Fréquence | Porteur |
|--------|-----------|-----------|---------|
| PostgreSQL | `autovacuum` activé, réglé par table pour les grosses tables (`autovacuum_vacuum_scale_factor = 0.02`) | Continu | DBA |
| PostgreSQL | `ANALYZE` après un chargement massif | Chaque chargement | DAG Airflow |
| PostgreSQL | `REINDEX CONCURRENTLY` sur les index gonflés | Mensuel ou sur alerte | DBA |
| PostgreSQL | Création des partitions futures | Quotidien | `pg_partman` / DAG |
| MySQL | `ANALYZE TABLE` | Hebdomadaire | DBA |
| SQL Server | Reconstruction/réorganisation d'index, mise à jour des statistiques | Hebdomadaire | Plan de maintenance |
| Oracle | Collecte des statistiques (`DBMS_STATS`) | Job automatique | DBA |
| ClickHouse | `OPTIMIZE … FINAL` seulement ponctuellement ; surveiller `system.parts` | Sur alerte | Data engineer |
| Snowflake | Rien d'obligatoire ; surveiller le clustering et la consommation des entrepôts | Hebdomadaire | Data engineer |
| Iceberg | `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`, `rewrite_manifests` | Quotidien à hebdomadaire | DAG Airflow |

---

## 5. Rétention et archivage

| Couche / type | Rétention active | Archivage | Base légale indicative |
|---------------|------------------|-----------|------------------------|
| `landing` | 30 à 90 jours | Non (source rejouable) | — |
| `staging` | Dernier état ou 90 jours | Non | — |
| Faits financiers | 10 ans | Oui, stockage objet (Parquet/Iceberg) | Obligations comptables (OHADA : 10 ans) |
| Données RH | Durée du contrat + délai légal | Oui | Code du travail applicable |
| Données personnelles | Durée strictement nécessaire | Anonymisation plutôt qu'archivage | Loi ivoirienne n° 2013-450, RGPD si applicable |
| `audit` | 1 an actif | 5 ans archivés | Politique interne |
| Logs applicatifs en base | 30 à 90 jours | Non | — |

Règles :

- La rétention est **automatisée** (TTL ClickHouse, détachement de partitions PostgreSQL, `expire_snapshots` Iceberg, expiration de partitions BigQuery) et journalisée dans `audit`.
- Les durées légales ci-dessus sont indicatives : **les faire valider par le juriste / DPO** du projet.
- Une donnée archivée reste restaurable : tester la restauration au moins une fois par an.

---

## 6. Supervision

Indicateurs à exposer (Prometheus/Grafana, voir `monitoring/`) :

| Indicateur | Seuil d'alerte |
|------------|----------------|
| Connexions utilisées / `max_connections` | > 80 % |
| Requêtes de plus de 5 minutes (OLTP : 30 s) | > 0 |
| Verrous en attente | > 1 minute |
| Taux de cache (PostgreSQL `blks_hit` / total) | < 95 % |
| Gonflement (bloat) d'une table ou d'un index | > 30 % |
| Retard de réplication | > 60 s |
| Espace disque libre | < 20 % |
| Âge de la plus vieille transaction (wraparound PostgreSQL) | > 1 milliard d'identifiants |
| Nombre de *parts* actives ClickHouse par partition | > 300 |
| Coût des requêtes BigQuery / crédits Snowflake | Budget mensuel dépassé à 80 % |

Activer `pg_stat_statements` (PostgreSQL), le Query Store (SQL Server), le *slow query log* (MySQL) et `system.query_log` (ClickHouse).
