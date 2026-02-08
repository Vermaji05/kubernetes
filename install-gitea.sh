#!/usr/bin/env bash
set -euo pipefail

############################################
# SETTINGS (TIGHT AKS FRIENDLY)
############################################
NAMESPACE="gitea"
RELEASE="gitea"

SC_RWO="managed-csi"
SC_RWX="azurefile-wffc"

############################################
# HELPERS
############################################
need() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }

randpw() {
python3 - <<'PY'
import secrets,string
print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))
PY
}

############################################
# PREFLIGHT
############################################
need kubectl
need helm
kubectl get nodes >/dev/null

############################################
# 1. STORAGECLASS (WFFC FOR AZURE FILE)
############################################
kubectl get sc azurefile-wffc >/dev/null 2>&1 || cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-wffc
provisioner: file.csi.azure.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  skuName: Standard_LRS
  protocol: smb
  enableHttpsTrafficOnly: "true"
EOF

############################################
# 2. NAMESPACE
############################################
kubectl get ns $NAMESPACE >/dev/null 2>&1 || kubectl create ns $NAMESPACE


############################################
# 3. CLOUDNATIVEPG OPERATOR
############################################
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl get ns cnpg-system >/dev/null 2>&1 || kubectl create ns cnpg-system

helm upgrade --install cnpg cloudnative-pg/cloudnative-pg \
  -n cnpg-system --wait --timeout 10m

############################################
# 4. POSTGRES (3 PODS)
############################################
PG_USER="gitea"
PG_DB="gitea"
PG_PASS="$(randpw)"

kubectl -n $NAMESPACE get secret gitea-postgres-secret >/dev/null 2>&1 || \
kubectl -n $NAMESPACE create secret generic gitea-postgres-secret \
  --from-literal=username="$PG_USER" \
  --from-literal=password="$PG_PASS"


cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: gitea-postgres
  namespace: $NAMESPACE
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: $SC_RWO
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
  bootstrap:
    initdb:
      database: $PG_DB
      owner: $PG_USER
      secret:
        name: gitea-postgres-secret
EOF

kubectl -n $NAMESPACE wait cluster gitea-postgres \
  --for=condition=Ready --timeout=15m

############################################
# 5. VALKEY (RWX PVC, FIXED)
############################################
VALKEY_PASS="$(randpw)"

kubectl -n $NAMESPACE get secret gitea-valkey-secret >/dev/null 2>&1 || \
kubectl -n $NAMESPACE create secret generic gitea-valkey-secret \
  --from-literal=password="$VALKEY_PASS"


cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valkey-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteMany]
  storageClassName: $SC_RWX
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea-valkey
  namespace: $NAMESPACE
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
        command: ["sh","-c"]
        args:
          - exec valkey-server --requirepass "\$VALKEY_PASSWORD"
        env:
        - name: VALKEY_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitea-valkey-secret
              key: password
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
        volumeMounts:
        - mountPath: /data
          name: data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: valkey-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-valkey
  namespace: $NAMESPACE
spec:
  selector:
    app: gitea-valkey
  ports:
  - port: 6379
EOF

kubectl -n $NAMESPACE rollout status deploy/gitea-valkey --timeout=10m

############################################
# 6. GITEA (3 PODS, NO LEVELDB)
############################################
helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install $RELEASE gitea-charts/gitea \
  -n $NAMESPACE \
  --set replicaCount=3 \
  --set postgresql.enabled=false \
  --set valkey.enabled=false \
  --set persistence.enabled=true \
  --set persistence.storageClass=$SC_RWX \
  --set persistence.size=20Gi \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=512Mi \
  --set gitea.config.database.DB_TYPE=postgres \
  --set gitea.config.database.HOST=gitea-postgres-rw:5432 \
  --set gitea.config.database.NAME=$PG_DB \
  --set gitea.config.database.USER=$PG_USER \
  --set gitea.config.queue.TYPE=redis \
  --set gitea.config.queue.CONN_STR="redis://:$VALKEY_PASS@gitea-valkey.$NAMESPACE.svc.cluster.local:6379/0" \
  --set gitea.config.cache.ADAPTER=redis \
  --set gitea.config.cache.HOST="redis://:$VALKEY_PASS@gitea-valkey.$NAMESPACE.svc.cluster.local:6379/1" \
  --set gitea.config.session.PROVIDER=redis \
  --set gitea.config.session.PROVIDER_CONFIG="redis://:$VALKEY_PASS@gitea-valkey.$NAMESPACE.svc.cluster.local:6379/2" \
  --timeout 20m

############################################
# 7. LOADBALANCER SERVICE
############################################
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gitea-lb
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: gitea
  ports:
  - port: 80
    targetPort: 3000
EOF

############################################
# DONE
############################################
echo "======================================"
kubectl -n $NAMESPACE get pods
kubectl -n $NAMESPACE get pvc
kubectl -n $NAMESPACE get svc gitea-lb
echo "======================================"
