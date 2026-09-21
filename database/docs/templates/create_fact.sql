-- =============================================================================
-- Modèle : table de faits transactionnelle partitionnée (PostgreSQL)
-- Convention : docs/database/02_ARCHITECTURE_LAYERS.md §4.1
--              docs/database/06_PARTITIONING_PERFORMANCE.md §2
--
-- Remplacer :
--   <domain>  schéma de domaine (finance, sales…) ou "dwh"
--   <event>   événement au singulier, en anglais (payment, order_line…)
--
-- Grain : 1 ligne par <event>. À préciser AVANT d'ajouter des colonnes.
-- =============================================================================

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS <domain>.fact_<event> (
    -- Clé de substitution + clé de partition (la clé de partition fait partie de la PK)
    <event>_key         BIGINT GENERATED ALWAYS AS IDENTITY,
    event_at            TIMESTAMPTZ   NOT NULL,

    -- Clés de dimensions (jamais NULL : -1 = inconnu)
    event_date_key      INTEGER       NOT NULL,           -- YYYYMMDD -> dwh.dim_date
    customer_key        BIGINT        NOT NULL DEFAULT -1,
    product_key         BIGINT        NOT NULL DEFAULT -1,

    -- Dimension dégénérée
    <event>_number      VARCHAR(30)   NOT NULL,

    -- Mesures additives
    quantity            NUMERIC(18,3) NOT NULL DEFAULT 0,
    gross_amount        NUMERIC(18,2) NOT NULL DEFAULT 0,
    discount_amount     NUMERIC(18,2) NOT NULL DEFAULT 0,
    net_amount          NUMERIC(18,2) NOT NULL DEFAULT 0,
    currency_code       CHAR(3)       NOT NULL,

    -- Colonnes techniques
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    loaded_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    batch_id            VARCHAR(250)  NOT NULL,

    CONSTRAINT pk_fact_<event> PRIMARY KEY (<event>_key, event_at),
    CONSTRAINT ck_fact_<event>_net_amount CHECK (net_amount = gross_amount - discount_amount)
) PARTITION BY RANGE (event_at);

-- Partitions mensuelles (à créer à l'avance par pg_partman ou un DAG de maintenance)
CREATE TABLE IF NOT EXISTS <domain>.fact_<event>_p2026_09
    PARTITION OF <domain>.fact_<event>
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

CREATE TABLE IF NOT EXISTS <domain>.fact_<event>_default
    PARTITION OF <domain>.fact_<event> DEFAULT;

-- Index : clés de dimensions filtrées fréquemment + BRIN sur le temps
CREATE INDEX IF NOT EXISTS ix_fact_<event>_customer_key
    ON <domain>.fact_<event> (customer_key);
CREATE INDEX IF NOT EXISTS brin_fact_<event>_loaded_at
    ON <domain>.fact_<event> USING brin (loaded_at);

-- Clés étrangères vers les dimensions : déclarées pour la documentation.
-- NOT VALID évite le scan complet ; valider hors chargement si nécessaire.
-- ALTER TABLE <domain>.fact_<event>
--     ADD CONSTRAINT fk_fact_<event>_dim_customer
--     FOREIGN KEY (customer_key) REFERENCES dwh.dim_customer (customer_key) NOT VALID;

COMMENT ON TABLE <domain>.fact_<event> IS
    'Faits <event>. Grain : 1 ligne par <event>. Partitionnée par mois sur event_at.';
COMMENT ON COLUMN <domain>.fact_<event>.net_amount IS
    'Montant net = gross_amount - discount_amount, dans currency_code';
