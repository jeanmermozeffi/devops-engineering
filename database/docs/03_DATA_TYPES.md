# Types de données

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

## Table des matières

1. [Principes](#1-principes)
2. [Type recommandé par usage](#2-type-recommandé-par-usage)
3. [Correspondance entre SGBD](#3-correspondance-entre-sgbd)
4. [Pièges par SGBD](#4-pièges-par-sgbd)
5. [Encodage et collation](#5-encodage-et-collation)
6. [NULL et valeurs par défaut](#6-null-et-valeurs-par-défaut)

---

## 1. Principes

1. **Le type le plus précis qui couvre le besoin métier sur 10 ans.** Un code pays est `CHAR(2)`, pas `VARCHAR(255)`.
2. **Jamais de nombre à virgule flottante pour de l'argent** (`FLOAT`, `REAL`, `DOUBLE`) : `0.1 + 0.2 ≠ 0.3`.
3. **Jamais de date stockée en texte ou en entier** (sauf la clé `date_key` au format `YYYYMMDD` des dimensions).
4. **Horodatages en UTC**. La conversion vers `Africa/Abidjan` ou un autre fuseau se fait à l'affichage.
5. **Même concept, même type partout** : si `customer_id` est `BIGINT` dans une table, il l'est dans toutes.
6. **`NOT NULL` par défaut**, `NULL` seulement quand l'absence de valeur a un sens métier.
7. **Pas de `VARCHAR(255)` par réflexe** : la longueur documente la règle métier et protège contre les données aberrantes.

---

## 2. Type recommandé par usage

Types exprimés en PostgreSQL. Voir [§3](#3-correspondance-entre-sgbd) pour les autres moteurs.

| Usage | Type | Commentaire |
|-------|------|-------------|
| Clé technique OLTP | `BIGINT GENERATED ALWAYS AS IDENTITY` | `INTEGER` seulement pour les petites tables de référence |
| Clé exposée publiquement / distribuée | `UUID` (v7 de préférence) | v7 est ordonné dans le temps, donc les index B-tree restent compacts |
| Clé de substitution DWH | `BIGINT` | |
| Clé de date DWH | `INTEGER` | `YYYYMMDD` |
| Code métier court (pays, devise, langue) | `CHAR(2)` / `CHAR(3)` | ISO 3166-1, ISO 4217, ISO 639-1 |
| Code métier variable | `VARCHAR(30)` | |
| Nom, libellé | `VARCHAR(100)` à `VARCHAR(255)` | |
| Description, commentaire | `TEXT` | |
| E-mail | `VARCHAR(320)` | Limite RFC ; `CITEXT` pour ignorer la casse |
| Téléphone | `VARCHAR(20)` | Format E.164 (`+2250700000000`), jamais un nombre |
| URL | `VARCHAR(2048)` | |
| Montant | `NUMERIC(18,2)` | Jusqu'à 9 999 999 999 999 999,99. `NUMERIC(19,4)` pour les calculs intermédiaires ou les devises à 3 décimales |
| Prix unitaire, taux de change | `NUMERIC(19,6)` | |
| Taux (0 à 1) | `NUMERIC(9,6)` | |
| Pourcentage (0 à 100) | `NUMERIC(7,4)` | |
| Quantité entière | `INTEGER` | |
| Quantité décimale (poids, volume) | `NUMERIC(18,3)` | |
| Mesure scientifique, score ML | `DOUBLE PRECISION` | Seul cas légitime du flottant |
| Booléen | `BOOLEAN NOT NULL DEFAULT false` | |
| Date | `DATE` | |
| Horodatage | `TIMESTAMPTZ` | Stocké en UTC |
| Heure locale (horaire d'ouverture) | `TIME` | |
| Durée | `INTEGER` (secondes) ou `INTERVAL` | Préférer l'entier, plus portable |
| Statut | `VARCHAR(30)` + `CHECK` ou FK vers une table de référence | |
| Document semi-structuré | `JSONB` | Pas `JSON` : `JSONB` est indexable (GIN) |
| Empreinte SHA-256 | `CHAR(64)` (hex) ou `BYTEA` | |
| Fichier | Stockage objet (S3/MinIO) + `VARCHAR(1024)` pour le chemin | Pas de fichier binaire en base |
| Adresse IP | `INET` | |
| Coordonnées GPS | `GEOGRAPHY(POINT, 4326)` (PostGIS) | Ou deux `NUMERIC(9,6)` sans PostGIS |

---

## 3. Correspondance entre SGBD

| Concept | PostgreSQL | MySQL 8 | SQL Server | Oracle | ClickHouse | Snowflake | BigQuery | Iceberg |
|---------|-----------|---------|------------|--------|------------|-----------|----------|---------|
| Booléen | `BOOLEAN` | `BOOLEAN` (= `TINYINT(1)`) | `BIT` | `BOOLEAN` (23ai), sinon `NUMBER(1)` | `Bool` | `BOOLEAN` | `BOOL` | `boolean` |
| Entier 16 bits | `SMALLINT` | `SMALLINT` | `SMALLINT` | `NUMBER(5)` | `Int16` | `NUMBER(5,0)` | `INT64` | `int` |
| Entier 32 bits | `INTEGER` | `INT` | `INT` | `NUMBER(10)` | `Int32` | `NUMBER(10,0)` | `INT64` | `int` |
| Entier 64 bits | `BIGINT` | `BIGINT` | `BIGINT` | `NUMBER(19)` | `Int64` | `NUMBER(19,0)` | `INT64` | `long` |
| Décimal exact | `NUMERIC(p,s)` | `DECIMAL(p,s)` | `DECIMAL(p,s)` | `NUMBER(p,s)` | `Decimal(p,s)` | `NUMBER(p,s)` | `NUMERIC` / `BIGNUMERIC` | `decimal(p,s)` |
| Précision max. | 1 000 (déclarée) | 65 | 38 | 38 | 76 | 38 | 38 (échelle 9) / 76 | 38 |
| Flottant | `DOUBLE PRECISION` | `DOUBLE` | `FLOAT(53)` | `BINARY_DOUBLE` | `Float64` | `FLOAT` | `FLOAT64` | `double` |
| Texte court | `VARCHAR(n)` | `VARCHAR(n)` | `NVARCHAR(n)` | `VARCHAR2(n CHAR)` | `String` / `LowCardinality(String)` | `VARCHAR(n)` | `STRING` | `string` |
| Texte long | `TEXT` | `TEXT` / `LONGTEXT` | `NVARCHAR(MAX)` | `CLOB` | `String` | `VARCHAR` | `STRING` | `string` |
| Code fixe | `CHAR(n)` | `CHAR(n)` | `CHAR(n)` | `CHAR(n CHAR)` | `FixedString(n)` (octets) | `VARCHAR(n)` | `STRING` | `string` |
| Date | `DATE` | `DATE` | `DATE` | `DATE` ⚠ contient l'heure | `Date32` | `DATE` | `DATE` | `date` |
| Horodatage sans fuseau | `TIMESTAMP` | `DATETIME(6)` | `DATETIME2(6)` | `TIMESTAMP(6)` | `DateTime64(6)` | `TIMESTAMP_NTZ` | `DATETIME` | `timestamp` |
| Horodatage UTC | `TIMESTAMPTZ` | `DATETIME(6)` en UTC ⚠ | `DATETIMEOFFSET(6)` | `TIMESTAMP(6) WITH TIME ZONE` | `DateTime64(6, 'UTC')` | `TIMESTAMP_TZ` / `TIMESTAMP_LTZ` | `TIMESTAMP` | `timestamptz` |
| Heure | `TIME` | `TIME` | `TIME` | `INTERVAL DAY TO SECOND` | `Int32` (secondes) | `TIME` | `TIME` | `time` |
| UUID | `UUID` | `BINARY(16)` | `UNIQUEIDENTIFIER` | `RAW(16)` | `UUID` | `VARCHAR(36)` | `STRING` | `uuid` |
| JSON | `JSONB` | `JSON` | `NVARCHAR(MAX)` + `ISJSON` (type `json` sur Azure SQL / 2025) | `JSON` (21c+) | `JSON` | `VARIANT` | `JSON` | `variant` (v3) |
| Binaire | `BYTEA` | `VARBINARY` / `BLOB` | `VARBINARY(MAX)` | `BLOB` | `String` | `BINARY` | `BYTES` | `binary` |
| Tableau | `type[]` | `JSON` | — | `JSON` | `Array(T)` | `ARRAY` | `ARRAY<T>` | `list<T>` |
| Structure | type composite / `JSONB` | `JSON` | — | `OBJECT` / `JSON` | `Tuple` / `Nested` | `OBJECT` | `STRUCT` | `struct` |
| Énumération | `CHECK` ou table | `CHECK` ou table (éviter `ENUM`) | `CHECK` | `CHECK` | `LowCardinality(String)` / `Enum8` | `VARCHAR` | `STRING` | `string` |
| Géographie | `geography` (PostGIS) | `POINT` / `GEOMETRY` | `geography` | `SDO_GEOMETRY` | `Point` | `GEOGRAPHY` | `GEOGRAPHY` | `geography` (v3) |

⚠ = voir les pièges ci-dessous.

---

## 4. Pièges par SGBD

### PostgreSQL

- `VARCHAR(n)` et `TEXT` ont les mêmes performances. `VARCHAR(n)` sert à exprimer une règle métier.
- Ne jamais utiliser `MONEY` (dépend de `lc_monetary`), `TIMESTAMP` sans fuseau pour un instant, ni `SERIAL` (préférer `IDENTITY`).
- `NUMERIC` sans précision accepte n'importe quelle échelle : toujours préciser `(p,s)`.
- Un identifiant de plus de 63 octets est **tronqué sans erreur**.

### MySQL / MariaDB

- `utf8` = `utf8mb3` (3 octets, pas d'emoji) : toujours **`utf8mb4`**.
- `TIMESTAMP` est limité à la plage 1970–**2038** : utiliser `DATETIME(6)` et stocker en UTC (`time_zone = '+00:00'` sur la session).
- `ENUM` : l'ajout d'une valeur au milieu réécrit la table, et le tri se fait sur l'index interne.
- `sql_mode` doit inclure `STRICT_TRANS_TABLES`, sinon les valeurs trop longues sont tronquées silencieusement.
- La taille d'un index est comptée en octets (4 par caractère en `utf8mb4`) : `VARCHAR(768)` est le maximum indexable entièrement (3 072 octets).

### SQL Server

- `VARCHAR` n'est pas Unicode (sauf collation `_UTF8`, 2019+) : utiliser **`NVARCHAR`** pour les noms et libellés.
- `DATETIME` a une précision de 3,33 ms : utiliser `DATETIME2`.
- Ne jamais utiliser `MONEY`/`SMALLMONEY` (arrondis en division), ni `TEXT`/`NTEXT`/`IMAGE` (obsolètes).
- `FLOAT` sans paramètre = `FLOAT(53)`.

### Oracle

- **Chaîne vide = `NULL`** : `WHERE col = ''` ne renvoie jamais rien. Le code applicatif doit en tenir compte.
- `DATE` contient les heures, minutes et secondes : filtrer avec `TRUNC(col)` ou avec un intervalle.
- `VARCHAR2(n)` compte en **octets** par défaut (`NLS_LENGTH_SEMANTICS=BYTE`) : écrire `VARCHAR2(n CHAR)`.
- `VARCHAR2` est limité à 4 000 octets (32 767 si `MAX_STRING_SIZE=EXTENDED`).
- `NUMBER` sans précision stocke jusqu'à 38 chiffres ; les pilotes Python le lisent parfois en `float`. Toujours préciser `(p,s)`.

### ClickHouse

- `Nullable(T)` a un coût (fichier de masque supplémentaire) et ne peut pas faire partie de la clé de tri : préférer une valeur par défaut (`''`, `0`, `1970-01-01`).
- `LowCardinality(String)` pour les colonnes à moins de ~10 000 valeurs distinctes (statut, pays).
- `DateTime` est à la seconde et en 32 bits (jusqu'en 2106). `Date` va de 1970 à 2149 : utiliser `Date32` pour des dates de naissance.
- Pas de contrainte d'unicité : la déduplication passe par `ReplacingMergeTree` + `FINAL` ou par une agrégation.
- Les noms sont **sensibles à la casse**.

### Snowflake

- `NUMBER` sans précision = `NUMBER(38,0)` : un montant déclaré `NUMBER` perd ses décimales.
- `VARCHAR` sans longueur = 16 777 216 caractères (maximum 128 Mo) ; aucun coût de stockage, mais les outils BI allouent parfois selon la longueur déclarée : préciser `n`.
- Trois types d'horodatage : `TIMESTAMP_NTZ` (défaut), `TIMESTAMP_LTZ`, `TIMESTAMP_TZ`. Fixer `TIMESTAMP_TYPE_MAPPING` au niveau du compte.
- Les contraintes PK/FK/UNIQUE sont **déclaratives, non appliquées** (sauf tables hybrides).

### BigQuery

- `NUMERIC` = précision 38 et **échelle 9** fixe ; au-delà, utiliser `BIGNUMERIC`.
- `DATETIME` n'a pas de fuseau, `TIMESTAMP` est toujours en UTC.
- Pas de longueur maximale déclarée par défaut (`STRING`), mais `STRING(n)` est possible pour documenter la règle.
- Contraintes PK/FK **non appliquées** (utiles à l'optimiseur seulement).

### Apache Iceberg

- `decimal(p,s)` : l'échelle ne peut pas changer, la précision peut seulement augmenter (≤ 38).
- Promotions autorisées : `int → long`, `float → double`, `decimal(p,s) → decimal(p',s)` avec `p' > p`. Tout autre changement impose une nouvelle colonne.
- `timestamp` et `timestamptz` sont en microsecondes ; `timestamp_ns`, `variant` et `geometry` exigent le format **v3**.
- Le type réellement lu dépend du moteur (Spark, Trino, Snowflake) : tester la lecture sur chaque moteur consommateur.

---

## 5. Encodage et collation

| SGBD | Réglage recommandé |
|------|--------------------|
| PostgreSQL | `ENCODING 'UTF8'`, `LC_COLLATE`/`LC_CTYPE` = `C.UTF-8` ou ICU `und-x-icu` ; collation ICU non déterministe si besoin d'insensibilité à la casse ou aux accents |
| MySQL | `utf8mb4` + `utf8mb4_0900_ai_ci` (insensible casse/accents) ou `utf8mb4_0900_as_cs` pour les codes |
| SQL Server | `Latin1_General_100_CI_AS_SC_UTF8` (2019+) ou `French_100_CI_AS` + `NVARCHAR` |
| Oracle | `AL32UTF8` pour la base, `NLS_LENGTH_SEMANTICS=CHAR` |
| Snowflake / BigQuery / ClickHouse / Iceberg | UTF-8 natif ; comparer avec `LOWER()` ou une collation explicite |

Règle : **la collation se choisit à la création de la base** ; la changer plus tard impose de reconstruire les index.

---

## 6. NULL et valeurs par défaut

| Situation | Choix |
|-----------|-------|
| Valeur inconnue au moment de la saisie | `NULL` |
| Valeur absente par nature (pas de date de fin pour un contrat en cours) | `NULL` |
| Booléen | `NOT NULL DEFAULT false` |
| Compteur, montant cumulé | `NOT NULL DEFAULT 0` |
| Horodatages techniques | `NOT NULL DEFAULT now()` (`CURRENT_TIMESTAMP`, `SYSUTCDATETIME()`, `SYSTIMESTAMP`) |
| Clé de dimension en DWH | `NOT NULL`, `-1` si inconnue |
| Texte en DWH | `NULL` en staging ; `'Unknown'` ou `'N/A'` dans les dimensions pour les libellés affichés |
| ClickHouse | Valeur par défaut plutôt que `Nullable` (voir §4) |

Éviter les « valeurs magiques » en OLTP (`1900-01-01`, `-999`) : elles faussent les agrégats. Elles sont tolérées uniquement pour `valid_to = 9999-12-31` et pour les membres inconnus des dimensions.
