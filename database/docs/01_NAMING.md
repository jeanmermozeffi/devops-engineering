# Conventions de nommage des bases de données

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Règles générales](#1-règles-générales)
2. [Bases de données](#2-bases-de-données)
3. [Schémas](#3-schémas)
4. [Tables analytiques](#4-tables-analytiques)
5. [Tables applicatives](#5-tables-applicatives)
6. [Vues et vues matérialisées](#6-vues-et-vues-matérialisées)
7. [Colonnes](#7-colonnes)
8. [Colonnes techniques standard](#8-colonnes-techniques-standard)
9. [Clés, contraintes et index](#9-clés-contraintes-et-index)
10. [Fonctions, procédures, triggers, séquences, types](#10-fonctions-procédures-triggers-séquences-types)
11. [Rôles et utilisateurs](#11-rôles-et-utilisateurs)
12. [Abréviations autorisées](#12-abréviations-autorisées)
13. [Mots interdits](#13-mots-interdits)
14. [Particularités par SGBD](#14-particularités-par-sgbd)
15. [Exemples complets](#15-exemples-complets)

---

## 1. Règles générales

| Règle | Correct | Incorrect |
|-------|---------|-----------|
| Anglais | `payment`, `due_date` | `paiement`, `date_echeance` |
| `snake_case` en minuscules | `customer_order` | `CustomerOrder`, `customerOrder`, `CUSTOMER_ORDER` |
| Caractères autorisés : `a-z`, `0-9`, `_` | `invoice_line` | `invoice-line`, `facture_é`, `invoice line` |
| Commence par une lettre | `q1_revenue` | `1q_revenue`, `_revenue` |
| Pas de double `_` (réservé aux séparateurs dbt `__`) | `order_line` | `order__line` |
| Pas de `_` final | `amount` | `amount_` |
| **Singulier** | `dim_customer`, `billing.invoice` | `dim_customers`, `billing.invoices` |
| Pas de guillemets à la création | `CREATE TABLE finance.fact_payment` | `CREATE TABLE "Finance"."FactPayment"` |
| 30 caractères au plus (plafond interne) | `fact_payment_installment` | `fact_customer_payment_installment_schedule_detail` |
| Pas de type dans le nom | `customer` | `tbl_customer`, `customer_table`, `t_customer` |
| Pas d'environnement dans le nom | `finance.fact_payment` | `finance.fact_payment_prod` |
| Pas de date ou de version dans le nom | `fact_payment` partitionnée | `fact_payment_2026`, `customer_v2` |

**Pourquoi le singulier ?** Une table décrit un type d'entité, ce qui correspond au nom de la classe ORM (`Invoice` → `invoice`). Le singulier évite aussi les pluriels irréguliers (`person`/`people`, `category`/`categories`) et rend les composés lisibles (`order_line` plutôt que `orders_lines`).

**Pourquoi 30 caractères ?** C'est la seule longueur acceptée par tous les moteurs que nous utilisons, y compris les anciennes versions d'Oracle (< 12.2). PostgreSQL **tronque sans erreur** au-delà de 63 octets, ce qui peut créer des collisions entre deux noms longs (voir [04_LIMITS_BY_DBMS.md](04_LIMITS_BY_DBMS.md)).

---

## 2. Bases de données

Format : `<project>` ou `<project>_<purpose>`

| Exemple | Usage |
|---------|-------|
| `analytics` | Entrepôt de données principal |
| `db_analytics_oscrum` | Entrepôt du projet OSCRUM |
| `billing` | Base applicative du service de facturation |
| `crm_replica` | Réplique en lecture d'une source |

Règles :

- **Pas de suffixe d'environnement** (`_dev`, `_prod`) : l'environnement est porté par l'instance ou le serveur, pas par le nom. Le même code et les mêmes migrations tournent partout.
- Une base par application OLTP. Une base analytique peut héberger plusieurs domaines, séparés par des schémas.
- Oracle : la base (PDB) est limitée à 30 octets (64 à partir de 21c). Snowflake/BigQuery : « database » correspond respectivement à une base Snowflake et à un **projet** GCP.

---

## 3. Schémas

Le schéma est le **premier niveau de rangement**. Il porte **soit un domaine métier, soit une couche transverse**.

### 3.1 Schémas de domaine

Un schéma par domaine métier (bounded context). Le nom est un nom court, au singulier, en anglais.

| Schéma | Domaine |
|--------|---------|
| `finance` | Paiements, factures, comptabilité |
| `hr` | Ressources humaines, paie, effectifs |
| `sales` | Ventes, commandes, pipeline commercial |
| `crm` | Clients, contacts, interactions |
| `project` | Projets, tâches, temps passé |
| `inventory` | Stocks, articles, entrepôts |
| `billing` | Facturation (application) |
| `auth` | Authentification, comptes, sessions (application) |

### 3.2 Schémas de couche (transverses)

| Schéma | Contenu | Préfixe de table attendu |
|--------|---------|--------------------------|
| `landing` | Données brutes telles que reçues, sans transformation | `raw_` |
| `staging` | Données nettoyées, typées, dédoublonnées | `stg_`, `int_` |
| `dwh` | Faits et dimensions **partagés entre domaines** (`dim_date`, `dim_customer` conforme) | `dim_`, `fact_`, `bridge_`, `snp_` |
| `marts` | Tables prêtes pour la BI, transverses | `mart_`, `agg_` |
| `audit` | Journal de chargement, résultats qualité, lignage | `audit_` |
| `ref` | Référentiels partagés (pays, devises, calendriers) | `ref_` |
| `sandbox` | Espace d'exploration des analystes, **jamais lu en production** | libre |
| `archive` | Données sorties de la rétention active | même nom que l'original |

> Le schéma s'appelle `marts` (pluriel) pour rester aligné avec les profils RBAC de `db-analytics-oscrum` (`pg-admin.sh rbac apply … marts bi`). C'est la seule exception à la règle du singulier.

### 3.3 Comment choisir

| Situation | Choix | Exemple |
|-----------|-------|---------|
| Projet mono-domaine, petite équipe | Schémas de couche uniquement | `staging.stg_order`, `dwh.fact_order` |
| Plateforme multi-domaines | Schéma de domaine + préfixe de couche dans la table | `finance.stg_payment`, `finance.fact_payment` |
| Objet partagé par plusieurs domaines | Schéma de couche transverse | `dwh.dim_date`, `dwh.dim_customer` |
| Base applicative | Schéma de domaine, tables sans préfixe | `billing.invoice` |

Dans tous les cas, **la couche reste visible** : soit par le schéma, soit par le préfixe de la table. Les droits se donnent par schéma (voir [07_SECURITY_ACCESS.md](07_SECURITY_ACCESS.md)).

Interdits : `public` pour les objets métier (PostgreSQL), `dbo` pour les objets métier (SQL Server), un schéma par personne.

---

## 4. Tables analytiques

Format : `<schema>.<prefix>_<entity>[_<qualifier>]`

| Préfixe | Rôle | Couche | Exemple |
|---------|------|--------|---------|
| `raw_` | Copie brute d'une source, colonnes source conservées | landing | `landing.raw_crm_contact` |
| `stg_` | Donnée nettoyée et typée, 1 table = 1 source | staging | `finance.stg_payment` |
| `int_` | Étape intermédiaire de transformation | staging | `finance.int_payment_enriched` |
| `dim_` | Dimension | dwh ou domaine | `dwh.dim_customer` |
| `fact_` | Table de faits | dwh ou domaine | `finance.fact_payment` |
| `bridge_` | Table de pont (relation N-N en DWH) | dwh ou domaine | `sales.bridge_order_promotion` |
| `snp_` | Snapshot (photo périodique d'un état) | dwh ou domaine | `hr.snp_headcount_monthly` |
| `agg_` | Agrégat technique pré-calculé | marts ou domaine | `finance.agg_payment_daily` |
| `mart_` | Table exposée à la BI | marts ou domaine | `marts.mart_cash_position` |
| `ref_` | Référentiel partagé | ref | `ref.ref_currency` |
| `audit_` | Journalisation technique | audit | `audit.audit_dag_run` |
| `tmp_` | Table de travail supprimée en fin de traitement | toutes | `staging.tmp_payment_dedup` |

Règles :

- **`raw_` inclut la source** quand plusieurs systèmes alimentent la même couche : `raw_<source>_<entity>` (`raw_sap_invoice`, `raw_crm_contact`).
- **Grain dans le nom des faits** quand il n'est pas évident : `fact_payment` (1 ligne par paiement), `fact_payment_daily` (1 ligne par jour).
- **Qualificatifs de fréquence** en fin de nom : `_daily`, `_weekly`, `_monthly`, `_yearly`.
- Les tables `tmp_` ne sont **jamais** lues par un autre traitement que celui qui les crée.

---

## 5. Tables applicatives

Format : `<schema>.<entity>[_<qualifier>]`, **sans préfixe de rôle**.

| Cas | Nom | Commentaire |
|-----|-----|-------------|
| Entité | `billing.invoice` | Singulier |
| Composition (enfant) | `billing.invoice_line` | Parent + enfant |
| Association N-N | `auth.user_account_role` | Les deux entités, ordre du sens de lecture principal |
| Association porteuse de sens | `project.membership` | Nom métier si il existe |
| Historique | `billing.invoice_history` | Suffixe `_history` |
| Paramétrage | `billing.payment_term` | Pas de préfixe `ref_` en OLTP |
| File d'attente / outbox | `billing.outbox_event` | |

Mots réservés à contourner (voir [§13](#13-mots-interdits)) : `user` devient `user_account`, `order` devient `customer_order` ou `sales_order`, `group` devient `user_group`.

---

## 6. Vues et vues matérialisées

| Objet | Format | Exemple |
|-------|--------|---------|
| Vue | `v_<name>` | `finance.v_payment_overdue` |
| Vue matérialisée | `mv_<name>` | `finance.mv_payment_monthly` |
| Vue de sécurité (filtrage, masquage) | `sv_<name>` | `hr.sv_employee_masked` |

Exception : dans `marts`, une vue exposée à la BI garde le préfixe `mart_`, car l'outil BI ne doit pas dépendre de l'implémentation (table ou vue).

---

## 7. Colonnes

### 7.1 Suffixes et préfixes sémantiques

Le suffixe indique **la nature de la valeur**, ce qui aide à deviner le type sans regarder le DDL.

| Suffixe / préfixe | Signification | Type attendu | Exemple |
|-------------------|---------------|--------------|---------|
| `id` | Clé primaire technique de la table | `BIGINT` / `UUID` | `id` (OLTP) |
| `<entity>_id` | Clé technique (PK en DWH, FK partout) | `BIGINT` / `UUID` | `customer_id` |
| `<entity>_key` | Clé de substitution d'une dimension | `BIGINT` | `customer_key` |
| `<entity>_code` | Code métier lisible et stable | `VARCHAR(n)` | `currency_code` |
| `<entity>_ref` / `external_id` | Identifiant dans un système externe | `VARCHAR(n)` | `sap_ref` |
| `_name` | Libellé court | `VARCHAR(n)` | `product_name` |
| `_label` | Libellé affichable | `VARCHAR(n)` | `status_label` |
| `_desc` | Description longue | `TEXT` | `product_desc` |
| `_at` | Horodatage (UTC, avec fuseau) | `TIMESTAMPTZ` | `paid_at` |
| `_date` | Date sans heure | `DATE` | `due_date` |
| `_time` | Heure sans date | `TIME` | `opening_time` |
| `_year`, `_month`, `_week` | Composante de date | `SMALLINT` | `fiscal_year` |
| `_amount` | Montant monétaire | `NUMERIC(18,2)` | `paid_amount` |
| `_price` | Prix unitaire | `NUMERIC(19,4)` | `unit_price` |
| `_qty` | Quantité | `NUMERIC(18,3)` ou `INTEGER` | `ordered_qty` |
| `_count` | Nombre d'occurrences | `INTEGER` | `line_count` |
| `_rate` | Taux (0 à 1) | `NUMERIC(9,6)` | `tax_rate` |
| `_pct` | Pourcentage (0 à 100) | `NUMERIC(7,4)` | `discount_pct` |
| `_ratio` | Rapport sans borne | `NUMERIC(18,6)` | `conversion_ratio` |
| `_seconds`, `_minutes`, `_days` | Durée avec unité explicite | `INTEGER` / `NUMERIC` | `processing_seconds` |
| `_kg`, `_m`, `_km` | Mesure avec unité explicite | `NUMERIC` | `weight_kg` |
| `_url` | URL | `VARCHAR(2048)` | `avatar_url` |
| `_email` | Adresse e-mail | `VARCHAR(320)` | `contact_email` |
| `_phone` | Numéro E.164 | `VARCHAR(20)` | `mobile_phone` |
| `_hash` | Empreinte | `CHAR(64)` / `BYTEA` | `row_hash` |
| `_json` | Document semi-structuré | `JSONB` | `payload_json` |
| `_status` | État d'un cycle de vie | `VARCHAR(30)` ou FK | `payment_status` |
| `_type` | Catégorie | `VARCHAR(30)` ou FK | `payment_type` |
| `_flag` | À éviter, préférer `is_`/`has_` | — | — |
| `is_` / `has_` / `can_` | Booléen | `BOOLEAN NOT NULL` | `is_active`, `has_discount` |
| `nb_`, `num_` | **Interdit**, utiliser `_count` | — | — |

### 7.2 Règles

- **Pas de préfixe systématique par le nom de la table** : dans `billing.invoice`, écrire `issued_at` et non `invoice_issued_at`. Exceptions : les clés (`invoice_id` dans `invoice_line`), les identifiants métier usuels (`invoice_number`), les colonnes qui seraient sinon un mot générique ou réservé (`invoice_status`, `invoice_type`), et les colonnes des tables de faits, qui doivent rester explicites après jointure.
- **FK = nom de la PK référencée** : `invoice_line.invoice_id` référence `invoice.id` (OLTP) ou `invoice.invoice_id`. Quand une table référence deux fois la même entité, préfixer par le rôle : `billing_address_id`, `shipping_address_id`.
- **Booléens positifs** : `is_active` et non `is_not_inactive`, `NOT NULL` avec une valeur par défaut.
- **Unités et devises explicites** : un montant sans devise est un bug. Ajouter `currency_code` à côté de tout `_amount`, ou suffixer : `amount_xof`, `amount_eur`.
- **Même concept, même nom partout** : `customer_id` s'appelle `customer_id` dans toutes les tables et toutes les couches.
- **Pas de nom générique seul** : `value`, `data`, `info`, `date`, `type`, `name` doivent être qualifiés (`metric_value`, `event_date`).
- **Ordre des colonnes recommandé** : clés, clés étrangères, attributs métier, mesures, colonnes techniques.

### 7.3 Renommage à la couche staging

La couche `landing` garde les noms source tels quels (y compris en français ou en `CamelCase`, mis en minuscules). **Le renommage vers la convention se fait en `staging`** :

```sql
SELECT
    "IdPaiement"::BIGINT            AS payment_id,
    "MontantTTC"::NUMERIC(18,2)     AS gross_amount,
    "DatePaiement"::DATE            AS payment_date,
    "CodeDevise"                    AS currency_code
FROM landing.raw_sage_paiement;
```

---

## 8. Colonnes techniques standard

Colonnes présentes dans **toutes** les tables selon la couche. Elles sont placées **en fin de table**.

| Colonne | Type PostgreSQL | landing | staging | dwh / domaine | OLTP | Description |
|---------|-----------------|:-------:|:-------:|:-------------:|:----:|-------------|
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | — | — | ✓ | ✓ | Création de la ligne dans cette table |
| `updated_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | — | — | ✓ | ✓ | Dernière modification |
| `created_by` | `VARCHAR(100)` | — | — | — | ✓ | Utilisateur ou service à l'origine |
| `updated_by` | `VARCHAR(100)` | — | — | — | ✓ | Dernier modificateur |
| `deleted_at` | `TIMESTAMPTZ NULL` | — | — | option | option | Suppression logique (NULL = active) |
| `version` | `INTEGER NOT NULL DEFAULT 1` | — | — | — | option | Verrouillage optimiste |
| `loaded_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | ✓ | ✓ | ✓ | — | Chargement par le pipeline |
| `batch_id` | `VARCHAR(250)` | ✓ | ✓ | ✓ | — | `run_id` du DAG Airflow |
| `source_system` | `VARCHAR(50)` | ✓ | ✓ | option | — | Code du système source (`sap`, `crm`) |
| `source_file` | `VARCHAR(1024)` | option | — | — | — | Fichier d'origine (ingestion fichier) |
| `row_hash` | `CHAR(64)` | — | ✓ | ✓ | — | SHA-256 des attributs métier (détection de changement) |
| `valid_from` | `TIMESTAMPTZ NOT NULL` | — | — | SCD2 | — | Début de validité |
| `valid_to` | `TIMESTAMPTZ NULL` | — | — | SCD2 | — | Fin de validité (NULL = version courante) |
| `is_current` | `BOOLEAN NOT NULL` | — | — | SCD2 | — | Version courante |

Changements par rapport à l'ancienne convention :

- `dag_run_id` devient **`batch_id`**, pour rester neutre vis-à-vis de l'orchestrateur (Airflow, dbt, script).
- `is_deleted` devient **`deleted_at`**, qui dit aussi *quand* la ligne a été supprimée. `is_deleted` reste toléré dans les tables existantes.
- `valid_from`/`valid_to` passent de `DATE` à `TIMESTAMPTZ` pour gérer plusieurs changements dans la journée. Utiliser `DATE` seulement si le grain métier est le jour.

---

## 9. Clés, contraintes et index

Format : `<prefix>_<table>[_<columns>]`. Le nom ne répète pas le schéma. S'il dépasse 30 caractères, abréger les colonnes (voir [§12](#12-abréviations-autorisées)).

| Objet | Préfixe | Exemple |
|-------|---------|---------|
| Clé primaire | `pk_` | `pk_invoice` |
| Clé étrangère | `fk_<table>_<referenced_table>` | `fk_invoice_line_invoice` |
| Contrainte d'unicité | `uq_` | `uq_invoice_invoice_number` |
| Contrainte CHECK | `ck_` | `ck_invoice_amount_positive` |
| Valeur par défaut nommée (SQL Server) | `df_` | `df_invoice_created_at` |
| Contrainte d'exclusion (PostgreSQL) | `ex_` | `ex_booking_period` |
| Index B-tree | `ix_` | `ix_invoice_customer_id` |
| Index unique | `ux_` | `ux_customer_email` |
| Index partiel | `ix_<table>_<cols>_<condition>` | `ix_invoice_due_date_open` |
| Index BRIN / GIN / GiST | `brin_`, `gin_`, `gist_` | `brin_fact_payment_paid_at` |
| Index columnstore (SQL Server) | `cci_` / `ncci_` | `cci_fact_payment` |
| Clé de tri / d'ordre (ClickHouse) | non nommée | `ORDER BY (customer_id, paid_at)` |

**Toujours nommer les contraintes explicitement.** Les noms générés (`invoice_pkey`, `SYS_C0012345`, `PK__invoice__3213E83F`) diffèrent selon l'environnement et cassent les migrations.

---

## 10. Fonctions, procédures, triggers, séquences, types

| Objet | Format | Exemple |
|-------|--------|---------|
| Fonction | `fn_<verb>_<object>` | `finance.fn_compute_penalty` |
| Procédure | `sp_<verb>_<object>` (sauf SQL Server : `usp_`) | `finance.sp_load_fact_payment` |
| Trigger | `trg_<table>_<timing><event>` | `trg_invoice_bu` (before update) |
| Fonction de trigger | `trg_fn_<purpose>` | `trg_fn_set_updated_at` |
| Séquence | `seq_<table>_<column>` | `seq_invoice_number` |
| Type énuméré | `<name>_enum` | `payment_status_enum` |
| Type composite | `<name>_type` | `money_type` |
| Domaine | `<name>_domain` | `email_domain` |
| Extension / package | nom officiel | `pgcrypto` |

Codes de timing et d'événement pour les triggers : `b` (before), `a` (after), `i` (instead of), suivis de `i` (insert), `u` (update), `d` (delete). Exemple : `trg_invoice_aiud`.

SQL Server : ne jamais préfixer une procédure par `sp_`, réservé au système et qui déclenche une recherche dans `master`.

---

## 11. Rôles et utilisateurs

Aligné sur `db-analytics-oscrum` (`pg-admin.sh`).

| Objet | Format | Exemple |
|-------|--------|---------|
| Rôle groupe (sans LOGIN) | `role_<profile>` | `role_data_engineer`, `role_bi_user` |
| Rôle groupe par domaine | `role_<domain>_<access>` | `role_finance_read`, `role_finance_write` |
| Compte de service | `svc_<application>[_<purpose>]` | `svc_airflow`, `svc_billing_api`, `svc_metabase` |
| Compte nominatif | `<firstname>_<lastname>` ou identifiant SSO | `jean_effi` |
| Propriétaire des objets | `owner_<database>` | `owner_analytics` |

---

## 12. Abréviations autorisées

N'abréger **que** pour tenir dans les 30 caractères, et uniquement avec cette liste :

| Mot | Abréviation | Mot | Abréviation |
|-----|-------------|-----|-------------|
| account | `acct` | amount | `amt` (noms d'objets uniquement) |
| average | `avg` | calculation | `calc` |
| category | `cat` | configuration | `config` |
| customer | `cust` | description | `desc` |
| document | `doc` | employee | `emp` |
| identifier | `id` | information | `info` |
| maximum / minimum | `max` / `min` | number | `num` (noms d'objets uniquement) |
| organization | `org` | percentage | `pct` |
| previous | `prev` | quantity | `qty` |
| reference | `ref` | sequence | `seq` |
| statistics | `stats` | temporary | `tmp` |
| transaction | `txn` | warehouse | `whs` |

Les colonnes gardent de préférence le mot entier (`amount`, `number`). Les abréviations servent surtout aux noms d'index et de contraintes.

---

## 13. Mots interdits

Ne jamais utiliser seuls comme nom de table ou de colonne (mots réservés dans au moins un des SGBD couverts) :

`all`, `analyse`, `analyze`, `and`, `array`, `as`, `asc`, `between`, `by`, `case`, `cast`, `check`, `column`, `comment`, `constraint`, `create`, `current_date`, `current_user`, `date`, `default`, `delete`, `desc`, `distinct`, `do`, `else`, `end`, `except`, `file`, `for`, `foreign`, `from`, `grant`, `group`, `having`, `in`, `index`, `insert`, `interval`, `into`, `is`, `join`, `key`, `level`, `limit`, `number`, `offset`, `on`, `option`, `or`, `order`, `partition`, `password`, `primary`, `range`, `references`, `role`, `row`, `rows`, `select`, `session`, `size`, `table`, `then`, `time`, `timestamp`, `to`, `type`, `union`, `unique`, `update`, `user`, `using`, `value`, `values`, `view`, `when`, `where`, `window`, `with`, `year`

Ils restent autorisés **dans un nom composé** : `order_date`, `user_account`, `event_type`.

La liste complète utilisée par le validateur est dans `orchestration/db/naming.py` du template Airflow.

---

## 14. Particularités par SGBD

| SGBD | Casse des identifiants non quotés | Conséquence |
|------|-----------------------------------|-------------|
| PostgreSQL | Convertis en **minuscules** | `CREATE TABLE Foo` crée `foo`. Un nom créé entre guillemets avec une majuscule devra toujours être quoté. |
| MySQL / MariaDB | Tables sensibles à la casse **selon l'OS** (`lower_case_table_names`) ; colonnes insensibles | Toujours en minuscules pour que Linux et Windows/macOS se comportent pareil. |
| SQL Server | Selon la **collation** (souvent insensible) | Écrire en minuscules pour la portabilité, même si `Invoice` et `invoice` sont identiques. |
| Oracle | Convertis en **MAJUSCULES** | `finance.fact_payment` est stocké `FINANCE.FACT_PAYMENT`. Ne jamais quoter pour garder cette équivalence. Les schémas sont des utilisateurs. |
| Snowflake | Convertis en **MAJUSCULES** | Même comportement qu'Oracle. Les outils (dbt, Airflow) doivent éviter de quoter. |
| BigQuery | Colonnes insensibles à la casse ; datasets et tables **sensibles** | Schéma = *dataset*. Écrire en minuscules. |
| ClickHouse | **Sensible** à la casse | `Customer_ID` ≠ `customer_id`. La convention en minuscules est impérative. Schéma = *database*. |
| Iceberg (Hive/Glue/REST) | Hive Metastore et AWS Glue **mettent en minuscules** | Schéma = *namespace*. Les majuscules créent des désaccords entre Spark et le catalogue. |

---

## 15. Exemples complets

### Plateforme analytique multi-domaines

```text
analytics                           (base)
├── landing
│   ├── raw_sage_payment
│   └── raw_crm_contact
├── dwh
│   ├── dim_date
│   └── dim_customer                (dimension conforme, partagée)
├── finance
│   ├── stg_payment
│   ├── int_payment_enriched
│   ├── dim_payment_method
│   ├── fact_payment
│   ├── agg_payment_daily
│   └── mart_cash_position
├── hr
│   ├── stg_employee
│   ├── dim_employee
│   └── snp_headcount_monthly
├── marts
│   └── mart_executive_kpi
└── audit
    ├── audit_dag_run
    └── audit_quality_check
```

### Base applicative FastAPI

```text
billing                             (base)
├── auth
│   ├── user_account
│   ├── user_role
│   └── user_account_role
└── billing
    ├── customer
    ├── invoice
    ├── invoice_line
    ├── payment
    ├── payment_term
    └── outbox_event
```

```sql
CREATE TABLE billing.invoice (
    id               BIGINT GENERATED ALWAYS AS IDENTITY,
    customer_id      BIGINT        NOT NULL,
    invoice_number   VARCHAR(30)   NOT NULL,
    issued_date      DATE          NOT NULL,
    due_date         DATE          NOT NULL,
    total_amount     NUMERIC(18,2) NOT NULL,
    currency_code    CHAR(3)       NOT NULL,
    invoice_status   VARCHAR(30)   NOT NULL DEFAULT 'draft',
    is_paid          BOOLEAN       NOT NULL DEFAULT false,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT pk_invoice PRIMARY KEY (id),
    CONSTRAINT fk_invoice_customer FOREIGN KEY (customer_id) REFERENCES billing.customer (id),
    CONSTRAINT uq_invoice_invoice_number UNIQUE (invoice_number),
    CONSTRAINT ck_invoice_total_amount CHECK (total_amount >= 0)
);
```
