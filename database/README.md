# database — Administration PostgreSQL

Outil DBA du monorepo (scope d'installation `database`). Intégré depuis
`devops-database-manager`. **Outillage uniquement** : le runtime spécifique à un
projet (docker-compose, données) n'est volontairement pas embarqué ici.

## Commandes

Installées globalement via `devops-manager install --scope database` :

- **`pg-admin`** — CLI d'administration PostgreSQL : bases, schémas, utilisateurs,
  RBAC équipe data, permissions granulaires, sauvegarde/restore, monitoring, audit.
  Exécution locale, SSH ou Docker. Modes `--dry-run`, `--verbose`, `--yes`.
- **`db-connect`** — lanceur multi-serveurs : menu de profils défini dans
  `scripts/servers.conf`, puis délègue à `pg-admin`.

Sans installation, les scripts sont exécutables directement :

```bash
./database/scripts/pg-admin.sh --help
./database/scripts/connect.sh --server <id> db list
```

## Configuration

Les scripts lisent leurs propres fichiers de connexion (non versionnés — partez
des `*.example`) :

| Fichier                         | Rôle                                   |
| ------------------------------- | -------------------------------------- |
| `scripts/pg-config.conf`        | Connexion mono-serveur                 |
| `scripts/servers.conf`          | Profils multi-serveurs (INI)           |
| `scripts/desired/state.conf`    | État déclaratif (GitOps `state apply`) |

```bash
cp scripts/pg-config.conf.example scripts/pg-config.conf
cp scripts/servers.conf.example   scripts/servers.conf
```

> ⚠️ Ne jamais committer les fichiers réels ni les dossiers `logs/`, `backups/`,
> `.credentials/` — déjà couverts par `.gitignore`.

## Documentation

- `scripts/pg-admin.md`, `scripts/pg-admin-ext.md` — référence des commandes.
- `docs/` — standards de conception de base de données (nommage, couches,
  typage, clés/index, partitionnement, sécurité, migrations) + templates SQL.
