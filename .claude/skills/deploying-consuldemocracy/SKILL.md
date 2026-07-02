---
name: deploying-consuldemocracy
description: Use when deploying a new version of Consuldemocracy to staging or production, before running any `cap` command. This fork deploys from branch main-zatsit, not master.
---

# Déployer Consuldemocracy avec Capistrano

## Vue d'ensemble

Déployer Consuldemocracy demande une rigueur stricte: **jamais de raccourci qui saute staging, jamais de déploiement sans backup, jamais sans vérifier que la fix est appliquée, jamais sans spécifier la bonne branche.**

**Principe fondamental:** Les tests et backups ne sont PAS optionnels. Ils sauvent du temps en évitant une crise en production.

**Violer la lettre de ce processus, c'est violer l'esprit du déploiement sûr.**

**⚠️ CONTRAINTE DE BRANCHE — Zéro exception:**

Ce fork (zatsit) déploie depuis la branche **`main-zatsit`**, PAS `master`. `master` est la branche upstream Consul Democracy — la déployer déploierait le mauvais code (sans les customisations zatsit).

Toute commande `cap` DOIT être préfixée par `branch=main-zatsit`:

```bash
branch=main-zatsit cap staging deploy
branch=main-zatsit cap production deploy
```

**Sans ce préfixe, Capistrano déploie `master` par défaut — silencieusement.** Il n'y a pas d'erreur, pas de warning: le déploiement réussit, mais avec le mauvais code. C'est la pire sorte d'échec silencieux.

---

## Quand utiliser

- Vous devez déployer une **nouvelle version** de Consuldemocracy
- Vous allez exécuter `cap staging deploy` ou `cap production deploy`
- Vous êtes sous pression (deadline, manager qui demande "aujourd'hui?")
- Vous êtes tentés de "juste déployer sans tester d'abord"
- Vous êtes tentés de lancer `cap` sans préciser `branch=main-zatsit`

**À NE PAS utiliser pour:**
- Rollbacks d'urgence (autre processus)
- Hotfixes critiques en prod (autre processus)
- Déploiements de micro-services distincts

---

## Le Pipeline Obligatoire

```
0. Vérifier la branche (main-zatsit, jamais master)
   ↓
1. Vérifier la fix
   ↓
2. Deployer STAGING
   ↓
3. Tester STAGING
   ↓
4. Backup GCP (production seulement)
   ↓
5. Deployer PRODUCTION
   ↓
6. Vérifier PRODUCTION
```

### Étape 0: Vérifier la Branche (1 min)

**Ce fork déploie `main-zatsit`, jamais `master`.**

```bash
# Vérifier que vous êtes bien sur main-zatsit localement
git branch --show-current
# Doit montrer: main-zatsit

# Vérifier que main-zatsit est à jour avec origin
git fetch origin main-zatsit
git log HEAD..origin/main-zatsit --oneline
# Doit être vide (rien en retard) ou contenir les commits à déployer
```

**Toute commande `cap` de ce processus DOIT inclure `branch=main-zatsit` en préfixe.** Sans ça, Capistrano déploie silencieusement `master` (le fork upstream, sans les customisations zatsit).

### Étape 1: Vérifier la Fix (5 min)

**AVANT tout, confirmer que votre changement est réellement en place:**

```bash
# Vérifier la version Capistrano
gem list | grep capistrano
# Doit montrer: capistrano (3.20.0) ou plus récent

# Vérifier que le Gemfile.lock est à jour
cat Gemfile.lock | grep -A 2 "capistrano ("
# Doit matcher Gemfile: ~> 3.20.0

# Vérifier que la branche a le changement
git log --oneline -5
# Chercher le commit qui fixe le problème

# Vérifier que Gemfile et Gemfile.lock sont synchronisés (TOUJOURS, pas seulement capistrano)
bundle lock --local
# Si ça échoue avec "dependencies... changed, but the lockfile can't be updated
# because frozen mode is set" ou similaire → Gemfile.lock est désynchronisé.
# Le serveur tourne en mode frozen: il refusera silencieusement de résoudre,
# et deploy:assets:precompile échouera à mi-déploiement.
# Fix: bundle lock (sans --local si le gem manque du cache), vérifier le diff,
# committer Gemfile.lock, push, PUIS redéployer.
```

