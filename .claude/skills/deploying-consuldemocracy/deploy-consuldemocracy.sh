#!/bin/bash
#
# Deploy script for Consuldemocracy with TDD-validated safety pipeline
# Usage: ./deploy-consuldemocracy.sh [staging|production]
# Always deploys branch=main-zatsit (this fork's branch, never master)
#

set -e

ENV=${1:-staging}
BRANCH="main-zatsit"  # Ce fork ne déploie JAMAIS master
PROJECT_ID="zatsit-dsi-internalsites-prod"
DISK_NAME="zatsit-democracy-prod-1"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Deploying Consuldemocracy to $ENV (branch=$BRANCH)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ============================================================================
# ÉTAPE 0: Vérifier la branche
# ============================================================================
echo ""
echo "📋 STEP 0: Vérifier que la branche locale est $BRANCH..."
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "⚠️  WARNING: local branch is '$CURRENT_BRANCH', expected '$BRANCH'"
  echo "   Le déploiement forcera quand même branch=$BRANCH sur le serveur distant."
fi
echo "✅ Deploying will use branch=$BRANCH"

# ============================================================================
# ÉTAPE 1: Vérifier la fix
# ============================================================================
echo ""
echo "📋 STEP 1: Vérifier que Capistrano 3.20.0+ est installé..."
if ! gem list | grep -q "capistrano (3.2"; then
  echo "❌ FAIL: Capistrano 3.20.0+ required"
  echo "   Run: gem install capistrano -v '~> 3.20.0'"
  exit 1
fi
echo "✅ Capistrano version OK"

# Vérifier Gemfile.lock
if ! grep -q "capistrano (3.2" Gemfile.lock; then
  echo "⚠️  WARNING: Gemfile.lock may not be updated"
  echo "   Consider running: bundle update capistrano"
fi

# ============================================================================
# ÉTAPE 2+3: Deploy et tester Staging
# ============================================================================
echo ""
echo "📋 STEP 2-3: Deployer et tester STAGING (obligatoire)..."

STAGING_LOG=$(mktemp)
if ! branch=$BRANCH cap staging deploy 2>&1 | tee "$STAGING_LOG"; then
  echo "❌ FAIL: Staging deployment échoué"
  exit 1
fi

# Pas de domaine public: extraire l'IP/user du serveur réellement utilisé par Capistrano
STAGING_SERVER=$(grep -oE '[a-z_]+@[0-9.]+' "$STAGING_LOG" | sort -u | head -1)
if [ -z "$STAGING_SERVER" ]; then
  echo "⚠️  WARNING: could not detect staging server from deploy output, skipping smoke test"
else
  echo "⏳ Smoke test on staging ($STAGING_SERVER)..."
  ssh "$STAGING_SERVER" "systemctl --user is-active puma_consul_staging && curl -sf http://localhost:3000 > /dev/null" \
    && echo "✅ Staging is up" \
    || { echo "❌ FAIL: Staging service or homepage not responding"; echo "   Check: ssh $STAGING_SERVER \"tail -50 /home/consul/consul/current/log/staging.log\""; exit 1; }
fi
rm -f "$STAGING_LOG"

# ============================================================================
# ÉTAPE 4: Backup GCP (production seulement)
# ============================================================================
if [ "$ENV" = "production" ]; then
  echo ""
  echo "📋 STEP 4: GCP Backup (OBLIGATOIRE avant production)..."

  # Obtenir la zone du disque
  ZONE=$(gcloud compute disks list \
    --filter="name:$DISK_NAME AND project:$PROJECT_ID" \
    --format="value(zone)" \
    --project="$PROJECT_ID" | rev | cut -d/ -f1 | rev)

  if [ -z "$ZONE" ]; then
    echo "❌ FAIL: Disque $DISK_NAME not found in project $PROJECT_ID"
    exit 1
  fi

  echo "   Zone: $ZONE"

  # Créer le snapshot
  SNAPSHOT_NAME="backup-$(date +%Y%m%d-%H%M%S)"
  echo "   Creating snapshot: $SNAPSHOT_NAME"

  gcloud compute disks snapshot "$DISK_NAME" \
    --snapshot-names="$SNAPSHOT_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID"

  # Attendre que le snapshot soit READY
  echo "   Waiting for snapshot to be READY..."
  MAX_WAIT=120  # 2 minutes max
  ELAPSED=0

  while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    STATUS=$(gcloud compute snapshots describe "$SNAPSHOT_NAME" \
      --format='value(status)' \
      --project="$PROJECT_ID" 2>/dev/null || echo "CREATING")

    if [ "$STATUS" = "READY" ]; then
      echo "✅ Backup ready: $SNAPSHOT_NAME"
      break
    fi

    echo -n "."
    sleep 3
    ELAPSED=$((ELAPSED + 3))
  done

  if [ "$STATUS" != "READY" ]; then
    echo "❌ FAIL: Backup not ready after ${MAX_WAIT}s"
    exit 1
  fi
fi

# ============================================================================
# ÉTAPE 5: Deploy Production
# ============================================================================
DEPLOY_LOG=$(mktemp)
if [ "$ENV" = "production" ]; then
  echo ""
  echo "📋 STEP 5: Deployer PRODUCTION..."

  if ! branch=$BRANCH cap production deploy 2>&1 | tee "$DEPLOY_LOG"; then
    echo "❌ FAIL: Production deployment échoué"
    echo "   Backup disponible: $SNAPSHOT_NAME"
    exit 1
  fi
fi

# ============================================================================
# ÉTAPE 6: Vérifier
# ============================================================================
echo ""
echo "📋 STEP 6: Vérification post-déploiement..."

if [ "$ENV" = "staging" ]; then
  SERVICE="puma_consul_staging"
  LOG_FILE="/home/consul/consul/current/log/staging.log"
else
  SERVICE="puma_consul_production"
  LOG_FILE="/home/consul/consul/current/log/production.log"
fi

# Pas de domaine public: extraire l'IP/user du serveur réellement déployé.
# Pour ENV=staging, DEPLOY_LOG est vide (rien écrit dedans) — réutiliser STAGING_SERVER connu à l'étape 2-3.
if [ "$ENV" = "staging" ]; then
  SERVER="$STAGING_SERVER"
else
  SERVER=$(grep -oE '[a-z_]+@[0-9.]+' "$DEPLOY_LOG" | sort -u | head -1)
fi
rm -f "$DEPLOY_LOG"

if [ -z "$SERVER" ]; then
  echo "⚠️  WARNING: could not detect server from deploy output, skipping remote verification"
else
  echo "   Server: $SERVER"
  ssh "$SERVER" "
    echo '=== Service ==='; systemctl --user is-active $SERVICE;
    echo '=== Release live ==='; readlink /home/consul/consul/current;
    echo '=== Erreurs récentes ==='; tail -50 $LOG_FILE | grep -iE 'FATAL|ERROR' | tail -10
  "
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Deployment complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ENV" = "production" ]; then
  echo ""
  echo "📌 Backup info:"
  echo "   Name: $SNAPSHOT_NAME"
  echo "   To restore: gcloud compute disks create <new-disk-name> --source-snapshot=$SNAPSHOT_NAME --zone=$ZONE"
  echo ""
  echo "⏱️  Keep monitoring logs and metrics for the next 10 minutes"
fi
