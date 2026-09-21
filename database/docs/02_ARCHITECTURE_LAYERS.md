# Architecture des données : couches, domaines et modélisation

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [OLTP ou OLAP : deux mondes, deux règles](#1-oltp-ou-olap--deux-mondes-deux-règles)
2. [Couches analytiques](#2-couches-analytiques)
3. [Organisation par domaine](#3-organisation-par-domaine)
4. [Modélisation dimensionnelle](#4-modélisation-dimensionnelle)
5. [Historisation (SCD)](#5-historisation-scd)
6. [Modélisation applicative (OLTP)](#6-modélisation-applicative-oltp)
7. [Lakehouse et Apache Iceberg](#7-lakehouse-et-apache-iceberg)
8. [Choisir le moteur](#8-choisir-le-moteur)

---

## 1. OLTP ou OLAP : deux mondes, deux règles

| Critère | Base applicative (OLTP) | Base analytique (OLAP) |
|---------|-------------------------|------------------------|
| Usage | Lire/écrire quelques lignes, très souvent | Lire des millions de lignes, peu souvent |
| Modèle | Normalisé (3NF) | Dimensionnel (étoile), dénormalisé |
| Intégrité | Garantie par la base (FK, CHECK, transactions) | Garantie par le pipeline (tests qualité) |
| Clés | Identity/UUID, FK déclarées | Clés de substitution, FK souvent non appliquées |
| Suppression | Physique ou logique | Logique, avec historique |
| Moteurs | PostgreSQL, MySQL, SQL Server, Oracle | PostgreSQL, ClickHouse, Snowflake, BigQuery, Iceberg |
| Propriétaire du schéma | L'équipe applicative (migrations ORM) | L'équipe Data (migrations SQL / dbt) |

**Règle d'or** : une application ne lit jamais directement les couches `staging`/`dwh`, et un pipeline analytique n'écrit jamais dans une base applicative. Les échanges passent par une API, un export, une réplique ou un CDC.

---

## 2. Couches analytiques

```text
 Sources ──► landing ──► staging ──► dwh / domaine ──► marts ──► BI / API
 (OLTP,       raw_*       stg_*       dim_* fact_*       mart_*
  fichiers,               int_*       bridge_* snp_*     agg_*
  API)
                         └────────────── audit (audit_*) ──────────────┘
```

| Couche | Objectif | Transformations autorisées | Rétention conseillée | Lecteurs |
|--------|----------|----------------------------|----------------------|----------|
| `landing` | Rejouer un chargement sans relire la source | Aucune, sauf ajout des colonnes techniques | 30 à 90 jours | Pipelines |
| `staging` | Donnée propre et typée, 1 table = 1 source | Typage, renommage, dédoublonnage, normalisation | Dernier état ou 90 jours | Pipelines, data engineers |
| `dwh` / domaine | Vérité métier historisée | Jointures, règles métier, clés de substitution, SCD | Durée légale (10 ans en comptabilité) | Analystes, marts |
| `marts` | Répondre à un besoin de restitution | Agrégations, KPI, dénormalisation | Selon usage | Outils BI, API |
| `audit` | Tracer chaque exécution | Insertion seule | 1 an minimum | Exploitation |

Règles :

- **Les flux vont toujours de gauche à droite**. Une table `marts` ne lit jamais `landing`.
- **Chaque couche est rejouable** à partir de la précédente (idempotence, voir `docs/DATA_ENGINEERING_BEST_PRACTICES.md` §2 du template Airflow (`airflow-plateforme-template`)).
- **La couche `landing` accepte tout** : colonnes en `TEXT`, pas de contrainte. Le typage et le rejet des lignes invalides se font en `staging`.
- Avec dbt, la correspondance est : `landing` = sources, `staging` = `models/staging`, `int_` = `models/intermediate`, `dwh`/`marts` = `models/marts` (voir `docs/DBT_INTEGRATION.md` du template Airflow (`airflow-plateforme-template`)).

---

## 3. Organisation par domaine

Un **domaine** est un périmètre métier avec un responsable identifié (data owner) : finance, RH, ventes, projet…

| Élément | Règle |
|---------|-------|
| Schéma | Un schéma par domaine : `finance`, `hr`, `sales` |
| Responsable | Un data owner métier et un référent technique par domaine, déclarés dans le catalogue |
| Droits | Rôles `role_<domain>_read` / `role_<domain>_write` |
| Objets partagés | Dimensions conformes dans `dwh` (`dwh.dim_date`, `dwh.dim_customer`), jamais dupliquées |
| Dépendances entre domaines | Un domaine lit les `dim_`/`fact_` d'un autre domaine, jamais ses `stg_`/`int_` |
| Nommage des tables | Préfixe de couche obligatoire : `finance.stg_payment`, `finance.fact_payment` |

Le passage d'une organisation par couche (`dwh.fact_payment`) à une organisation par domaine (`finance.fact_payment`) se fait quand un deuxième domaine arrive avec un responsable différent. On peut conserver une **vue de compatibilité** dans l'ancien schéma pendant la transition.

---

## 4. Modélisation dimensionnelle

### 4.1 Tables de faits

| Type | Grain | Exemple | Mise à jour |
|------|-------|---------|-------------|
| Transactionnelle | 1 ligne par événement | `finance.fact_payment` | Insertion (+ corrections) |
| Snapshot périodique | 1 ligne par entité et par période | `finance.snp_account_balance_daily` | Insertion par période |
| Snapshot accumulé | 1 ligne par processus, mise à jour à chaque étape | `sales.fact_order_fulfillment` | Mise à jour |
| Sans mesure (factless) | 1 ligne par occurrence | `hr.fact_training_attendance` | Insertion |

Règles :

1. **Déclarer le grain** en commentaire de la table **avant** de choisir les colonnes : `COMMENT ON TABLE finance.fact_payment IS 'Grain : 1 ligne par paiement reçu'`.
2. Une table de faits ne contient que : les clés de dimensions (`*_key`), les dimensions dégénérées (`payment_number`), les mesures et les colonnes techniques.
3. **Mesures additives** de préférence (montants, quantités). Les ratios se recalculent à partir des composantes, ils ne se somment pas.
4. **Pas de NULL dans les clés de dimension** : utiliser un membre inconnu (`-1` = inconnu, `-2` = non applicable).
5. Clé de date au format `YYYYMMDD` (`INTEGER`) : `payment_date_key = 20260916`.

### 4.2 Dimensions

| Règle | Détail |
|-------|--------|
| Clé de substitution | `<entity>_key BIGINT`, générée par l'entrepôt |
| Clé naturelle | `<entity>_id` ou `<entity>_code`, conservée et indexée |
| Membres spéciaux | Lignes `-1` (Unknown) et `-2` (Not applicable) créées à l'initialisation |
| Attributs | Libellés lisibles plutôt que codes seuls (`status_code` **et** `status_label`) |
| Hiérarchies | Aplaties dans la dimension (`country_name`, `region_name`, `city_name`) |
| `dim_date` | Obligatoire, générée une fois (de 2000 à 2050), partagée dans `dwh` |

### 4.3 Étoile plutôt que flocon

Privilégier le **schéma en étoile** (dimensions dénormalisées). Le flocon (dimensions normalisées) n'est justifié que pour une très grande dimension avec une sous-partie peu utilisée, ou quand une sous-dimension est partagée par plusieurs dimensions.

### 4.4 Plafonds de largeur par type de table

Voir [04_LIMITS_BY_DBMS.md §3](04_LIMITS_BY_DBMS.md#3-plafonds-internes-par-type-de-table).

---

## 5. Historisation (SCD)

| Type | Comportement | Quand l'utiliser | Colonnes |
|------|--------------|------------------|----------|
| SCD 0 | Jamais modifié | Date de naissance, date de création | — |
| SCD 1 | Écrasement | Correction d'erreur, attribut sans valeur historique | `updated_at` |
| SCD 2 | Nouvelle ligne à chaque changement | Attribut analysé dans le temps (segment client, service d'un employé) | `valid_from`, `valid_to`, `is_current`, `row_hash` |
| SCD 3 | Colonne « valeur précédente » | Besoin limité à la valeur d'avant | `previous_<attr>` |
| SCD 4 | Table d'historique séparée | Dimension volumineuse, historique rarement consulté | table `<dim>_history` |
| SCD 6 | Combinaison 1 + 2 + 3 | Analyse « tel qu'à l'époque » et « tel qu'aujourd'hui » | `current_<attr>` + colonnes SCD 2 |

Règles SCD 2 :

- `valid_to` est `NULL` pour la version courante (ou `9999-12-31` si le moteur n'indexe pas bien les NULL : Oracle, ClickHouse).
- Intervalle **semi-ouvert** : `valid_from <= t < valid_to`.
- La détection de changement compare `row_hash` (SHA-256 des attributs historisés), pas chaque colonne.
- Une contrainte d'unicité garantit une seule version courante : `CREATE UNIQUE INDEX ux_dim_customer_current ON dwh.dim_customer (customer_id) WHERE is_current;`
- Avec dbt, utiliser les **snapshots** (`snp_`) plutôt qu'un SCD 2 codé à la main.

---

## 6. Modélisation applicative (OLTP)

| Règle | Détail |
|-------|--------|
| 3e forme normale | Une information à un seul endroit. Dénormaliser seulement après mesure. |
| Clé primaire | `id` technique (`BIGINT` identity ou `UUID` v7), jamais une donnée métier modifiable |
| Clés métier | Protégées par une contrainte `UNIQUE` |
| FK | Toujours déclarées et **indexées** |
| Énumérations | Table de référence si la liste évolue ou porte des attributs ; `CHECK (status IN (…))` sinon. Éviter `ENUM` MySQL/PostgreSQL, difficile à faire évoluer. |
| Suppression logique | `deleted_at` + index partiel `WHERE deleted_at IS NULL` + vues de lecture |
| Concurrence | Colonne `version` (verrouillage optimiste) sur les agrégats modifiés par plusieurs utilisateurs |
| Audit | Table `<entity>_history` alimentée par trigger ou par l'application, ou CDC (Debezium) |
| Multi-tenant | Colonne `tenant_id` dans toutes les tables + Row Level Security, ou un schéma par tenant |
| JSON | Pour les attributs réellement variables. Tout champ filtré ou joint devient une vraie colonne. |
| Événements sortants | Patron *outbox* (`outbox_event`) pour publier vers Kafka de façon transactionnelle |
| ORM | Le modèle ORM (SQLAlchemy, Django, Prisma) déclare explicitement `__tablename__`, schéma et noms de contraintes |

Exemple SQLAlchemy conforme :

```python
from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase

NAMING_CONVENTION = {
    "pk": "pk_%(table_name)s",
    "fk": "fk_%(table_name)s_%(referred_table_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(schema="billing", naming_convention=NAMING_CONVENTION)
```

---

## 7. Lakehouse et Apache Iceberg

Iceberg est un **format de table** (fichiers Parquet + métadonnées) lu par plusieurs moteurs : Spark, Trino, Flink, Snowflake, BigQuery, ClickHouse, DuckDB.

| Concept | Équivalent relationnel | Règle |
|---------|------------------------|-------|
| Catalogue (REST, Glue, Hive, Nessie, Polaris) | Instance / base | Un catalogue par environnement |
| Namespace | Schéma | Mêmes noms que les schémas : `landing`, `finance`… |
| Table | Table | Mêmes préfixes : `finance.fact_payment` |
| Partition spec | Partitionnement | Partitionnement caché : `days(paid_at)`, `bucket(16, customer_id)` |
| Sort order | Index / clé de tri | Colonnes des filtres fréquents |
| Snapshot | Historique | Voyage dans le temps, expiration obligatoire |

Règles spécifiques :

- **Noms en minuscules uniquement** : Glue et Hive Metastore les convertissent.
- **Format v2 minimum** (suppressions au niveau ligne), v3 si tous les moteurs lecteurs le supportent (`variant`, `timestamp_ns`, lignage des lignes).
- **Évolution de schéma par identifiant de champ** : renommer une colonne est sûr, réutiliser un ancien nom pour une autre donnée ne l'est pas.
- **Maintenance planifiée** (DAG Airflow) : `expire_snapshots`, `remove_orphan_files`, `rewrite_data_files` (compaction), `rewrite_manifests`.
- **Pas de partition par colonne à forte cardinalité** : préférer `bucket(N, col)`.
- Viser des fichiers de **128 à 512 Mo**. Les petits fichiers sont la première cause de lenteur.

---

## 8. Choisir le moteur

| Besoin | Moteur conseillé |
|--------|------------------|
| Application transactionnelle | PostgreSQL (défaut), MySQL si l'écosystème l'impose |
| Écosystème Microsoft / .NET | SQL Server |
| Existant Oracle, ERP | Oracle (pas de nouveau projet sans justification) |
| DWH jusqu'à quelques centaines de Go | PostgreSQL |
| Analytique temps réel, logs, événements, milliards de lignes | ClickHouse |
| DWH cloud managé, forte concurrence BI | Snowflake ou BigQuery |
| Lac de données ouvert, multi-moteurs | Iceberg (+ Trino/Spark) |

Toute nouvelle base fait l'objet d'un ADR (Architecture Decision Record) dans le dépôt du projet.
