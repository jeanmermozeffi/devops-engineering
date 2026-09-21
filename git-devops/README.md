# 🚀 Git Deploy - Workflow de Déploiement Global

Script interactif **COMPLET** pour gérer le workflow Git : `feature → dev → staging → main → prod`

## 🆕 Nouvelles Fonctionnalités v3.0

### ✨ 7 Opérations Avancées Ajoutées !

Le script intègre maintenant des fonctionnalités Git avancées avec choix numérotés :

| Option | Fonction | Description |
|--------|----------|-------------|
| **8** | ↩️ Annuler un commit | Soft/Mixed/Hard reset, Amend |
| **9** | ⏮️ Revenir à un commit | Par hash ou nombre de commits |
| **10** | 🚫 Untrack fichier | Retirer du suivi + .gitignore |
| **11** | 📜 Historique (log) | Log avancé, par fichier, auteur |
| **12** | 💼 Stash | Sauvegarder/Appliquer/Gérer |
| **13** | 🗑️ Annuler modifs | Restaurer fichiers/commits |
| **14** | 🗑️ Supprimer branche | Normal, forcé, local+distant |

📖 **[Voir le guide complet des nouvelles fonctionnalités](NOUVELLES-FONCTIONNALITÉS.md)**

## 🎯 Fonctionnalités v2.0

### ✅ Gestion Automatique de la Divergence après Rebase

Le script gère maintenant **automatiquement** la divergence de branches après un rebase !

**Problème résolu :**
```
Your branch and 'origin/feature/XXX' have diverged
fatal: Need to specify how to reconcile divergent branches
```

**Solution :** Après un merge `feature → dev`, si vous retournez sur votre feature branch, le script :
- Détecte automatiquement la divergence
- Vous propose 3 options : Force push, Reset, ou Ne rien faire
- Utilise `--force-with-lease` pour la sécurité

📖 **[Voir le guide complet](FIX-DIVERGENCE.md)**

### ⚙️ Configuration Automatique de Git

Le script configure automatiquement :
- `pull.rebase = false` (comportement de merge par défaut)
- `advice.skippedCherryPicks = false` (désactive les avertissements)

## ✨ Installation

Pour installer `git-deploy` comme commande globale sur votre Mac :

```bash
cd /Users/jeanmermozeffi/PycharmProjects/devops-enginering/git-devops
./install-git-deploy.sh
```

Le script va :
1. ✅ Copier `git-deploy.sh` vers `~/bin/git-deploy`
2. ✅ Rendre le script exécutable
3. ✅ Créer un alias Git global `deploy`
4. ✅ Vérifier que `~/bin` est dans votre PATH

**⚠️ Note :** Si le répertoire `~/bin` n'est pas dans votre PATH, ajoutez cette ligne à votre `~/.zshrc` :
```bash
export PATH="$HOME/bin:$PATH"
```
Puis rechargez : `source ~/.zshrc`

## 📝 Utilisation

Après l'installation, vous pouvez utiliser la commande depuis **n'importe quel projet Git** :

```bash
# Méthode 1 : Commande directe (fonctionne partout)
git-deploy

# Méthode 2 : Alias Git (dans un repo Git)
git deploy

# Afficher l'aide (pas besoin d'être dans un repo Git)
git-deploy --help

# Afficher le statut (dans un repo Git)
git-deploy --status

# Afficher l'état des branches (dans un repo Git)
git-deploy --branches
```

## 🔧 Vérification

Pour vérifier que l'installation a réussi :

```bash
# 1. Vérifier que le fichier existe
ls -la ~/bin/git-deploy

# 2. Vérifier que la commande est accessible
which git-deploy

# 3. Vérifier l'alias Git
git config --global --get alias.deploy

# 4. Tester la commande
git-deploy --help
```

## 🐛 Dépannage

### Erreur : `command not found: git-deploy`

**Solution :** Vérifiez que `~/bin` est dans votre PATH :
```bash
echo $PATH | grep "$HOME/bin"
```