**Si la fix n'est pas appliquée:** Stop. Ne dépployez pas. Appliquez d'abord la fix.

**Si Gemfile.lock est désynchronisé:** Stop. Ne dépployez pas tant que `bundle lock --local` ne passe pas proprement. Un `git diff` minimal (juste les gems ajoutés) est attendu — si `BUNDLED WITH` change de version, restaurez la valeur d'origine à la main pour éviter un changement non lié.

### Étape 2: Déployer Staging (15–20 min)

```bash
branch=main-zatsit cap staging deploy
```

Ceci va:
- Télécharger le code
- Installer les dépendances
- Compiler les assets
- Exécuter les migrations (s'il y en a)
- Redémarrer les services

**Vous POUVEZ tester les changements critiques en parallèle:**
- Pendant que Capistrano travaille, démarrer le backup GCP (étape 4)

### Étape 3: Tester Staging (5–10 min)

**Smoke test obligatoire** (minimum absolu). L'app n'a pas de domaine public accessible depuis l'extérieur pour staging/production — tout se vérifie via SSH sur le serveur (l'accès SSH est déjà celui qu'utilise Capistrano, donc s'il a déployé, il fonctionne):

```bash
SERVER=<IP-ou-host-du-serveur staging>  # visible dans la sortie de `cap staging deploy`, ex: consul@34.38.179.210

ssh $SERVER "
  echo '=== Service Puma ===';
  systemctl --user status puma_consul_staging --no-pager -l | head -10;

  echo '=== Homepage locale ===';
  curl -sI http://localhost:3000 | head -5;

  echo '=== Erreurs récentes ===';
  tail -50 /home/consul/consul/current/log/staging.log | grep -iE 'FATAL|ERROR' | tail -10;

  echo '=== Release couramment live ===';
  readlink /home/consul/consul/current
"
```

