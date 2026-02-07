#!/usr/bin/env bash
set -euo pipefail

# ========= USER SETTINGS =========
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-a2b28c85-1948-4263-90ca-bade2bac4df4}"         # optional: set if you have multiple subs
RG="${RG:-kml_rg_main-eb1b8323fad242fd}"
LOCATION="${LOCATION:-eastus}"                 # change if needed
AKS_NAME="${AKS_NAME:-aks-test}"
NODEPOOL="${NODEPOOL:-nodepool1}"
NODE_COUNT="${NODE_COUNT:-2}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
K8S_VERSION="${K8S_VERSION:-}"                # optional
# =================================

echo "[1/6] Azure login context..."
if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi
az account show -o table >/dev/null

echo "[2/6] Create resource group (if needed)..."

echo "[3/6] Create AKS cluster (if needed)..."
# Create AKS only if it doesn't exist
if ! az aks show -g "${RG}" -n "${AKS_NAME}" >/dev/null 2>&1; then
  AKS_ARGS=(
    -g "${RG}"
    -n "${AKS_NAME}"
    --nodepool-name "${NODEPOOL}"
    --node-count "${NODE_COUNT}"
    --node-vm-size "${VM_SIZE}"
    --enable-managed-identity
    --generate-ssh-keys
  )

  # optional version pin
  if [[ -n "${K8S_VERSION}" ]]; then
    AKS_ARGS+=(--kubernetes-version "${K8S_VERSION}")
  fi

  

  az aks create "${AKS_ARGS[@]}" -o none
else
  echo "AKS already exists: ${AKS_NAME}"
fi

echo "[4/6] Get kubeconfig..."
az aks get-credentials -g "${RG}" -n "${AKS_NAME}" --overwrite-existing -o none

echo "[5/6] Show nodes..."
kubectl get nodes -o wide

echo "[6/6] Show storage classes..."
kubectl get storageclass || true

cat <<EOF

DONE ✅
Next:
  ./02-install-gitea-postgres-ha.sh

Notes:
- In some sandbox subscriptions you may NOT have permission to scale nodepools later (RBAC). That’s okay.
- We’ll keep the stack stable with CPU limits and maxSurge=0.

EOF