Si non, ajoutez à `~/.zshrc` :
```bash
export PATH="$HOME/bin:$PATH"
source ~/.zshrc
```

### Erreur : `git deploy` ne fonctionne pas

**Note :** La commande `git-deploy` (avec tiret) fonctionne toujours partout. L'alias `git deploy` peut avoir des problèmes dans certains environnements (ex: environnements virtuels Python).

**Solution recommandée :** Utilisez `git-deploy` au lieu de `git deploy`

**Ou vérifiez l'alias Git :**
```bash
git config --global alias.deploy '!git-deploy'
```

**Test dans un nouveau terminal :**
```bash
# Ouvrez un nouveau terminal (sans environnement virtuel)
cd /chemin/vers/votre/projet
git-deploy --help
```

### Réinstallation

Si vous rencontrez des problèmes, réinstallez :
```bash
cd /Users/jeanmermozeffi/PycharmProjects/devops-enginering/git-devops
./install-git-deploy.sh

# Tester dans un projet
cd /chemin/vers/votre/projet
git deploy --status
```

## 🛠️ Workflow Supporté

Le script gère le workflow suivant :

- **feature/** - Branches de développement de fonctionnalités
- **dev** - Intégration des fonctionnalités
- **staging** - Pré-production (tests QA)
- **main** - Version stable (release)
- **prod** - Production live

### ⚙️ Noms de branches configurables

Les noms ci-dessus sont des **valeurs par défaut**. Chaque projet peut les
redéfinir (par ex. utiliser `develop` au lieu de `dev`). Précédence :
**flag CLI > variable d'environnement > `.devops.yml` > défaut**.

1. **`.devops.yml`** à la racine du projet (format plat) :

   ```yaml
   dev_branch: develop
   staging_branch: staging
   main_branch: main
   prod_branch: prod
   feature_prefix: feature/
   ```

2. **Variables d'environnement** : `BRANCH_DEV`, `BRANCH_STAGING`, `BRANCH_MAIN`,
   `BRANCH_PROD`, `FEATURE_PREFIX`.

3. **Flags CLI** : `--branch-dev`, `--branch-staging`, `--branch-main`,
   `--branch-prod`, `--feature-prefix`, `--config <fichier.yml>`.

```bash
# Voir la configuration effective des branches
git deploy --branches

# Exemple : projet utilisant "develop"
git deploy --branch-dev develop --branches
```

## 📁 Emplacement

- **Script source** : `/Users/jeanmermozeffi/PycharmProjects/devop-enginering/git-devop/git-deploy.sh`
- **Installation globale** : `~/bin/git-deploy`
- **Configuration** : `~/.gitconfig` (alias global)

## 🔄 Mise à Jour

Pour mettre à jour le script après modification :

```bash
cd /Users/jeanmermozeffi/PycharmProjects/devops-enginering/git-devops
./install-git-deploy.sh
```

## ⚠️ Dépannage

### Erreur : "cannot run git-deploy: No such file or directory"

Si vous obtenez cette erreur, vérifiez :

1. **Le script est installé** :
   ```bash
   ls -la ~/bin/git-deploy
   ```

2. **~/bin est dans le PATH** :
   ```bash
   echo $PATH | grep -o "$HOME/bin"
   ```

3. **L'alias est correctement configuré** :
   ```bash
   git config --global --get alias.deploy
   # Devrait afficher : !git-deploy "$@"
   ```

4. **Si ~/bin n'est pas dans le PATH**, ajoutez à `~/.zshrc` :
   ```bash
   echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

### Note sur `--help`

L'aide complète s'affiche avec des couleurs et un formatage correct :
```bash
git-deploy --help   # ✅ Affiche l'aide avec couleurs et formatage
```

**Note** : Si vous utilisez `git deploy --help`, Git tentera d'afficher une page de manuel qui n'existe pas. Dans ce cas, utilisez directement `git-deploy --help`.

## 📄 License

Auto-généré pour usage interne.

