-- =============================================================================
-- Modèle : table applicative OLTP (PostgreSQL) — back-end FastAPI, Django…
-- Convention : docs/database/01_NAMING.md §5 et 02_ARCHITECTURE_LAYERS.md §6
--
-- Remplacer :
--   <app_schema>  schéma du domaine applicatif (billing, auth…)
--   <entity>      entité au singulier, en anglais (invoice, user_account…)
--   <parent>      entité parente référencée (customer…)
-- En pratique, ce DDL est produit par une migration Alembic / Django / Flyway.
-- =============================================================================

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS <app_schema>.<entity> (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY,
    public_id           UUID          NOT NULL,              -- exposé dans l'API (UUID v7)
    <parent>_id         BIGINT        NOT NULL,

    -- Attributs métier
    <entity>_number     VARCHAR(30)   NOT NULL,
    label               VARCHAR(255)  NOT NULL,
    description         TEXT,
    total_amount        NUMERIC(18,2) NOT NULL DEFAULT 0,
    currency_code       CHAR(3)       NOT NULL,
    <entity>_status     VARCHAR(30)   NOT NULL DEFAULT 'draft',
    is_archived         BOOLEAN       NOT NULL DEFAULT false,
    due_date            DATE,

    -- Colonnes techniques
    version             INTEGER       NOT NULL DEFAULT 1,    -- verrouillage optimiste
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          VARCHAR(100),
    updated_by          VARCHAR(100),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT pk_<entity> PRIMARY KEY (id),
    CONSTRAINT uq_<entity>_public_id UNIQUE (public_id),
    CONSTRAINT fk_<entity>_<parent> FOREIGN KEY (<parent>_id)
        REFERENCES <app_schema>.<parent> (id) ON DELETE RESTRICT,
    CONSTRAINT ck_<entity>_total_amount CHECK (total_amount >= 0),
    CONSTRAINT ck_<entity>_status CHECK (<entity>_status IN ('draft', 'active', 'closed'))
);

-- Toute FK est indexée
CREATE INDEX IF NOT EXISTS ix_<entity>_<parent>_id
    ON <app_schema>.<entity> (<parent>_id);

-- Unicité métier limitée aux lignes non supprimées
CREATE UNIQUE INDEX IF NOT EXISTS ux_<entity>_number_active
    ON <app_schema>.<entity> (<entity>_number)
    WHERE deleted_at IS NULL;

-- Mise à jour automatique de updated_at
CREATE OR REPLACE FUNCTION <app_schema>.trg_fn_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_<entity>_bu ON <app_schema>.<entity>;
CREATE TRIGGER trg_<entity>_bu
    BEFORE UPDATE ON <app_schema>.<entity>
    FOR EACH ROW EXECUTE FUNCTION <app_schema>.trg_fn_set_updated_at();

COMMENT ON TABLE <app_schema>.<entity> IS '<Description métier de l''entité>';
COMMENT ON COLUMN <app_schema>.<entity>.public_id IS '[internal] Identifiant exposé par l''API';
