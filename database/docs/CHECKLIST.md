# Checklist de revue d'un changement de schéma

> **Rédigé par :** Jean Mermoz Effi
> **Dernière mise à jour :** 16 septembre 2026
> **Version :** 1.0.0

---

À copier dans la description de la merge request pour toute création ou modification de table.

```markdown
## Revue schéma base de données

### Nommage (01_NAMING.md)
- [ ] Anglais, snake_case, minuscules, sans guillemets, ≤ 30 caractères
- [ ] Schéma = domaine (`finance`, `hr`…) ou couche (`landing`, `staging`, `dwh`, `marts`, `audit`)
- [ ] Table analytique préfixée (`raw_`, `stg_`, `int_`, `dim_`, `fact_`, `bridge_`, `snp_`, `agg_`, `mart_`, `ref_`, `audit_`) ; table applicative sans préfixe
- [ ] Préfixe cohérent avec le schéma de couche (`landing` → `raw_`, `staging` → `stg_`/`int_`…)
- [ ] Nom au singulier, sans mot réservé seul, sans environnement ni date
- [ ] Colonnes avec suffixes sémantiques (`_id`, `_key`, `_code`, `_at`, `_date`, `_amount`, `is_`…)
- [ ] Contraintes et index nommés explicitement (`pk_`, `fk_`, `uq_`, `ck_`, `ix_`)
- [ ] Validé par `orchestration.db.naming.validate_table_name`

### Modélisation (02_ARCHITECTURE_LAYERS.md)
- [ ] Grain déclaré (tables de faits) dans `COMMENT ON TABLE`
- [ ] Type d'historisation choisi (SCD 1 / 2 / snapshot) et justifié
- [ ] Pas de lecture d'une couche amont sautée (marts ne lit pas landing)
- [ ] Dimensions partagées réutilisées (`dwh.dim_date`, `dwh.dim_customer`), pas dupliquées
- [ ] OLTP : 3NF, pas de colonnes répétées (`phone_1`, `phone_2`…)

### Types (03_DATA_TYPES.md)
- [ ] Montants en décimal exact avec devise associée
- [ ] Horodatages en `TIMESTAMPTZ` (ou équivalent UTC)
- [ ] Longueurs de `VARCHAR` justifiées, ≤ 4 000
- [ ] `NOT NULL` par défaut, `NULL` justifié
- [ ] Même type que les colonnes homonymes des autres tables
- [ ] Pièges du moteur vérifiés (Oracle '' = NULL, MySQL utf8mb4, Snowflake NUMBER(38,0)…)

### Limites (04_LIMITS_BY_DBMS.md)
- [ ] Nombre de colonnes sous le plafond du type de table (dépassement justifié en commentaire)
- [ ] Volumétrie estimée à 1 an et 5 ans : ______ lignes / ______ Go
- [ ] Partitionnement prévu si le seuil est atteint

### Clés et index (05_KEYS_INDEXES_CONSTRAINTS.md)
- [ ] Clé primaire définie (technique ou substitution)
- [ ] Clés métier protégées par `UNIQUE`
- [ ] FK déclarées (OLTP) et **toutes indexées**
- [ ] Index justifiés par une requête réelle (plan d'exécution joint si table > 1 Go)
- [ ] Pas d'index redondant

### Colonnes techniques (01_NAMING.md §8)
- [ ] `created_at` / `updated_at` (OLTP, dwh)
- [ ] `loaded_at` / `batch_id` (couches analytiques)
- [ ] `valid_from` / `valid_to` / `is_current` / `row_hash` (SCD 2)

### Sécurité (07_SECURITY_ACCESS.md)
- [ ] Colonnes classées (`public`, `internal`, `confidential`, `restricted`) dans les commentaires
- [ ] Données personnelles minimisées, pseudonymisées en DWH
- [ ] Droits attribués à des rôles, via `ALTER DEFAULT PRIVILEGES` / `state.conf`
- [ ] Aucun secret dans le code

### Migration (08_MIGRATIONS_DDL.md)
- [ ] Fichier de migration versionné, nommé `V<timestamp>__<verb>_<object>.sql` (ou Alembic)
- [ ] Idempotent et réversible (ou irréversibilité déclarée)
- [ ] Sans verrou long en production (`CONCURRENTLY`, `NOT VALID`, `lock_timeout`)
- [ ] Tables et colonnes commentées
- [ ] Testé en local et en CI sur une base éphémère
- [ ] Rétention et purge définies
```