**Ne pas deviner de nom de domaine ni de chemin de log** (`/var/log/...` n'est pas où vivent les logs — ils sont dans `/home/consul/consul/current/log/`). Si un chemin ou un nom de service semble faux, vérifiez-le en le cherchant dans `config/deploy.rb` / `config/deploy/*.rb`, ou en listant `/home/consul/.config/systemd/user/` sur le serveur, plutôt que de supposer.

**Si un test échoue:** Analysez l'erreur. Si c'est une vraie régression, ne progressez PAS en production. Fixez sur staging d'abord.

### Étape 4: Backup GCP (10–30 min, PRODUCTION seulement)

**OBLIGATOIRE avant de toucher la production.**

**Projet GCP:** `zatsit-dsi-internalsites-prod` (différent du projet gcloud actif par défaut — le préciser explicitement avec `--project`, sinon `disks list` retourne vide silencieusement).

**Disque:** `zatsit-democracy-prod-1`, zone `europe-west1-b`, 30 Go.

```bash
PROJECT=zatsit-dsi-internalsites-prod
DISK=zatsit-democracy-prod-1
ZONE=europe-west1-b

# Si "Reauthentication failed" apparaît: se reconnecter d'abord
# gcloud auth login

# Confirmer le disque (vérifie aussi que l'auth/projet sont bons)
gcloud compute disks list --filter="name:$DISK" --format="table(name,zone,sizeGb)" --project=$PROJECT

# Créer le snapshot
SNAPSHOT_NAME="backup-$(date +%Y%m%d-%H%M%S)"
gcloud compute disks snapshot $DISK \
  --snapshot-names=$SNAPSHOT_NAME \
  --zone=$ZONE \
  --project=$PROJECT

# Vérifier l'état du backup (doit être READY avant de continuer)
gcloud compute snapshots describe $SNAPSHOT_NAME --project=$PROJECT --format="value(status,diskSizeGb,name)"
```

**Pourquoi obligatoire:**
- Si le déploiement casse la DB ou les données, vous n'avez aucun recours
- Les snapshots GCP prennent 10–30 min (rarement plus)
- Vous pouvez paralléliser avec staging testing
- **Un backup sauvera VOTRE journée si quelque chose va mal**

**Vous pouvez laisser tourner pendant staging testing.**

### Étape 5: Déployer Production (5–10 min)

```bash
# Confirmer le backup est terminé
gcloud compute snapshots list --filter="name:backup-*" --limit=1

# PUIS déployer (branch=main-zatsit obligatoire)
branch=main-zatsit cap production deploy
```

Capistrano handle le zero-downtime automatiquement avec la config standard.

### Étape 6: Vérifier Production (5 min)

**Domaine public:** `https://democracy.zatsit.fr/` (accessible seulement via VPC privé — pas testable depuis l'extérieur). Tout se vérifie via SSH.

```bash
SERVER=<IP-ou-host-du-serveur production>  # ex: consul@34.38.179.210

ssh $SERVER "
  echo '=== Service Puma ===';
  systemctl --user status puma_consul_production --no-pager -l | head -10;

  echo '=== Release couramment live (doit matcher le release ID du déploiement) ===';
  readlink /home/consul/consul/current;

  echo '=== Erreurs récentes ===';
  tail -50 /home/consul/consul/current/log/production.log | grep -iE 'FATAL|ERROR' | tail -10;

  echo '=== TEST CRITIQUE: via nginx, pas juste Puma direct ===';
  curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: democracy.zatsit.fr' http://localhost/
"
```

**Le test via nginx (dernière ligne) est OBLIGATOIRE, pas optionnel.** Vérifier seulement `systemctl status puma_consul_production` = `active (running)` ne suffit PAS: Puma peut tourner parfaitement et répondre en direct sur son port/socket, tout en étant invisible pour nginx à cause d'un souci de socket Unix (voir piège ci-dessous). Le seul test qui prouve que l'utilisateur final voit le site est un curl **à travers nginx** avec le bon `Host:` header — pas un curl direct sur Puma.

**Interpréter le résultat:**
- `Active: active (running)` + release ID qui matche + `HTTP 200` via nginx → déploiement réussi
- Des erreurs `ERROR` peuvent être préexistantes (pas causées par ce déploiement) — comparer leur timestamp à l'heure du déploiement avant de paniquer. Seules les erreurs **après** l'heure de déploiement, ou un service qui ne redémarre pas, sont bloquantes.
- `HTTP 502` malgré Puma `active (running)` → voir le piège "Socket Unix orphelin" ci-dessous.
- Toute erreur `FATAL`, ou service non `active (running)` → grave, voir Escalade ci-dessous.

**Si une erreur apparaît:** Cherchez la cause dans les logs. Si c'est grave, préparez-vous à rollback.

---

## Pièges Courants (et pourquoi vous les ferez)

| Piège | Tentation | Réalité |
|-------|-----------|---------|
| **Skip staging test** | "C'est juste un bump de version, rien ne peut casser" | Les changements Capistrano affectent l'ordre de chargement, les hooks, les dépendances. Staging prend 15 min. Production breakage = 2+ heures. |
| **Déployer sans backup** | "Rien ne va jamais mal, et ça prend du temps" | Si le déploiement casse la DB ou les migrations, vous êtes bloqué sans recours. GCP backups = assurance. |
| **Vérifier la fix seulement après coup** | "On l'a probablement appliquée" | Vous pourriez déployer l'ANCIENNE version. 2 min de vérification = zéro risque. |
| **Tester directement en prod** | "Staging est trop lent, testons en live" | Les utilisateurs voient les erreurs en même temps que vous. Trop tard. |
| **Lancer `cap` sans `branch=main-zatsit`** | "La commande de la doc officielle Capistrano ne précise pas de branche" | Sans préfixe, Capistrano déploie `master` (upstream) silencieusement — pas d'erreur, juste le mauvais code en ligne. |
| **Gemfile modifié sans régénérer Gemfile.lock** | "J'ai juste ajouté une ligne au Gemfile, le lock doit suivre tout seul" | Le serveur tourne `bundle` en mode frozen: il refuse de résoudre les nouvelles dépendances et casse `assets:precompile` à mi-déploiement (release déjà créée, service pas encore basculé). |
| **Vérifier seulement `systemctl status puma_...`, pas nginx** | "Le service est `active (running)`, donc c'est bon" | Puma peut tourner et répondre parfaitement en direct (port 3000 ou socket) pendant que nginx retourne 502, si le fichier du socket Unix a été supprimé/orphelin (voir Escalade "Socket Unix orphelin"). Seul un curl à travers nginx avec le bon `Host:` prouve que l'utilisateur final voit le site. |

---

## Les Red Flags — STOP et Recommencez

Si vous pensez l'une de ces choses, vous êtes sur le point de violarit ce processus:

- "C'est juste un petit changement, pas besoin de staging"
- "Le manager dit que ça doit être live maintenant"
- "Staging prend trop de temps, on saute"
- "Je vais faire le backup après le déploiement" (NON)
- "Les utilisateurs nous le diront si c'est cassé"
- "Un snapshot GCP c'est trop cher/lent"
- "Je vais tester directement en prod"
- "Je lance juste `cap staging deploy`, la branche par défaut ira bien"
- "C'est plus simple sans le préfixe `branch=`"

**Tous ces signaux = STOP. Recommencez le processus correctement.**

**Exceptions:** 
- **Zéro exception pour le backup avant production**
- **Zéro exception pour vérifier la fix**
- **Zéro exception pour tester staging d'abord**
- **Zéro exception pour le préfixe `branch=main-zatsit`**

---

## Checklist Pré-Déploiement

### Avant Staging

- [ ] Vérifier que vous êtes sur `main-zatsit` (`git branch --show-current`)
- [ ] Vérifier que la fix est appliquée (`gem list | grep capistrano`)
- [ ] Vérifier que Gemfile.lock est à jour
- [ ] Vérifier que le commit est sur la bonne branche
- [ ] Vérifier que la commande `cap` est préfixée par `branch=main-zatsit`

### Avant Production

- [ ] Staging test a réussi (homepage, login, logs propres)
- [ ] GCP backup terminé (vérifier: `gcloud compute snapshots list`)
- [ ] Aucune alerte/incident ouvert sur Consuldemocracy

### Après Production

- [ ] Vérifier production logs (no FATAL/ERROR)
- [ ] Homepage charge en < 2s
- [ ] Service en status "active (running)"
- [ ] Garder un eye sur les métriques pendant 10 min

---

## Réalités du Timing

| Étape | Temps | Peut paralléliser? |
|-------|-------|-------------------|
| Vérifier branche | 1 min | Non |
| Vérifier fix | 2 min | Non |
| Staging deploy | 15–20 min | Oui (backup parallèle) |
| Staging test | 5 min | Oui (pendant backup) |
| GCP backup | 10–30 min | Oui (parallèle staging) |
| Prod deploy | 5 min | Non (après backup) |
| Prod verify | 5 min | Non |
| **TOTAL** | **~45 min** | **Optimization: 35 min avec parallèle** |

**Point clé:** Vous sauvez 10 min en parallélisant, PAS en skipant des étapes.

---

## Exemple: Vous êtes sous Pression

Scenario: Manager dit "Faut que ce soit live aujourd'hui, c'est possible?"

**Réponse correcte:**
```
Oui, voici le plan:
0. Vérifier branche main-zatsit (1 min)
1. Vérifier fix (2 min)
2. branch=main-zatsit cap staging deploy + Backup GCP en parallèle (20 min)
3. Staging test rapide (5 min)
4. branch=main-zatsit cap production deploy (5 min)
5. Prod verify (5 min)
Total: 38 min

J'optimise en parallélisant, pas en sacrifiant safety, et je garde le préfixe branch=main-zatsit sur chaque cap.
```

**Réponse incorrecte:**
```
Oui, je vais juste déployer direct en prod, ça va être rapide.
```

(Cette approche peut finir en crise de 2+ heures au lieu de 45 min.)

---

## Escalade: Quelque Chose Va Mal

### Sur Staging

1. Vérifier les logs: `ssh $SERVER "tail -100 /home/consul/consul/current/log/staging.log"`
2. Identifier l'erreur
3. **Ne pas progresser en production**
4. Fixer le code, re-tester staging
5. Puis seulement production

### Sur Production

1. Vérifier les logs: `ssh $SERVER "tail -100 /home/consul/consul/current/log/production.log"`
2. Si c'est grave (app ne boot pas, DB cassée):
   - Vous avez un backup GCP
   - Préparez-vous à restore (autre processus)
3. Ne PAS continuer à essayer de déployer

### Cas vécu: 502 nginx malgré Puma `active (running)` (Socket Unix orphelin)

**Symptôme:** `https://democracy.zatsit.fr/` retourne 502. `systemctl --user status puma_consul_production` montre `active (running)`, `journalctl` ne montre aucune erreur de boot, les logs applicatifs sont propres. Un `curl` direct sur le port Puma (ou son socket, si on arrive à le tester en local sur la même machine) répond en 200. Pourtant nginx échoue.

**Root cause:** nginx est configuré en amont pour parler à Puma via un socket Unix (`upstream app { server unix:/home/consul/consul/shared/tmp/sockets/puma.sock; }`). Ce socket est aussi géré par une unité systemd `puma_consul_production.socket` (`Requires=` du `.service`), qui reste active indéfiniment (elle n'est redémarrée ni par Capistrano ni par un `puma:restart` classique — seul le `.service` l'est). Si un ancien process Puma buggé (ex: mal configuré pour bind sur TCP au lieu du socket) supprime/`unlink()` ce fichier socket en s'arrêtant sans l'utiliser, le fd systemd sous-jacent continue d'exister au niveau noyau (les process qui l'ont déjà — nouveau master, workers, systemd lui-même — peuvent toujours s'en servir), mais **plus aucun nouveau `connect()` par chemin ne fonctionne** puisque le fichier n'existe plus sur le disque. `ss -xlp | grep puma` montre le socket "LISTEN" avec des process attachés, mais `ls`/`stat` sur le chemin renvoie "No such file or directory" — c'est la signature de ce problème.

**Diagnostic:**
```bash
ssh $SERVER '
  ss -xlp | grep -i puma                      # Le socket écoute-t-il au niveau noyau ?
  stat /home/consul/consul/shared/tmp/sockets/puma.sock   # Existe-t-il sur le disque ?
  sudo tail -20 /var/log/nginx/error.log       # Confirme "No such file or directory"
'
```
Si `ss` montre un listener actif mais `stat` échoue → c'est ce piège, pas un bug applicatif.

**Fix (nécessite une confirmation explicite avant d'agir — ce n'est pas couvert par `cap ... deploy`):**
```bash
ssh $SERVER '
  systemctl --user stop puma_consul_production.service
  systemctl --user restart puma_consul_production.socket   # recrée le fichier
  systemctl --user start puma_consul_production.service
'
```
Puis re-tester impérativement via nginx (pas juste Puma direct): `curl -H "Host: democracy.zatsit.fr" http://localhost/` sur le serveur.

**Prévention à la racine:** ce bug n'apparaît que si un process Puma mal configuré (bind TCP au lieu du socket Unix attendu par nginx) tourne, ne serait-ce que temporairement. Le vrai fix est de garder `config/puma/production.rb` aligné sur `config/puma/staging.rb` (charger `defaults.rb`, jamais `development.rb`) — sinon ce problème peut se reproduire à chaque restart.

---

## Script Helper: Automatiser le Déploiement

Créer un script `deploy-consuldemocracy.sh` dans votre repo:

```bash
#!/bin/bash
set -e

ENV=${1:-staging}  # Par défaut: staging, usage: ./deploy.sh production
BRANCH="main-zatsit"  # Ce fork ne déploie JAMAIS master

echo "=== Deploying Consuldemocracy v$(cat version.txt) to $ENV (branch=$BRANCH) ==="

# Étape 0: Vérifier la branche locale
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "⚠ WARNING: local branch is '$CURRENT_BRANCH', not '$BRANCH'"
fi

# Étape 1: Vérifier la fix
echo "✓ Checking Capistrano version..."
gem list | grep capistrano || { echo "FAIL: Capistrano 3.20.0+ required"; exit 1; }

# Étape 2+3: Deploy + test staging (toujours, même pour production)
if [ "$ENV" != "staging" ]; then
  echo "✓ Deploy to staging first (required before production)..."
  branch=$BRANCH cap staging deploy
  echo "✓ Quick smoke test on staging..."
  curl -sf https://staging-consuldemocracy.zatsit.fr/ > /dev/null || { echo "FAIL: Staging down"; exit 1; }
fi

# Étape 4: Backup si production
if [ "$ENV" = "production" ]; then
  echo "✓ Creating GCP backup (required before production)..."
  SNAPSHOT_NAME="backup-$(date +%Y%m%d-%H%M%S)"
  ZONE=$(gcloud compute disks list --filter="name:zatsit-democracy-prod-1" --format="value(zone)" | rev | cut -d/ -f1 | rev)
  
  gcloud compute disks snapshot zatsit-democracy-prod-1 \
    --snapshot-names=$SNAPSHOT_NAME \
    --zone=$ZONE
  
  echo "✓ Waiting for backup to be READY..."
  while [ "$(gcloud compute snapshots describe $SNAPSHOT_NAME --format='value(status)')" != "READY" ]; do
    sleep 5
  done
  echo "✓ Backup ready: $SNAPSHOT_NAME"
fi

# Étape 5: Deploy
echo "✓ Deploying to $ENV..."
branch=$BRANCH cap $ENV deploy

# Étape 6: Verify
echo "✓ Verifying deployment..."
if [ "$ENV" = "staging" ]; then
  URL="https://staging-consuldemocracy.zatsit.fr"
else
  URL="https://consuldemocracy.zatsit.fr"
fi

curl -sf $URL > /dev/null && echo "✓ $ENV is up and running!" || echo "⚠ Check $URL manually"

echo "=== Deployment complete ==="
```

**Utilisation:**
```bash
./deploy-consuldemocracy.sh staging      # Deploy staging
./deploy-consuldemocracy.sh production   # Deploy + backup + production
```

---

## Résumé: Les Trois Piliers

```
PILIER 0: branch=main-zatsit sur CHAQUE commande cap
  → 0 min, zéro exception
  → Sans lui: déploiement silencieux du mauvais code (master)

PILIER 1: Vérifier la fix
  → 2 min, zéro raccourci

PILIER 2: Tester sur Staging
  → Sauve des heures en production
  → 15 min + 5 min, zéro raccourci

PILIER 3: Backup GCP AVANT Production
  → Assurance si quelque chose casse
  → Zéro exception, jamais après

Ces quatre piliers = 45 min sûrs
Sauter un seul = risque zéro gain de temps
```
