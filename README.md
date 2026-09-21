# devops-engineering

Gestionnaire DevOps Bash avec installation modulaire et mise à jour interactive.

## Objectif

Installer globalement une ou plusieurs parties du projet sans imposer la copie manuelle complète à chaque poste:

- `deployment` (commande `devops`)
- `git-devops` (commande `git-deploy` + alias `git deploy`)
- `database` (commandes `pg-admin` + `db-connect` — administration PostgreSQL)
- `all` (les trois)

## Installation rapide (bootstrap, sans clone préalable)

Si vous n'avez **pas encore** cloné le dépôt, n'essayez pas `./install.sh` (le fichier
n'existe pas sur votre poste). Utilisez le mode bootstrap : le script se clone lui-même puis
délègue l'installation.

```bash
# Installation complète, non interactive, depuis main
curl -fsSL https://raw.githubusercontent.com/jeanmermozeffi/devops-engineering/main/install.sh | bash -s -- \
  --non-interactive \
  --scope all \
  --source managed \
  --ref main
```

```bash
# Version interactive (choix du scope, du bin dir, etc.)
curl -fsSL https://raw.githubusercontent.com/jeanmermozeffi/devops-engineering/main/install.sh | bash
```

Points d'attention:

- `bash -s --` est **obligatoire** pour transmettre les options quand le script est lu depuis
  l'entrée standard (`curl | bash`). Les options placées directement après `bash` seraient
  ignorées.
- Le dépôt est cloné dans `~/.local/share/devops-enginering/repo` (ou `XDG_DATA_HOME`).
- Le dépôt source par défaut est `https://github.com/jeanmermozeffi/devops-engineering.git`.
  Pour en cibler un autre, ajoutez `--repo-url <url>` ou exportez `DEVOPS_REPO_URL`.

Les sections suivantes (`./install.sh ...`) supposent que vous êtes **dans un clone local** du dépôt.

## Scripts disponibles

- `./install.sh` : installation (interactive par défaut)
- `./update.sh` : mise à jour (interactive par défaut)
- `./uninstall.sh` : désinstallation (interactive par défaut)
- `./devops-manager.sh status` : afficher l'état installé

## Installation interactive

```bash
./install.sh
```

Le mode interactif permet de choisir:

- le scope (`all`, `deployment`, `git-devops`, `database`)
- le mode source:
  - `managed` (recommandé): clone géré localement pour faciliter les updates
  - `local`: utilise directement le checkout courant
- le `bin dir` (ex: `~/.local/bin`)
- l'alias Git `git deploy`

## Installation non interactive

Exemple (installation complète depuis la branche `main`):

```bash
./install.sh \
  --non-interactive \
  --scope all \
  --source managed \
  --repo-url https://github.com/<org>/<repo>.git \
  --ref main
```

Exemple (installer seulement `deployment` depuis le checkout local):

```bash
./install.sh --non-interactive --scope deployment --source local
```

Exemple (installer seulement l'outil base de données `database`) :

```bash
./install.sh --non-interactive --scope database --source local
```

Le scope `database` installe deux commandes globales :

- `pg-admin` : CLI d'administration PostgreSQL (bases, schémas, RBAC, sauvegardes, monitoring, audit).
- `db-connect` : lanceur multi-serveurs (menu de profils défini dans `database/scripts/servers.conf`).

Les configs réelles (`pg-config.conf`, `servers.conf`, …) ne sont **pas** versionnées ; partez des `*.example` de `database/scripts/`.

## Mises à jour

Mode interactif:

```bash
./update.sh
```

Actions disponibles selon le mode source:

- `latest` (ref suivie)
- `version` (tag/ref spécifique)
- `rollback` (commit précédent mémorisé)
- `reinstall` (recréation des liens sans changer de ref)

Exemples non interactifs:

```bash
# Mettre à jour vers la ref suivie
./update.sh --non-interactive --latest

# Mettre à jour vers un tag précis
./update.sh --non-interactive --version v1.2.3

# Rollback
./update.sh --non-interactive --rollback
```

## Désinstallation

Mode interactif:

```bash
./uninstall.sh
```

Exemples non interactifs:

```bash
# Retirer seulement git-devops
./uninstall.sh --non-interactive --scope git-devops

# Retirer seulement l'outil base de données
./uninstall.sh --non-interactive --scope database

# Retirer tout + alias git + dossier source managed
./uninstall.sh --non-interactive --scope all --remove-git-alias --remove-managed-source
```

## Où l'état est stocké

Le manifeste d'installation est écrit ici:

`~/.local/state/devops-enginering/install.env` (ou `XDG_STATE_HOME` si défini)

Il contient notamment:

- source utilisée
- ref suivie
- scopes installés
- commit/version courants et précédents

## Vérifier l'installation

```bash
./devops-manager.sh status
```
