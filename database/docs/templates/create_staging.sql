-- =============================================================================
-- Modèle : table de staging (PostgreSQL)
-- Convention : docs/database/01_NAMING.md §4
--
-- Remplacer :
--   <domain>  schéma de domaine (finance, hr…) ou "staging"
--   <entity>  entité au singulier, en anglais (payment, employee…)
--   <source>  code du système source (sage, crm…)
-- =============================================================================

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS <domain>.stg_<entity> (
    -- Clé naturelle de la source
    <entity>_id         BIGINT        NOT NULL,

    -- Attributs métier (typés et renommés depuis landing.raw_<source>_<entity>)
    <entity>_code       VARCHAR(30)   NOT NULL,
    <entity>_name       VARCHAR(255),
    amount              NUMERIC(18,2),
    currency_code       CHAR(3),
    event_date          DATE,
    source_updated_at   TIMESTAMPTZ,

    -- Colonnes techniques
    source_system       VARCHAR(50)   NOT NULL DEFAULT '<source>',
    row_hash            CHAR(64)      NOT NULL,
    loaded_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    batch_id            VARCHAR(250)  NOT NULL,

    CONSTRAINT pk_stg_<entity> PRIMARY KEY (<entity>_id)
);

-- Chargement incrémental : l'upsert filtre sur la date de modification source
CREATE INDEX IF NOT EXISTS ix_stg_<entity>_source_updated_at
    ON <domain>.stg_<entity> (source_updated_at);

COMMENT ON TABLE <domain>.stg_<entity> IS
    'Staging <entity> : 1 ligne par <entity> source (<source>), dernier état connu.';
COMMENT ON COLUMN <domain>.stg_<entity>.row_hash IS
    'SHA-256 des attributs métier, pour détecter les changements';
COMMENT ON COLUMN <domain>.stg_<entity>.batch_id IS
    'run_id du DAG Airflow ayant chargé la ligne';
