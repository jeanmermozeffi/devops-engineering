# Limites techniques et plafonds internes

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

Ce document sépare deux notions :

- **Limite technique** : ce que le moteur refuse (ou tronque). La dépasser provoque une erreur.
- **Plafond interne** : ce que **nous** nous autorisons, bien en dessous de la limite technique. Le dépasser impose une justification en revue (voir [CHECKLIST.md](CHECKLIST.md)).

## Table des matières

1. [Limites techniques par SGBD](#1-limites-techniques-par-sgbd)
2. [Plafonds internes transverses](#2-plafonds-internes-transverses)
3. [Plafonds internes par type de table](#3-plafonds-internes-par-type-de-table)
4. [Seuils de volumétrie](#4-seuils-de-volumétrie)
5. [Que faire quand on dépasse un plafond](#5-que-faire-quand-on-dépasse-un-plafond)

---

## 1. Limites techniques par SGBD

Valeurs vérifiées le 16 septembre 2026 dans la documentation officielle (liens dans le [README](README.md#sources-officielles)). Elles peuvent évoluer d'une version à l'autre : en cas de doute, consulter la documentation de la version déployée.

### 1.1 Identifiants

| SGBD | Longueur max. | Unité | Comportement au-delà |
|------|---------------|-------|----------------------|
| PostgreSQL | 63 | octets | **Tronqué sans erreur** (avertissement seulement) |
| MySQL 8 | 64 (alias : 256) | caractères | Erreur |
| SQL Server | 128 (tables temporaires : 116) | caractères | Erreur |
| Oracle ≥ 12.2 | 128 | octets | Erreur |
| Oracle < 12.2 | 30 | octets | Erreur |
| Snowflake | 255 | caractères | Erreur |
| BigQuery | Colonne : 300 caractères ; table : 1 024 octets ; dataset : 1 024 caractères | — | Erreur |
| ClickHouse | Pas de limite documentée ; le nom devient un nom de fichier (~255 octets selon le système de fichiers) | — | Erreur système de fichiers |
| Iceberg | Définie par le catalogue (Glue : 255 caractères) | — | Selon catalogue |

### 1.2 Colonnes et lignes

| SGBD | Colonnes max. par table | Taille max. d'une ligne | Taille max. d'un champ |
|------|-------------------------|-------------------------|------------------------|
| PostgreSQL | 1 600 (réduit par la taille de page de 8 Ko) | 8 Ko en ligne ; les grands champs partent en TOAST (pointeur de 18 octets) | 1 Go |
| MySQL 8 (InnoDB) | 1 017 (limite serveur : 4 096) | 65 535 octets hors `BLOB`/`TEXT` ; un peu moins de 8 Ko en ligne avec des pages de 16 Ko | `LONGTEXT` : 4 Go |
| SQL Server | 1 024 (30 000 avec colonnes éparses) | 8 060 octets en ligne ; au-delà, débordement (pointeur de 24 octets) | `(MAX)` : 2 Go |
| Oracle | 1 000 (4 096 avec `MAX_COLUMNS=EXTENDED`, 23ai+) | Chaînage au-delà de 255 colonnes | `VARCHAR2` : 4 000 / 32 767 octets ; LOB : téraoctets |
| Snowflake | Pas de limite documentée stricte | Micro-partitions | `VARCHAR` : 128 Mo ; `BINARY` : 64 Mo |
| BigQuery | 10 000 (colonnes imbriquées comprises) | 100 Mo | Limité par la ligne |
| ClickHouse | Pas de limite stricte ; au-delà de quelques milliers, métadonnées et fusions ralentissent | Pas de limite pratique | `String` : pas de limite fixe |
| Iceberg | Pas de limite dans la spécification | Dépend de Parquet et du moteur | Dépend du moteur |

### 1.3 Index, clés et partitions

| SGBD | Colonnes max. par index | Taille max. d'une clé d'index | Index max. par table | Partitions max. |
|------|-------------------------|-------------------------------|----------------------|-----------------|
| PostgreSQL | 32 | ~2 700 octets (1/3 de page B-tree) | Illimité | Pratique : quelques milliers ; 32 colonnes de clé de partition |
| MySQL 8 (InnoDB) | 16 | 3 072 octets | 64 secondaires | 8 192 |
| SQL Server | 32 | 900 octets (cluster) / 1 700 (non cluster) | 1 cluster + 999 | 15 000 |
| Oracle | 32 (bitmap : 30) | Selon taille de bloc | Non défini | 1 024 000 − 1 |
| Snowflake | Pas d'index ; clé de clustering (3 à 4 colonnes conseillées) | — | — | Micro-partitions automatiques |
| BigQuery | Clustering : 4 colonnes | — | Index de recherche | 10 000 |
| ClickHouse | Clé de tri : pas de limite, 3 à 5 colonnes conseillées | — | Index de saut (skip) | Conseillé : < 1 000 par table |
| Iceberg | Ordre de tri libre | — | — | Pas de limite ; éviter plus de ~10 000 partitions actives |

### 1.4 Autres limites utiles

| SGBD | Limite | Valeur |
|------|--------|--------|
| PostgreSQL | Paramètres par requête (`executemany`, `IN (…)`) | 65 535 |
| PostgreSQL | Arguments de fonction | 100 |
| PostgreSQL | Taille d'une table | 32 To (pages de 8 Ko) |
| MySQL | `max_allowed_packet` (défaut 64 Mo) | Limite la taille d'un `INSERT` multi-lignes |
| SQL Server | Paramètres par procédure / requête | 2 100 |
| SQL Server | Taille d'une base | 524 272 To |
| Oracle | Éléments dans une liste `IN (…)` | 1 000 |
| BigQuery | Taille d'une requête SQL | 1 Mo (non résolue) |

Conséquence pour les chargements Airflow : **découper les lots** à 1 000 lignes vers Oracle et SQL Server, et au plus 65 535 / nombre de colonnes lignes par requête vers PostgreSQL (voir `orchestration/db/batch_loader.py`).

---

## 2. Plafonds internes transverses

| Élément | Plafond interne | Pourquoi |
|---------|-----------------|----------|
| Longueur d'un identifiant | **30 caractères** | Portable partout, lisible, pas de troncature PostgreSQL |
| Longueur d'un nom d'index ou de contrainte | 30 caractères | Idem |
| Profondeur de nommage | `base.schema.table` | Pas de 4e niveau (liens entre bases) dans le code applicatif |
| `VARCHAR(n)` | n ≤ 4 000 ; au-delà `TEXT` | Compatible Oracle standard et SQL Server en ligne |
| Colonnes dans un index | 5 | Au-delà, l'index est rarement utilisé en entier |
| Index par table OLTP | 10 | Chaque index ralentit les écritures |
| Index par table de faits PostgreSQL | 5 | Chargement en masse |
| Colonnes dans une clé primaire composite | 4 | Au-delà, créer une clé technique |
| Niveaux d'imbrication JSON exploités en SQL | 3 | Au-delà, aplatir en staging |
| Taille d'un document JSON | 1 Mo | Au-delà, stockage objet |
| Lignes par lot de chargement | 10 000 (1 000 vers Oracle/SQL Server) | Mémoire, verrous, limites de paramètres |

---

## 3. Plafonds internes par type de table

Nombre de colonnes **colonnes techniques comprises**.

| Type de table | Préfixe | Plafond conseillé | Plafond absolu | Remarque |
|---------------|---------|-------------------|----------------|----------|
| Table applicative | — | 30 | 50 | Au-delà : table trop « large », découper par sous-entité (1-1) |
| Table de référence | `ref_` | 15 | 30 | |
| Landing | `raw_` | = source | 250 | Au-delà : charger le surplus dans une colonne `JSONB` ou découper |
| Staging | `stg_` | 100 | 150 | Ne garder que les colonnes utiles en aval |
| Intermédiaire | `int_` | 100 | 150 | |
| Dimension | `dim_` | 60 | 100 | Au-delà : mini-dimension ou dimension « outrigger » |
| Table de faits | `fact_` | 30 | 50 | ≤ 20 clés de dimension, ≤ 25 mesures |
| Pont | `bridge_` | 6 | 10 | 2 clés + poids + colonnes techniques |
| Snapshot | `snp_` | 40 | 60 | |
| Agrégat | `agg_` | 50 | 100 | |
| Mart (moteur ligne : PostgreSQL, MySQL, SQL Server, Oracle) | `mart_` | 100 | 200 | |
| Mart (moteur colonne : ClickHouse, Snowflake, BigQuery, Iceberg) | `mart_` | 200 | 500 | Tables larges acceptables : seules les colonnes lues sont scannées |
| Audit | `audit_` | 20 | 30 | |

Pourquoi limiter même quand le moteur accepte plus :

- **PostgreSQL** : une ligne doit tenir dans une page de 8 Ko ; avec 1 600 colonnes `BIGINT` c'est impossible (1 600 × 8 = 12,8 Ko). Les colonnes supprimées comptent toujours dans la limite de 1 600 jusqu'à la réécriture de la table.
- **MySQL** : l'erreur `Row size too large` survient bien avant 1 017 colonnes dès qu'il y a des `VARCHAR`.
- **Toutes bases** : une table très large signale souvent un problème de modélisation (colonnes répétées `month_01` … `month_12`, attributs de plusieurs entités mélangés).

---

## 4. Seuils de volumétrie

Seuils indicatifs, pour PostgreSQL sur un serveur standard (8 vCPU, 32 Go RAM, SSD).

| Signal | Seuil | Action |
|--------|-------|--------|
| Lignes dans une table | > 50 millions | Partitionner (voir [06_PARTITIONING_PERFORMANCE.md](06_PARTITIONING_PERFORMANCE.md)) |
| Taille d'une table | > 20 Go | Partitionner, archiver |
| Croissance | > 1 million de lignes / jour | Partitionner dès la création |
| Taille d'une partition | > 10 Go ou < 10 Mo | Revoir la granularité |
| Nombre de partitions | > 1 000 | Granularité plus grossière |
| Temps d'un `VACUUM` | > 1 heure | Partitionner, ajuster l'autovacuum |
| Volume analytique total | > 500 Go ou requêtes BI > 30 s | Étudier ClickHouse, Snowflake, BigQuery ou Iceberg |

---

## 5. Que faire quand on dépasse un plafond

1. Vérifier d'abord la modélisation : colonnes répétées, entités mélangées, attributs rarement renseignés.
2. Découper :
   - OLTP : table 1-1 (`customer` + `customer_preference`).
   - Dimension : mini-dimension pour les attributs qui changent souvent, *outrigger* pour un groupe d'attributs cohérent.
   - Landing : colonne `JSONB` pour les attributs non utilisés.
3. Si le dépassement est justifié, **documenter la raison** dans le commentaire de la table et dans la merge request :

```sql
COMMENT ON TABLE marts.mart_customer_360 IS
  'Mart large (180 colonnes) : export BI demandé par la DG, validé en revue MR !142';
```
