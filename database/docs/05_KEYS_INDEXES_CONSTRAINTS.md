# Clés, index et contraintes

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Clés primaires](#1-clés-primaires)
2. [Clés étrangères](#2-clés-étrangères)
3. [Contraintes d'unicité et CHECK](#3-contraintes-dunicité-et-check)
4. [Stratégie d'indexation](#4-stratégie-dindexation)
5. [Types d'index par moteur](#5-types-dindex-par-moteur)
6. [Moteurs sans contraintes appliquées](#6-moteurs-sans-contraintes-appliquées)
7. [Diagnostic](#7-diagnostic)

---

## 1. Clés primaires

**Toute table a une clé primaire**, y compris en staging (sauf `landing` et `tmp_`).

| Contexte | Clé recommandée | Exemple |
|----------|-----------------|---------|
| OLTP, usage interne | `id BIGINT GENERATED ALWAYS AS IDENTITY` | `billing.invoice.id` |
| OLTP, identifiant exposé (URL, API) ou généré côté client | `id UUID` v7 | `/invoices/0191f3a2-…` |
| OLTP, les deux besoins | `id BIGINT` interne + `public_id UUID UNIQUE` | |
| Dimension | `<entity>_key BIGINT` (clé de substitution) | `dim_customer.customer_key` |
| Table de faits | Clé de substitution `<fact>_key` ou clé composite du grain | `fact_payment.payment_key` |
| Staging | Clé naturelle de la source | `stg_payment.payment_id` |
| Table d'association | Clé composite des deux FK | `PRIMARY KEY (user_account_id, user_role_id)` |
| Table de référence | Code métier | `ref_currency.currency_code` |

Règles :

- **Jamais de donnée métier modifiable** en clé primaire (e-mail, numéro de téléphone, matricule qui peut être réattribué).
- **UUID v4 à éviter** comme clé de cluster (SQL Server, MySQL InnoDB) : l'ordre aléatoire fragmente l'index. Utiliser UUID v7 ou `NEWSEQUENTIALID()`.
- `IDENTITY` plutôt que `SERIAL` (PostgreSQL) ou `AUTO_INCREMENT` sans contrôle : `GENERATED ALWAYS` empêche les insertions manuelles accidentelles.
- En DWH, la clé de substitution est générée par l'entrepôt, jamais reprise de la source.

---

## 2. Clés étrangères

| Contexte | Déclarer la FK ? | Pourquoi |
|----------|------------------|----------|
| OLTP | **Toujours** | L'intégrité est garantie par la base |
| Staging | Non | Les données arrivent dans le désordre |
| DWH PostgreSQL / SQL Server / Oracle | Oui, éventuellement `NOT VALID` / `NOCHECK` pendant le chargement | Documente le modèle, aide l'optimiseur |
| Snowflake, BigQuery | Oui, déclarative (`NOT ENFORCED` / `RELY`) | Documentation et optimisation, aucune vérification |
| ClickHouse, Iceberg | Impossible | Contrôle par tests qualité |

Règles :

- **Toute colonne FK est indexée** (PostgreSQL et Oracle ne le font pas automatiquement). Sans index, une suppression dans la table parente verrouille et parcourt toute la table enfant.
- `ON DELETE` explicite :
  - `RESTRICT` (défaut conseillé) pour les données métier ;
  - `CASCADE` uniquement pour une composition (`invoice` → `invoice_line`) ;
  - `SET NULL` pour une référence optionnelle.
- Pas de FK entre bases ou entre domaines applicatifs : chaque service est propriétaire de ses données.
- Quand une FK n'est pas déclarée, un **test qualité** vérifie l'intégrité référentielle (requête d'orphelins sur le modèle de `@fact_events_orphan_records` dans `include/sql/data_quality/checks.sql`, ou test `relationships` dbt).

---

## 3. Contraintes d'unicité et CHECK

```sql
ALTER TABLE billing.invoice
    ADD CONSTRAINT uq_invoice_invoice_number UNIQUE (invoice_number),
    ADD CONSTRAINT ck_invoice_total_amount CHECK (total_amount >= 0),
    ADD CONSTRAINT ck_invoice_due_date CHECK (due_date >= issued_date),
    ADD CONSTRAINT ck_invoice_status CHECK (invoice_status IN ('draft', 'issued', 'paid', 'cancelled'));
```

- **Chaque clé métier est protégée par `UNIQUE`**, même quand la PK est technique.
- Unicité avec suppression logique : index unique partiel `WHERE deleted_at IS NULL` (PostgreSQL, SQL Server avec index filtré).
- Unicité avec `NULL` : PostgreSQL 15+ accepte `UNIQUE NULLS NOT DISTINCT`.
- Les règles simples et stables vont dans des `CHECK` ; les règles qui changent souvent ou dépendent d'autres tables restent dans l'application.

---

## 4. Stratégie d'indexation

### 4.1 Quoi indexer

1. Clés primaires et contraintes d'unicité (automatique).
2. **Toutes les clés étrangères.**
3. Colonnes des filtres fréquents (`WHERE`), en commençant par la plus sélective **utilisée avec `=`**, puis les colonnes utilisées en intervalle.
4. Colonnes de tri et de pagination (`ORDER BY created_at DESC LIMIT 50`).
5. Colonnes de chargement incrémental (`updated_at`, `loaded_at`).

### 4.2 Quoi ne pas faire

- Indexer chaque colonne « au cas où ».
- Créer `ix_a_b` et `ix_a` : le premier couvre le second.
- Indexer une colonne booléenne ou à très faible cardinalité (sauf index partiel).
- Appliquer une fonction sur une colonne indexée dans le `WHERE` (`WHERE LOWER(email) = …`) sans index fonctionnel correspondant.
- Garder des index jamais utilisés (voir [§7](#7-diagnostic)).

### 4.3 Chargement en masse

Pour les tables de faits volumineuses rechargées en entier : supprimer les index secondaires, charger, recréer les index, puis `ANALYZE`. Pour un chargement incrémental, garder les index.

---

## 5. Types d'index par moteur

| Moteur | Index | Usage |
|--------|-------|-------|
| PostgreSQL | B-tree | Défaut : égalité, intervalle, tri |
| | BRIN | Colonnes corrélées à l'ordre physique (`loaded_at`, `paid_at`) sur de très grandes tables ; quelques Ko au lieu de plusieurs Go |
| | GIN | `JSONB`, tableaux, recherche plein texte, `pg_trgm` (recherche `LIKE '%…%'`) |
| | GiST / SP-GiST | Géographie, intervalles, contraintes d'exclusion |
| | Hash | Égalité seule (rarement utile) |
| | Partiel (`WHERE`) | Sous-ensemble fréquent : `WHERE deleted_at IS NULL`, `WHERE status = 'open'` |
| | Couvrant (`INCLUDE`) | Lecture sans accès à la table |
| MySQL | B-tree (InnoDB) | La PK est l'index cluster : la garder courte et croissante |
| | FULLTEXT | Recherche texte |
| | Fonctionnel (8.0.13+) | Expressions, clés JSON |
| SQL Server | Cluster / non cluster | Un seul cluster, sur une clé courte, croissante, unique |
| | Columnstore (`cci_`) | Tables de faits : compression x10 et lecture vectorisée |
| | Filtré | Équivalent de l'index partiel |
| Oracle | B-tree, bitmap | Bitmap uniquement en DWH (verrous en écriture concurrente) |
| | Fonctionnel | `UPPER(col)`, `TRUNC(date)` |
| ClickHouse | Clé de tri (`ORDER BY`) | L'« index » principal : colonnes filtrées, de la plus faible à la plus forte cardinalité |
| | Index de saut (`minmax`, `set`, `bloom_filter`) | Filtres secondaires |
| | Projections | Autre ordre de tri ou agrégat pré-calculé |
| Snowflake | Clé de clustering | Tables > 1 To avec des filtres réguliers sur la même colonne |
| | Search optimization | Recherches ponctuelles sélectives |
| BigQuery | Partitionnement + clustering (4 colonnes) | Réduit les octets scannés, donc le coût |
| | Search index | Recherche dans du texte et du JSON |
| Iceberg | Partitionnement caché + ordre de tri | Élagage des fichiers |
| | Filtres de Bloom Parquet | Égalité sur colonnes à forte cardinalité |

---

## 6. Moteurs sans contraintes appliquées

Snowflake, BigQuery, ClickHouse et Iceberg n'appliquent ni l'unicité ni l'intégrité référentielle. Le pipeline doit donc :

1. **Dédoublonner explicitement** (`QUALIFY ROW_NUMBER() OVER (PARTITION BY … ORDER BY updated_at DESC) = 1`, `ReplacingMergeTree`, `MERGE`).
2. **Tester après chaque chargement** : unicité de la clé (`check_no_duplicates`), non-nullité (`check_no_nulls`) dans `orchestration/data_quality/checks.py`, intégrité référentielle par requête d'orphelins, ou tests dbt `unique`, `not_null`, `relationships`.
3. **Déclarer quand même** les PK/FK (Snowflake, BigQuery) pour la documentation et les outils BI.

---

## 7. Diagnostic

PostgreSQL :

```sql
-- Index jamais utilisés depuis le dernier reset des statistiques
SELECT schemaname, relname AS table_name, indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;

-- Clés étrangères sans index
SELECT c.conrelid::regclass AS table_name, c.conname AS fk_name
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] = c.conkey
  );

-- Tables sans clé primaire
SELECT n.nspname AS schema_name, c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'landing')
  AND NOT EXISTS (SELECT 1 FROM pg_constraint p WHERE p.conrelid = c.oid AND p.contype = 'p');
```

Toujours valider un nouvel index avec `EXPLAIN (ANALYZE, BUFFERS)` sur une volumétrie réaliste.
