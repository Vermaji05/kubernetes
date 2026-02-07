#!/usr/bin/env bash
set -euo pipefail

# ========= USER SETTINGS =========
NS="${NS:-gitea}"

# StorageClasses (adjust to match what exists in your AKS)
SC_RWO="${SC_RWO:-managed-csi}"                # common default in AKS (Azure Disk)
SC_RWX="${SC_RWX:-azurefile-csi}"              # common default in AKS (Azure Files)

# If your sandbox already has custom names like:
#   SC_RWO="rwo-azuredisk"
#   SC_RWX="rwx-azurefiles"
# just export them before running.

RWX_PVC_NAME="${RWX_PVC_NAME:-gitea-shared-storage}"
RWX_PVC_SIZE="${RWX_PVC_SIZE:-50Gi}"

PG_CLUSTER_NAME="${PG_CLUSTER_NAME:-gitea-postgres}"
PG_INSTANCES="${PG_INSTANCES:-3}"
PG_STORAGE_SIZE="${PG_STORAGE_SIZE:-20Gi}"

GITEA_RELEASE="${GITEA_RELEASE:-gitea}"
GITEA_REPLICAS="${GITEA_REPLICAS:-3}"

# Ingress
ING_NS="${ING_NS:-ingress-nginx}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
# =================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }

echo "[0/10] Checking tools..."
need kubectl
need helm

echo "[1/10] Create namespace..."
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

echo "[2/10] Install NGINX Ingress Controller (if not installed)..."
if ! kubectl get ns "${ING_NS}" >/dev/null 2>&1; then
  kubectl create ns "${ING_NS}"
fi

# Install ingress-nginx via official chart
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm -n "${ING_NS}" upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 15m

echo "[3/10] Wait for ingress service external IP..."
ING_SVC="ingress-nginx-controller"
LB_IP=""
for i in {1..90}; do
  LB_IP="$(kubectl -n "${ING_NS}" get svc "${ING_SVC}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${LB_IP}" ]]; then break; fi
  echo "Waiting for LB IP... (${i}/90)"
  sleep 10
done

if [[ -z "${LB_IP}" ]]; then
  echo "ERROR: Could not get external LB IP for ingress."
  kubectl -n "${ING_NS}" get svc "${ING_SVC}" -o wide || true
  exit 1
fi

HOST="gitea.${LB_IP}.nip.io"
echo "Ingress LB IP: ${LB_IP}"
echo "Planned host : ${HOST}"

echo "[4/10] Install CloudNativePG operator..."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
helm -n cnpg-system upgrade --install cnpg cnpg/cloudnative-pg \
  --create-namespace \
  --wait --timeout 15m

echo "[5/10] Create Postgres HA cluster (${PG_INSTANCES} instances)..."
# Create a simple DB secret for Gitea
# username: gitea  (change if you want)
# password: auto-generated if not provided
DB_USER="${DB_USER:-gitea}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 18 | tr -d '\n')}"
DB_NAME="${DB_NAME:-gitea}"

kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-postgresql-secret
type: Opaque
stringData:
  username: "${DB_USER}"
  password: "${DB_PASS}"
  database: "${DB_NAME}"
EOF

kubectl -n "${NS}" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${PG_CLUSTER_NAME}
spec:
  instances: ${PG_INSTANCES}
  storage:
    size: ${PG_STORAGE_SIZE}
    storageClass: ${SC_RWO}
  bootstrap:
    initdb:
      database: ${DB_NAME}
      owner: ${DB_USER}
      secret:
        name: gitea-postgresql-secret
EOF

echo "[6/10] Wait for Postgres pods ready..."
kubectl -n "${NS}" wait --for=condition=Ready pod -l cnpg.io/cluster="${PG_CLUSTER_NAME}" --timeout=20m

echo "[7/10] Create RWX PVC for Gitea shared storage..."
kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${RWX_PVC_NAME}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ${SC_RWX}
  resources:
    requests:
      storage: ${RWX_PVC_SIZE}
EOF

echo "[8/10] Install Gitea chart (HA-ish, external Postgres, RWX PVC)..."
helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Admin credentials (you can override by exporting these)
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-$(openssl rand -base64 18 | tr -d '\n')}"

# Create admin secret (chart init uses it)
kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-admin-secret
type: Opaque
stringData:
  username: "${GITEA_ADMIN_USER}"
  password: "${GITEA_ADMIN_PASS}"
EOF

# Install/upgrade Gitea
# Important: maxSurge=0 prevents extra pod scheduling on tiny clusters
helm -n "${NS}" upgrade --install "${GITEA_RELEASE}" gitea-charts/gitea \
  --set replicaCount="${GITEA_REPLICAS}" \
  --set strategy.type=RollingUpdate \
  --set strategy.rollingUpdate.maxSurge=0 \
  --set strategy.rollingUpdate.maxUnavailable=1 \
  --set postgresql.enabled=false \
  --set postgresql-ha.enabled=false \
  --set gitea.config.database.DB_TYPE=postgres \
  --set gitea.config.database.HOST="${PG_CLUSTER_NAME}-rw.${NS}.svc.cluster.local:5432" \
  --set gitea.config.database.NAME="${DB_NAME}" \
  --set gitea.config.database.USER="${DB_USER}" \
  --set gitea.config.database.PASSWD_FROM_SECRET="gitea-postgresql-secret" \
  --set gitea.config.database.PASSWD_FROM_SECRET_KEY="password" \
  --set persistence.enabled=true \
  --set persistence.existingClaim="${RWX_PVC_NAME}" \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=1Gi \
  --timeout 30m

echo "[9/10] Create a normal ClusterIP service for ingress (gitea-web)..."
kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gitea-web
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/instance: ${GITEA_RELEASE}
    app.kubernetes.io/name: gitea
  ports:
  - name: http
    port: 3000
    targetPort: 3000
EOF

echo "[10/10] Create Ingress (nip.io host)..."
kubectl -n "${NS}" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gitea-web
            port:
              number: 3000
EOF

echo
echo "==== ACCESS ===="
echo "URL:  http://${HOST}"
echo "User: ${GITEA_ADMIN_USER}"
echo "Pass: ${GITEA_ADMIN_PASS}"
echo
echo "Check:"
echo "  kubectl -n ${NS} get pods -o wide"
echo "  kubectl -n ${NS} get ingress gitea"
echo
