#!/usr/bin/env bash
set -euo pipefail

############################################
# USER SETTINGS (edit if needed)
############################################
NAMESPACE="gitea"
RELEASE="gitea"

# StorageClasses in AKS
SC_RWX="rwx-azurefiles"   # RWX for Gitea shared data
SC_RWO="rwo-azuredisk"    # RWO for CNPG Postgres

# Sizes
GITEA_RWX_SIZE="50Gi"
PG_SIZE="20Gi"

# HA-ish knobs (tuned to fit small sandbox)
GITEA_REPLICAS="3"
GITEA_REQ_CPU="100m"
GITEA_REQ_MEM="256Mi"
GITEA_LIM_CPU="500m"
GITEA_LIM_MEM="1Gi"

VALKEY_REQ_CPU="50m"
VALKEY_REQ_MEM="128Mi"
VALKEY_LIM_CPU="200m"
VALKEY_LIM_MEM="512Mi"

############################################
# Helpers
############################################
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }

randpw() {
  # 24 chars safe
  python3 - <<'PY'
import secrets,string
alphabet=string.ascii_letters+string.digits
print(''.join(secrets.choice(alphabet) for _ in range(24)))
PY
}

echo_step(){ echo -e "\n\033[1;32m[$1]\033[0m $2"; }

############################################
# Preflight
############################################
need kubectl
need helm

echo_step "0/9" "Checking Kubernetes access..."
kubectl version --short >/dev/null

############################################
# 1) Namespace
############################################
echo_step "1/9" "Create namespace: ${NAMESPACE}"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

############################################
# 2) Ingress NGINX
############################################
echo_step "2/9" "Install ingress-nginx (idempotent)"
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create ns ingress-nginx

# Official-ish minimal manifest (works in most sandboxes)
# NOTE: if you already have ingress installed, this will be mostly 'unchanged'
kubectl apply -n ingress-nginx -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml >/dev/null

echo_step "3/9" "Wait for ingress controller rollout..."
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m

echo_step "3/9" "Fetch ingress external IP..."
LB_IP=""
for i in {1..60}; do
  LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${LB_IP}" ]] && break
  sleep 5
done
if [[ -z "${LB_IP}" ]]; then
  echo "❌ Could not get ingress external IP. Check:"
  echo "kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide"
  exit 1
fi

HOST="gitea.${LB_IP}.nip.io"
ROOT_URL="http://${HOST}/"
echo "✅ Ingress IP: ${LB_IP}"
echo "✅ Host:      ${HOST}"

############################################
# 3) Install CloudNativePG operator
############################################
echo_step "4/9" "Install CNPG operator"
kubectl get ns cnpg-system >/dev/null 2>&1 || kubectl create ns cnpg-system
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm -n cnpg-system upgrade --install cnpg cloudnative-pg/cloudnative-pg \
  --wait --timeout 10m >/dev/null

############################################
# 4) Postgres secret + HA cluster (3 instances)
############################################
echo_step "5/9" "Create Postgres HA secret + cluster (3 pods)"
PG_USER="gitea"
PG_DB="gitea"
PG_PASS="$(randpw)"

kubectl -n "${NAMESPACE}" delete secret gitea-postgresql-secret >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" create secret generic gitea-postgresql-secret \
  --from-literal=username="${PG_USER}" \
  --from-literal=password="${PG_PASS}" >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: gitea-postgres
  namespace: ${NAMESPACE}
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18
  resources:
    requests:
      memory: "512Mi"
      cpu: "250m"
    limits:
      memory: "1Gi"
      cpu: "1"
  storage:
    size: ${PG_SIZE}
    storageClass: "${SC_RWO}"
  bootstrap:
    initdb:
      database: ${PG_DB}
      owner: ${PG_USER}
      secret:
        name: gitea-postgresql-secret
  affinity:
    podAntiAffinityType: preferred
EOF

echo_step "5/9" "Wait for Postgres pods ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l cnpg.io/cluster=gitea-postgres --timeout=15m

############################################
# 5) Valkey (1 pod) + secret
############################################
echo_step "6/9" "Deploy Valkey standalone (1 pod) + secret"
VALKEY_PASS="$(randpw)"

kubectl -n "${NAMESPACE}" delete secret gitea-valkey-auth >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" create secret generic gitea-valkey-auth \
  --from-literal=password="${VALKEY_PASS}" >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: gitea-valkey
  namespace: ${NAMESPACE}
spec:
  selector:
    app: gitea-valkey
  ports:
  - name: redis
    port: 6379
    targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea-valkey
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea-valkey
  template:
    metadata:
      labels:
        app: gitea-valkey
    spec:
      containers:
      - name: valkey
        image: valkey/valkey:7.2-alpine
        ports:
        - containerPort: 6379
          name: redis
        env:
        - name: VALKEY_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitea-valkey-auth
              key: password
        command: ["sh","-c"]
        args:
        - exec valkey-server --appendonly no --requirepass "\$VALKEY_PASSWORD"
        resources:
          requests:
            cpu: "${VALKEY_REQ_CPU}"
            memory: "${VALKEY_REQ_MEM}"
          limits:
            cpu: "${VALKEY_LIM_CPU}"
            memory: "${VALKEY_LIM_MEM}"
        readinessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 10
          periodSeconds: 10
EOF

kubectl -n "${NAMESPACE}" rollout status deploy/gitea-valkey --timeout=5m

