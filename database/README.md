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

Fichiers de connexion (non versionnés — partez des `*.example`) :

| Fichier              | Rôle                                   |
| -------------------- | -------------------------------------- |
| `pg-config.conf`     | Connexion mono-serveur (`pg-admin`)    |
| `servers.conf`       | Profils multi-serveurs INI (`db-connect`) |
| `desired/state.conf` | État déclaratif (GitOps `state apply`) |

### Où placer la config

Résolution par fichier, dans l'ordre :

1. Variable d'env explicite : `PG_CONFIG_FILE` (mono-serveur) / `SERVERS_CONF_FILE` (multi).
2. **`~/.config/devops/`** (recommandé — emplacement stable, hors du clone géré).
3. Dossier du script (`database/scripts/`) — repli pour un checkout local.

L'emplacement `~/.config/devops/` (ou `$XDG_CONFIG_HOME/devops`, surchargeable via
`DEVOPS_CONFIG_HOME`) est recommandé en installation *managed* : il survit aux
mises à jour **et** à un `uninstall --remove-managed-source`.

```bash
mkdir -p ~/.config/devops
cp scripts/servers.conf.example   ~/.config/devops/servers.conf   && chmod 600 ~/.config/devops/servers.conf
cp scripts/pg-config.conf.example ~/.config/devops/pg-config.conf && chmod 600 ~/.config/devops/pg-config.conf
```

> ⚠️ Ne jamais committer les fichiers réels ni les dossiers `logs/`, `backups/`,
> `.credentials/` — déjà couverts par `.gitignore`.

## Documentation

- `scripts/pg-admin.md`, `scripts/pg-admin-ext.md` — référence des commandes.
- `docs/` — standards de conception de base de données (nommage, couches,
  typage, clés/index, partitionnement, sécurité, migrations) + templates SQL.
