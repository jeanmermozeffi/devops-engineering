# pg-admin.sh — Documentation

> **PostgreSQL Admin CLI v3.0 — CICBI**  
> Outil d'administration interactif orienté Data Team : gestion des bases, schémas, utilisateurs, RBAC, permissions, backup et monitoring.

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Prérequis & installation](#2-prérequis--installation)
3. [Configuration](#3-configuration)
   - 3.1 [Création du fichier de config](#31-création-du-fichier-de-config)
   - 3.2 [Variables disponibles](#32-variables-disponibles)
   - 3.3 [Profils multiples (dev / staging / prod)](#33-profils-multiples-dev--staging--prod)
   - 3.4 [Mode de connexion : local vs SSH](#34-mode-de-connexion--local-vs-ssh)
4. [Utilisation — Mode interactif](#4-utilisation--mode-interactif)
5. [Utilisation — Mode CLI](#5-utilisation--mode-cli)
6. [RBAC — Gestion des profils Data Team](#6-rbac--gestion-des-profils-data-team)
   - 6.1 [Hiérarchie des rôles](#61-hiérarchie-des-rôles)
   - 6.2 [Initialisation](#62-initialisation)
   - 6.3 [Appliquer un profil sur un schéma](#63-appliquer-un-profil-sur-un-schéma)
   - 6.4 [Assigner un profil à un utilisateur](#64-assigner-un-profil-à-un-utilisateur)
   - 6.5 [Matrice des permissions](#65-matrice-des-permissions)
7. [Référence des commandes](#7-référence-des-commandes)
8. [Sécurité](#8-sécurité)
9. [Audit & journalisation](#9-audit--journalisation)
10. [Cas d'usage courants](#10-cas-dusage-courants)
11. [Structure des fichiers](#11-structure-des-fichiers)
12. [Résolution de problèmes](#12-résolution-de-problèmes)
   - 12.1 [`zsh: killed ./scripts/pg-admin.sh`](#121-zsh-killed-scriptspg-adminsh)
   - 12.2 [Connexion PostgreSQL échouée ou bloquée](#122-connexion-postgresql-échouée-ou-bloquée)

---

## 1. Vue d'ensemble

`pg-admin.sh` est un script Bash unique qui consolide et améliore les anciens `pg-manager.sh` et `pg-manager-v2.sh`. Il offre :

| Fonctionnalité | Détail |
|---|---|
| Interface interactive | Menus numérotés avec sous-menus par domaine |
| CLI non-interactif | Toutes les commandes accessibles en ligne de commande |
| RBAC Data Team | 5 profils pré-définis (Engineer, Analyst, BI User, Service, Admin) |
| Sécurité renforcée | Validation des entrées, PGPASSFILE, protection injection SQL |
| Dry-run | Affiche le SQL sans l'exécuter |
| Audit log | Journalisation de toutes les actions dans `logs/` |
| Multi-environnement | Plusieurs fichiers de config (dev/staging/prod) |
| Connexion locale & SSH | psql local ou exécution via tunnel SSH |

---

## 2. Prérequis & installation

### Prérequis

| Outil | Mode local | Mode SSH |
|---|---|---|
| `psql` | **Requis** | Non requis |
| `pg_dump` | **Requis** (backup) | Non requis |
| `ssh` | Non requis | **Requis** |
| `openssl` / `tr` | Requis | Requis |

**Installation de psql :**

```bash
# macOS
brew install postgresql

# Ubuntu / Debian
sudo apt-get install postgresql-client

# CentOS / RHEL
sudo yum install postgresql
```

### Installation du script

```bash
cd /Users/jeanmermozeffi/PycharmProjects/db-analytics-oscrum/scripts/

# Rendre le script exécutable (déjà fait)
chmod +x pg-admin.sh

# Créer votre configuration
cp pg-config.conf.example pg-config.conf
chmod 600 pg-config.conf   # OBLIGATOIRE — fichier contient des secrets

# Tester
./pg-admin.sh test
```

---

## 3. Configuration

### 3.1 Création du fichier de config

```bash
cp pg-config.conf.example pg-config.conf
chmod 600 pg-config.conf
```

> **Important :** `pg-config.conf` est dans `.gitignore`. Ne jamais le committer.

### 3.2 Variables disponibles

| Variable | Description | Défaut |
|---|---|---|
| `PG_HOST` | Adresse du serveur PostgreSQL | `localhost` |
| `PG_PORT` | Port PostgreSQL | `5432` |
| `PG_ADMIN_USER` | Utilisateur administrateur | `postgres` |
| `PG_ADMIN_PASSWORD` | Mot de passe administrateur | *(vide)* |
| `PG_DEFAULT_DB` | Base de données par défaut | `postgres` |
| `USE_SSH` | Mode de connexion : `local` ou `ssh` | `local` |
| `SSH_HOST` | Adresse du serveur SSH | *(vide)* |
| `SSH_PORT` | Port SSH | `22` |
| `SSH_USER` | Utilisateur SSH | `root` |
| `SSH_KEY` | Chemin vers la clé privée SSH | *(vide)* |

Toutes ces variables peuvent aussi être surchargées via l'environnement shell :

```bash
PG_HOST=203.0.113.10 PG_PORT=5435 ./pg-admin.sh db list
```

### 3.3 Profils multiples (dev / staging / prod)

Le script supporte plusieurs fichiers de configuration. Créez un fichier par environnement :

```
scripts/
├── pg-config.conf              ← actif par défaut (gitignored)
├── pg-config.dev.conf          ← base locale développement
├── pg-config.staging.conf      ← VPS staging
├── pg-config.prod.conf         ← VPS production
└── pg-config.conf.example      ← modèle de référence (versionné)
```

**Utilisation :**

```bash
# Connexion à staging
PG_CONFIG_FILE=./pg-config.staging.conf ./pg-admin.sh db list

# Connexion à production
PG_CONFIG_FILE=./pg-config.prod.conf ./pg-admin.sh perm audit db-analytics-oscrum

# Audit dry-run sur prod (preview sans exécuter)
PG_CONFIG_FILE=./pg-config.prod.conf ./pg-admin.sh --dry-run rbac apply db-analytics-oscrum dwh analyst
```

**Créer des alias pratiques :**

```bash
# Dans ~/.zshrc ou ~/.bashrc
alias pg-dev="PG_CONFIG_FILE=~/PycharmProjects/db_analytics_oscrum/scripts/pg-config.dev.conf \
              ~/PycharmProjects/db_analytics_oscrum/scripts/pg-admin.sh"

alias pg-staging="PG_CONFIG_FILE=~/PycharmProjects/db_analytics_oscrum/scripts/pg-config.staging.conf \
                  ~/PycharmProjects/db_analytics_oscrum/scripts/pg-admin.sh"

alias pg-prod="PG_CONFIG_FILE=~/PycharmProjects/db_analytics_oscrum/scripts/pg-config.prod.conf \
               ~/PycharmProjects/db_analytics_oscrum/scripts/pg-admin.sh"
```

```bash
# Utilisation des alias
pg-staging db list
pg-prod perm audit db-analytics-oscrum
```

### 3.4 Mode de connexion : local vs SSH

#### Mode `local` (recommandé si le port PostgreSQL est accessible)

```
[Machine locale]
    psql → [PG_HOST:PG_PORT]
```

Le script utilise `psql` installé localement pour se connecter directement à PostgreSQL.  
Fonctionne si le port PostgreSQL est ouvert (pare-feu, Docker port binding, etc.).

```ini
USE_SSH="local"
PG_HOST="203.0.113.10"
PG_PORT="5435"
```

#### Mode `ssh` (si le port PostgreSQL n'est pas accessible en direct)

```
[Machine locale]
    ssh → [Serveur SSH] → psql → [localhost:PG_PORT]
```

Le script se connecte au serveur via SSH, puis exécute `psql` à distance.  
PostgreSQL n'a pas besoin d'être accessible depuis l'extérieur.

```ini
USE_SSH="ssh"
PG_HOST="localhost"       # localhost vu DEPUIS le serveur SSH
PG_PORT="5435"
SSH_HOST="203.0.113.10"
SSH_PORT="22"
SSH_USER="deploy"
SSH_KEY="~/.ssh/id_rsa_example"
```

---

## 4. Utilisation — Mode interactif

```bash
./pg-admin.sh
```

Le script démarre avec un menu principal numéroté :

```
  ╔════════════════════════════════════════════════════════╗
  ║     PostgreSQL Admin CLI  v3.0  —  CICBI               ║
  ╚════════════════════════════════════════════════════════╝

  Connexion : admin_analytics_oscrum@203.0.113.10:5435/db_analytics_oscrum
  Mode      : local       Dry-run : false

  MENU PRINCIPAL

  1  Bases de données
  2  Schémas
  3  Utilisateurs
  4  RBAC / Profils Data
  5  Permissions granulaires
  6  Audit & Rapports
  7  Backup & Restauration
  8  Monitoring
  9  Paramètres & Connexion

  0  Quitter
```

Chaque option ouvre un **sous-menu dédié** avec retour possible vers le menu principal (`0`).

**Exemple — sous-menu RBAC :**

```
  4 › RBAC / PROFILS DATA

  1  Lister les rôles
  2  Initialiser les rôles RBAC (1 fois par base)
  3  Appliquer profil(s) sur schéma(s)   (engineer/analyst/bi × schémas)
  4  Assigner un profil à un utilisateur
  5  Révoquer un profil d'un utilisateur
  6  Réparer toutes les permissions (après migration Airflow)

  Profils : engineer · analyst · bi · service/admin (assign uniquement)

  0  ← Retour
```

> **Option 3 unifiée** : un seul écran demande le(s) profil(s) **et** le(s) schéma(s)
> (sélection multiple), puis applique le produit profil×schéma en une passe. Les profils
> `service` et `admin` ne s'appliquent pas à un schéma : `service` se configure via
> `perm grant-table`, `admin` s'assigne à un utilisateur via l'option 4.

---

## 5. Utilisation — Mode CLI

```bash
./pg-admin.sh [options] <commande> <sous-commande> [arguments]
```

### Options globales

| Option | Description |
|---|---|
| `--dry-run` | Affiche le SQL sans exécuter — aucune modification en base |
| `--verbose` | Logs de debug détaillés |
| `--help`, `-h` | Affiche l'aide complète |

### Commandes disponibles

```bash
# Bases de données
./pg-admin.sh db list
./pg-admin.sh db create <nom> [owner]
./pg-admin.sh db drop   <nom>

# Schémas
./pg-admin.sh schema list   <db>
./pg-admin.sh schema create <db> <schema> [owner]
./pg-admin.sh schema drop   <db> <schema> [cascade]

# Utilisateurs
./pg-admin.sh user list
./pg-admin.sh user create <user> [password] [profile]
./pg-admin.sh user drop   <user>
./pg-admin.sh user passwd <user> [newpassword]
./pg-admin.sh user lock   <user>
./pg-admin.sh user unlock <user>

# RBAC
./pg-admin.sh rbac roles
./pg-admin.sh rbac init   <db>
./pg-admin.sh rbac apply  <db> <schema> <profil>
./pg-admin.sh rbac assign <user> <profil>
./pg-admin.sh rbac revoke <user> <profil>

# Permissions
./pg-admin.sh perm grant       <user> <db> <type> [schema]
./pg-admin.sh perm grant-table <user> <db> <schema> <table> [privs]
./pg-admin.sh perm revoke      <user> <db> [schema]
./pg-admin.sh perm show        <user> [db]
./pg-admin.sh perm audit       [db]

# Backup
./pg-admin.sh backup  <db> [répertoire]
./pg-admin.sh restore <db> <fichier.sql.gz>

# Monitoring
./pg-admin.sh monitor stats
./pg-admin.sh monitor connections
./pg-admin.sh monitor slow [seuil_ms]
./pg-admin.sh monitor locks
./pg-admin.sh monitor kill <db>

# Connexion
./pg-admin.sh test
./pg-admin.sh config
```

---

## 6. RBAC — Gestion des profils Data Team

### 6.1 Hiérarchie des rôles

```
role_db_admin
│
├── role_data_engineer    ← DDL + DML complet
├── role_data_analyst     ← SELECT (schémas analytiques)
├── role_bi_user          ← SELECT (marts uniquement)
└── role_service_account  ← Aucun droit par défaut
```

Les rôles sont des **groupes** (pas de LOGIN). Ils sont assignés à des utilisateurs avec `GRANT role TO user`.

### 6.2 Initialisation

À effectuer **une seule fois** par base de données :

```bash
./pg-admin.sh rbac init db-analytics-oscrum
```

Cela crée les 5 rôles et accorde `CONNECT ON DATABASE` aux rôles qui en ont besoin.

### 6.3 Appliquer un profil sur un schéma

```bash
# Donner les droits Engineer sur le schéma staging
./pg-admin.sh rbac apply db-analytics-oscrum staging engineer

# Donner les droits Engineer sur dwh également
./pg-admin.sh rbac apply db-analytics-oscrum dwh engineer

# Donner les droits Analyst sur dwh et marts
./pg-admin.sh rbac apply db-analytics-oscrum dwh    analyst
./pg-admin.sh rbac apply db-analytics-oscrum marts  analyst

# Donner les droits BI User sur marts uniquement
./pg-admin.sh rbac apply db-analytics-oscrum marts bi
```

> **Note :** Les permissions incluent automatiquement les **futurs objets** (`ALTER DEFAULT PRIVILEGES`).

### 6.4 Assigner un profil à un utilisateur

```bash
# Créer l'utilisateur
./pg-admin.sh user create alice "" analyst

# Assigner le profil
./pg-admin.sh rbac assign alice analyst

# Vérifier
./pg-admin.sh perm show alice db-analytics-oscrum
```

### 6.5 Matrice des permissions

| Permission | `role_db_admin` | `role_data_engineer` | `role_data_analyst` | `role_bi_user` | `role_service_account` |
|---|:---:|:---:|:---:|:---:|:---:|
| CONNECT database | ✓ | ✓ | ✓ | ✓ | — |
| USAGE schema | ✓ | ✓ | ✓ | ✓ (marts) | — |
| CREATE schema | ✓ | ✓ | — | — | — |
| SELECT | ✓ | ✓ | ✓ | ✓ (marts) | — |
| INSERT / UPDATE / DELETE | ✓ | ✓ | — | — | — |
| TRUNCATE | ✓ | ✓ | — | — | — |
| CREATE TABLE / VIEW | ✓ | ✓ | — | — | — |
| EXECUTE functions | ✓ | ✓ | — | — | — |
| ALL PRIVILEGES (base) | ✓ | — | — | — | — |

> `role_service_account` : aucun droit par défaut — configurer manuellement avec `perm grant-table`.

---

## 7. Référence des commandes

### Gestion des utilisateurs

```bash
# Créer avec mot de passe auto-généré, profil analyst
./pg-admin.sh user create alice "" analyst

# Créer avec mot de passe défini
./pg-admin.sh user create bob "MonMotDePasse123!" engineer

# Changer le mot de passe
./pg-admin.sh user passwd alice "NouveauMotDePasse!"

# Verrouiller un compte (NOLOGIN)
./pg-admin.sh user lock alice

# Déverrouiller
./pg-admin.sh user unlock alice

# Supprimer (double confirmation requise)
./pg-admin.sh user drop alice
```

### Permissions granulaires

```bash
# Accorder lecture seule sur un schéma
./pg-admin.sh perm grant alice db-analytics-oscrum readonly staging

# Accorder lecture/écriture
./pg-admin.sh perm grant bob db-analytics-oscrum readwrite dwh

# Accorder sur une table précise
./pg-admin.sh perm grant-table svc_etl db-analytics-oscrum staging stg_projects "SELECT,INSERT"

# Voir les permissions d'un utilisateur
./pg-admin.sh perm show alice db-analytics-oscrum

# Révoquer toutes les permissions sur un schéma
./pg-admin.sh perm revoke alice db-analytics-oscrum staging

# Audit complet de la base
./pg-admin.sh perm audit db-analytics-oscrum
```

### Backup & restauration

```bash
# Backup vers le répertoire par défaut (./backups/)
./pg-admin.sh backup db-analytics-oscrum

# Backup vers un répertoire spécifique
./pg-admin.sh backup db-analytics-oscrum /srv/backups/

# Restaurer
./pg-admin.sh restore db-analytics-oscrum /srv/backups/db_analytics_oscrum_20260425_000000.sql.gz
```

Le backup est compressé en `.sql.gz`. La restauration décompresse automatiquement.

### Monitoring

```bash
# Statistiques générales (tailles, connexions, tables volumineuses)
./pg-admin.sh monitor stats

# Connexions actives en détail
./pg-admin.sh monitor connections

# Requêtes prenant plus de 3 secondes
./pg-admin.sh monitor slow 3000

# Verrous actifs
./pg-admin.sh monitor locks

# Forcer la fermeture de toutes les connexions sur une base
./pg-admin.sh monitor kill db-analytics-oscrum
```

---

## 8. Sécurité

### Protections implémentées

#### Injection SQL

Tous les identifiants (noms de base, schéma, utilisateur, table) sont **validés par regex** avant utilisation :

```
^[a-zA-Z_][a-zA-Z0-9_]{0,62}$
```

Toute tentative d'injection est bloquée :

```bash
./pg-admin.sh perm grant "alice; DROP TABLE users;" mydb readonly public
# → [ERROR] Valeur invalide pour nom d'utilisateur: 'alice; DROP TABLE users;'
```

Les valeurs (mots de passe) sont passées via `pg_escape_literal()` qui échappe les apostrophes.

#### Credentials & PGPASSFILE

Le mot de passe n'est **jamais** passé en argument de ligne de commande (visible dans `ps aux`).  
Le script crée un fichier temporaire `.pgpass` (chmod 600) et le supprime automatiquement à la fin via `trap`.

```
/tmp/pgpass.XXXXXX  (chmod 600, supprimé sur EXIT/INT/TERM)
```

#### Confirmations pour opérations irréversibles

Les opérations destructives exigent de **taper le nom exact** de la ressource :

```
⚠  Action IRRÉVERSIBLE : DROP DATABASE sur 'db_analytics_oscrum'
  Tapez exactement db_analytics_oscrum pour confirmer:
```

#### Fichiers sensibles

| Fichier | Permissions | Contenu |
|---|---|---|
| `pg-config.conf` | `600` | Credentials PostgreSQL et SSH |
| `.credentials/` | `700` | Répertoire des credentials générés |
| `.credentials/*.txt` | `600` | Credentials par utilisateur créé |
| `logs/` | *(standard)* | Journaux d'actions |

#### Chargement de config sécurisé

La config est parsée **sans `source`** pour éviter l'exécution de code arbitraire :

```bash
# ❌ Vulnérable à l'injection de code
source "$CONFIG_FILE"

# ✅ Parsing sécurisé ligne par ligne (pg-admin.sh)
while IFS='=' read -r key value; do
    case "$key" in
        PG_HOST) PG_HOST="$value" ;;
        ...
    esac
done < "$CONFIG_FILE"
```

---

## 9. Audit & journalisation

Toutes les actions sont journalisées dans `logs/audit-YYYY-MM-DD.log` :

```
[2026-04-25 00:44:15] USER=deploy         ACTION=CREATE_RBAC_ROLES              DETAILS=db=db_analytics_oscrum
[2026-04-25 00:45:02] USER=deploy         ACTION=CREATE_USER                    DETAILS=user=alice profile=analyst
[2026-04-25 00:45:10] USER=deploy         ACTION=ASSIGN_ROLE                    DETAILS=user=alice role=role_data_analyst profile=analyst
[2026-04-25 00:46:30] USER=deploy         ACTION=RBAC_APPLY_ANALYST             DETAILS=db=db_analytics_oscrum schema=dwh role=role_data_analyst
```

Pour consulter les logs :

```bash
# Via le menu interactif : 6 › Audit & Rapports › 3
# Via CLI
tail -50 scripts/logs/audit-2026-04-25.log

# Rechercher toutes les actions sur un utilisateur
grep "user=alice" scripts/logs/audit-*.log
```

---

## 10. Cas d'usage courants

### Onboarding d'un nouveau Data Analyst

```bash
# 1. Créer l'utilisateur (mot de passe auto-généré)
./pg-admin.sh user create john_doe "" analyst

# 2. Assigner le profil analyst (accès au rôle RBAC)
./pg-admin.sh rbac assign john_doe analyst

# 3. Vérifier ses droits
./pg-admin.sh perm show john_doe db-analytics-oscrum

# 4. Les credentials sont dans .credentials/john_doe_*.txt
```

### Onboarding d'un Data Engineer

```bash
# 1. Créer l'utilisateur avec profil engineer
./pg-admin.sh user create jane_doe "" engineer

# 2. Assigner le profil
./pg-admin.sh rbac assign jane_doe engineer

# 3. Les droits Engineer sont déjà configurés sur les schémas
#    (via rbac apply effectué lors de l'initialisation)
./pg-admin.sh perm show jane_doe db-analytics-oscrum
```

### Setup initial d'une nouvelle base

```bash
# 1. Créer la base
./pg-admin.sh db create db-analytics-oscrum admin_analytics_oscrum

# 2. Créer les schémas
./pg-admin.sh schema create db-analytics-oscrum raw
./pg-admin.sh schema create db-analytics-oscrum staging
./pg-admin.sh schema create db-analytics-oscrum dwh
./pg-admin.sh schema create db-analytics-oscrum marts

# 3. Initialiser les rôles RBAC
./pg-admin.sh rbac init db-analytics-oscrum

# 4. Appliquer les profils sur chaque schéma
./pg-admin.sh rbac apply db-analytics-oscrum raw      engineer
./pg-admin.sh rbac apply db-analytics-oscrum staging  engineer
./pg-admin.sh rbac apply db-analytics-oscrum dwh      engineer
./pg-admin.sh rbac apply db-analytics-oscrum marts    engineer

./pg-admin.sh rbac apply db-analytics-oscrum dwh      analyst
./pg-admin.sh rbac apply db-analytics-oscrum marts    analyst

./pg-admin.sh rbac apply db-analytics-oscrum marts    bi

# 5. Vérifier l'audit
./pg-admin.sh perm audit db-analytics-oscrum
```

### Autoriser un service account sur une table spécifique

```bash
# Créer un compte de service
./pg-admin.sh user create svc_airflow "" service

# Accorder SELECT sur une table précise
./pg-admin.sh perm grant-table svc_airflow db-analytics-oscrum staging stg_projects "SELECT"

# Accorder INSERT sur une autre table
./pg-admin.sh perm grant-table svc_airflow db-analytics-oscrum staging stg_users "SELECT,INSERT,UPDATE"
```

### Prévisualiser un changement avant exécution

```bash
# Voir le SQL qu'exécuterait l'initialisation RBAC — sans rien modifier
./pg-admin.sh --dry-run rbac init db-analytics-oscrum

# Voir le SQL d'un grant
./pg-admin.sh --dry-run perm grant bob db-analytics-oscrum readonly staging
```

### Rotation de mot de passe

```bash
# Générer un nouveau mot de passe automatiquement
./pg-admin.sh user passwd alice

# Définir un mot de passe spécifique
./pg-admin.sh user passwd alice "NouveauMotDePasse2024!"
```

### Départ d'un collaborateur

```bash
# 1. Verrouiller immédiatement
./pg-admin.sh user lock john_doe

# 2. Révoquer les permissions et rôles
./pg-admin.sh perm revoke john_doe db-analytics-oscrum dwh
./pg-admin.sh rbac revoke john_doe analyst

# 3. Supprimer le compte (irréversible)
./pg-admin.sh user drop john_doe
```

---

## 11. Structure des fichiers

```
scripts/
│
├── pg-admin.sh                  ← Script principal (v3.0)
├── pg-config.conf               ← Config active (gitignored — SECRETS)
├── pg-config.conf.example       ← Modèle de référence (versionné)
├── pg-config.dev.conf           ← Config dev (gitignored — créer si besoin)
├── pg-config.staging.conf       ← Config staging (gitignored — créer si besoin)
├── pg-config.prod.conf          ← Config prod (gitignored — créer si besoin)
│
├── .gitignore                   ← Exclut pg-config.conf, .credentials/, logs/, backups/
├── pg-admin.md                  ← Cette documentation
│
├── .credentials/                ← Credentials générés (chmod 700 — gitignored)
│   └── <user>_YYYYMMDD_HHMMSS.txt
│
├── logs/                        ← Journaux d'audit (gitignored)
│   └── audit-YYYY-MM-DD.log
│
├── backups/                     ← Backups (gitignored — créé à la demande)
│   └── <db>_YYYYMMDD_HHMMSS.sql.gz
│
│   ── Anciens scripts (conservés pour référence) ──
├── pg-manager.sh                ← v1 (déprécié)
└── pg-manager-v2.sh             ← v2 SSH (déprécié)
```

---

## 12. Résolution de problèmes

### 12.1 `zsh: killed ./scripts/pg-admin.sh`

Le message :

```bash
zsh: killed     ./scripts/pg-admin.sh
```

signifie que macOS/zsh a vu le processus recevoir un `SIGKILL`. Ce n'est pas une erreur SQL PostgreSQL classique.

Diagnostic rapide :

```bash
# Vérifier la syntaxe Bash
bash -n ./scripts/pg-admin.sh

# Vérifier que l'aide fonctionne sans connexion PostgreSQL
./scripts/pg-admin.sh --help

# Contournement si l'exécution directe est tuée
bash ./scripts/pg-admin.sh --help
bash ./scripts/pg-admin.sh --verbose test
```

Si `bash ./scripts/pg-admin.sh ...` fonctionne mais `./scripts/pg-admin.sh ...` est tué, la cause probable est liée à l'exécution directe du fichier sur macOS : résolution du shebang `#!/usr/bin/env bash`, attributs étendus (`xattr`) ou provenance/quarantaine du fichier.

Commandes utiles :

```bash
which -a bash
xattr -l ./scripts/pg-admin.sh

# Si l'attribut quarantine existe
xattr -d com.apple.quarantine ./scripts/pg-admin.sh
```

Le contournement sûr est de lancer explicitement le script avec Bash :

```bash
bash ./scripts/pg-admin.sh <commande>
```

### 12.2 Connexion PostgreSQL échouée ou bloquée

Le lancement sans argument exécute d'abord un test de connexion avant d'ouvrir le menu interactif. Si la base distante ne répond pas, le script peut attendre le timeout réseau de `psql`.

Tester avec logs :

```bash
./scripts/pg-admin.sh --verbose test
```

Limiter l'attente réseau côté PostgreSQL/libpq :

```bash
PGCONNECT_TIMEOUT=10 ./scripts/pg-admin.sh --verbose test
```

Vérifier ensuite :

1. `PG_HOST`, `PG_PORT`, `PG_ADMIN_USER` et `PG_DEFAULT_DB` dans `scripts/pg-config.conf`
2. L'ouverture du port : `nc -zv <PG_HOST> <PG_PORT>`
3. Le mode de connexion : `USE_SSH="local"` ou `USE_SSH="ssh"`
4. La présence des clients locaux : `command -v psql` et `command -v pg_dump`

Pour reconfigurer la connexion :

```bash
./scripts/pg-admin.sh config
```

### `psql: command not found`

```bash
# macOS
brew install postgresql

# Ubuntu/Debian
sudo apt-get install postgresql-client

# Ou utiliser le mode SSH (USE_SSH="ssh" dans pg-config.conf)
```

### `Impossible de se connecter à localhost:5432`

Vérifier :
1. PostgreSQL est démarré : `docker compose ps` ou `pg_isready`
2. `PG_HOST` et `PG_PORT` sont corrects dans `pg-config.conf`
3. Le pare-feu autorise le port : `nc -zv <PG_HOST> <PG_PORT>`

### `Permission denied` sur pg-config.conf

```bash
chmod 600 pg-config.conf
```

### `Valeur invalide pour nom d'utilisateur`

Les identifiants PostgreSQL n'acceptent que `[a-zA-Z_][a-zA-Z0-9_]` (max 63 chars).  
Éviter les tirets `-`, espaces, caractères spéciaux. Utiliser `_` à la place.

### `role "role_data_analyst" does not exist`

Les rôles RBAC n'ont pas encore été créés. Exécuter :

```bash
./pg-admin.sh rbac init <nom_de_la_base>
```

### Connexion SSH échouée

```bash
# Tester la connexion SSH manuellement
ssh -i ~/.ssh/id_rsa_example -p 22 deploy@203.0.113.10 "echo ok"

# Vérifier les droits sur la clé SSH
chmod 600 ~/.ssh/id_rsa_example
```

### `pg-config.conf` ignoré

Vérifier que `PG_CONFIG_FILE` ne pointe pas vers un autre fichier :

```bash
echo $PG_CONFIG_FILE
unset PG_CONFIG_FILE
./pg-admin.sh test
```

---

*Documentation mise à jour pour pg-admin.sh v3.0 — CICBI — Mai 2026*