############################################
# 6) Install Gitea Helm chart (HA-ish)
############################################
echo_step "7/9" "Install/upgrade Gitea (3 replicas, external CNPG Postgres, RWX PVC, Valkey queues)"

helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# IMPORTANT:
# - We let HELM create the RWX PVC to avoid ownership errors.
# - We set podAntiAffinity to preferred so 3 pods can run on 2 nodes (sandbox reality).
# - We force queue/cache/session to redis (Valkey) so LevelDB never gets used.
helm -n "${NAMESPACE}" upgrade --install "${RELEASE}" gitea-charts/gitea \
  --set replicaCount="${GITEA_REPLICAS}" \
  --set image.rootless=true \
  --set resources.requests.cpu="${GITEA_REQ_CPU}" \
  --set resources.requests.memory="${GITEA_REQ_MEM}" \
  --set resources.limits.cpu="${GITEA_LIM_CPU}" \
  --set resources.limits.memory="${GITEA_LIM_MEM}" \
  --set postgresql.enabled=false \
  --set postgresql-ha.enabled=false \
  --set valkey.enabled=false \
  --set valkey-cluster.enabled=false \
  --set persistence.enabled=true \
  --set persistence.accessModes[0]=ReadWriteMany \
  --set persistence.size="${GITEA_RWX_SIZE}" \
  --set persistence.storageClass="${SC_RWX}" \
  --set gitea.admin.existingSecret="gitea-admin-secret" \
  --set gitea.config.server.DOMAIN="${HOST}" \
  --set gitea.config.server.ROOT_URL="${ROOT_URL}" \
  --set gitea.config.server.SSH_LISTEN_PORT="2222" \
  --set gitea.config.server.START_SSH_SERVER=true \
  --set gitea.config.database.DB_TYPE="postgres" \
  --set gitea.config.database.HOST="gitea-postgres-rw:5432" \
  --set gitea.config.database.NAME="${PG_DB}" \
  --set gitea.config.database.USER="${PG_USER}" \
  --set gitea.config.queue.TYPE="redis" \
  --set gitea.config.queue.CONN_STR="redis://:\${VALKEY_PASSWORD}@gitea-valkey.${NAMESPACE}.svc.cluster.local:6379/0?pool_size=50&idle_timeout=180s" \
  --set gitea.config.cache.ADAPTER="redis" \
  --set gitea.config.cache.HOST="redis://:\${VALKEY_PASSWORD}@gitea-valkey.${NAMESPACE}.svc.cluster.local:6379/1?pool_size=50&idle_timeout=180s" \
  --set gitea.config.session.PROVIDER="redis" \
  --set gitea.config.session.PROVIDER_CONFIG="redis://:\${VALKEY_PASSWORD}@gitea-valkey.${NAMESPACE}.svc.cluster.local:6379/2" \
  --set-string gitea.additionalConfigFromEnvs[0].name="GITEA__DATABASE__PASSWD" \
  --set-string gitea.additionalConfigFromEnvs[0].valueFrom.secretKeyRef.name="gitea-postgresql-secret" \
  --set-string gitea.additionalConfigFromEnvs[0].valueFrom.secretKeyRef.key="password" \
  --set-string gitea.additionalConfigFromEnvs[1].name="VALKEY_PASSWORD" \
  --set-string gitea.additionalConfigFromEnvs[1].valueFrom.secretKeyRef.name="gitea-valkey-auth" \
  --set-string gitea.additionalConfigFromEnvs[1].valueFrom.secretKeyRef.key="password" \
  --set ingress.enabled=true \
  --set ingress.className="nginx" \
  --set ingress.hosts[0].host="${HOST}" \
  --set ingress.hosts[0].paths[0].path="/" \
  --set ingress.hosts[0].paths[0].pathType="Prefix" \
  --set affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution=null \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100 \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].key="app.kubernetes.io/name" \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].operator="In" \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].values[0]="gitea" \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey="kubernetes.io/hostname" \
  --timeout 30m

############################################
# 7) Create admin secret if missing (simple default)
############################################
echo_step "8/9" "Ensure gitea-admin-secret exists"
if ! kubectl -n "${NAMESPACE}" get secret gitea-admin-secret >/dev/null 2>&1; then
  ADMIN_USER="giteaadmin"
  ADMIN_PASS="$(randpw)"
  kubectl -n "${NAMESPACE}" create secret generic gitea-admin-secret \
    --from-literal=username="${ADMIN_USER}" \
    --from-literal=password="${ADMIN_PASS}" >/dev/null
  echo "✅ Admin user: ${ADMIN_USER}"
  echo "✅ Admin pass: ${ADMIN_PASS}"
else
  echo "✅ gitea-admin-secret already exists (not changing)."
fi

echo_step "9/9" "Wait for Gitea rollout..."
kubectl -n "${NAMESPACE}" rollout status deploy/gitea --timeout=15m || true

echo ""
echo "======================================================="
echo "✅ DONE"
echo "Gitea URL:  ${ROOT_URL}"
echo "Ingress IP: ${LB_IP}"
echo ""
echo "Check pods:"
echo "  kubectl -n ${NAMESPACE} get pods -o wide"
echo ""
echo "Check LevelDB errors (should be none):"
echo "  kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/name=gitea --tail=200 | grep -Ei 'level db|permission|fatal|queue' || echo OK"
echo ""
echo "If ingress isn’t reachable (rare sandbox issue), port-forward:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/gitea-http 3000:3000 --address 0.0.0.0"
echo "  Then open: http://<your-sandbox-ip>:3000"
echo "======================================================="
