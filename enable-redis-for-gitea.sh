#!/usr/bin/env bash
set -euo pipefail

# ========= USER SETTINGS =========
NS="${NS:-gitea}"
GITEA_RELEASE="${GITEA_RELEASE:-gitea}"
REDIS_RELEASE="${REDIS_RELEASE:-gitea-redis}"
# =================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }

echo "[0/6] Checking tools..."
need kubectl
need helm

echo "[1/6] Install Redis (ephemeral, no PVC)..."
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm -n "${NS}" upgrade --install "${REDIS_RELEASE}" bitnami/redis \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.persistence.enabled=false \
  --wait --timeout 10m

REDIS_HOST="${REDIS_RELEASE}-master.${NS}.svc.cluster.local:6379"
echo "Redis: ${REDIS_HOST}"

echo "[2/6] Update Gitea to use Redis for queue/cache/session (prevents LevelDB on RWX)..."
# Use INI-style conn strings (reliable for gitea.config.*)
helm -n "${NS}" upgrade "${GITEA_RELEASE}" gitea-charts/gitea \
  --reuse-values \
  --set gitea.config.queue.TYPE=redis \
  --set gitea.config.queue.CONN_STR="addr=${REDIS_HOST} db=0" \
  --set gitea.config.cache.ADAPTER=redis \
  --set gitea.config.cache.HOST="addr=${REDIS_HOST} db=1" \
  --set gitea.config.session.PROVIDER=redis \
  --set gitea.config.session.PROVIDER_CONFIG="addr=${REDIS_HOST} db=2" \
  --timeout 30m

echo "[3/6] Restart Gitea deployment..."
kubectl -n "${NS}" rollout restart deploy/"${GITEA_RELEASE}"
kubectl -n "${NS}" rollout status deploy/"${GITEA_RELEASE}" --timeout=10m || true

echo "[4/6] One-time cleanup: remove stale LevelDB queue dir from RWX (/data/queues/common)..."
GOODPOD="$(kubectl -n "${NS}" get pod -l app.kubernetes.io/instance="${GITEA_RELEASE}",app.kubernetes.io/name=gitea \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')"

if [[ -n "${GOODPOD}" ]]; then
  echo "Using pod: ${GOODPOD}"
  kubectl -n "${NS}" exec -it "${GOODPOD}" -- sh -lc \
    'rm -rf /data/queues/common || true; mkdir -p /data/queues || true; chmod -R 777 /data/queues || true'
else
  echo "No running Gitea pod found for cleanup (skip)."
fi

echo "[5/6] Quick log check (should NOT show leveldb permission errors)..."
kubectl -n "${NS}" logs -l app.kubernetes.io/instance="${GITEA_RELEASE}",app.kubernetes.io/name=gitea --tail=200 \
  | grep -Ei "level db|permission denied|fatal|queue" || true

echo "[6/6] Done."
echo "Tip: if you ever see LevelDB errors again, rerun this script."
