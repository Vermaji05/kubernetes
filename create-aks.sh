#!/usr/bin/env bash
set -euo pipefail

### ====== EDIT THESE (or export as env vars) ======
# Optional: set this if you have multiple subscriptions
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"   # e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

RG="${RG:-rg-gitea-aks}"
CLUSTER="${CLUSTER:-aks-gitea}"
LOCATION="${LOCATION:-eastus}"

# Node settings (prod-like but still reasonable)
NODE_COUNT="${NODE_COUNT:-3}"
NODE_SIZE="${NODE_SIZE:-Standard_D4s_v5}"   # good default (4 vCPU, 16GB). If quota is tight, try Standard_D2s_v5
K8S_VERSION="${K8S_VERSION:-}"              # leave empty to use default/latest available in region

# Networking (defaults are fine)
NETWORK_PLUGIN="${NETWORK_PLUGIN:-azure}"   # azure or kubenet (kubenet uses fewer IPs)
# If you want kubenet: export NETWORK_PLUGIN=kubenet

# Optional: enable autoscaler
ENABLE_AUTOSCALER="${ENABLE_AUTOSCALER:-false}"
MIN_NODES="${MIN_NODES:-3}"
MAX_NODES="${MAX_NODES:-5}"

### ====== Preflight ======
command -v az >/dev/null
command -v kubectl >/dev/null || true

echo "[1/7] Azure login + subscription context..."
az account show >/dev/null 2>&1 || az login >/dev/null

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

echo "Using subscription: $(az account show --query id -o tsv)"

echo "[2/7] Register providers (safe to rerun)..."
az provider register --namespace Microsoft.ContainerService --wait >/dev/null
az provider register --namespace Microsoft.Network --wait >/dev/null

echo "[3/7] Create resource group (idempotent)..."
az group create -n "${RG}" -l "${LOCATION}" >/dev/null

echo "[4/7] Create AKS (idempotent)..."
# Build optional flags cleanly
AKS_VERSION_FLAG=()
if [[ -n "${K8S_VERSION}" ]]; then
  AKS_VERSION_FLAG=(--kubernetes-version "${K8S_VERSION}")
fi

AUTOSCALER_FLAGS=()
if [[ "${ENABLE_AUTOSCALER}" == "true" ]]; then
  AUTOSCALER_FLAGS=(--enable-cluster-autoscaler --min-count "${MIN_NODES}" --max-count "${MAX_NODES}")
fi

# Create if missing
if az aks show -g "${RG}" -n "${CLUSTER}" >/dev/null 2>&1; then
  echo "AKS cluster already exists: ${CLUSTER} (skipping create)"
else
  az aks create \
    -g "${RG}" -n "${CLUSTER}" -l "${LOCATION}" \
    --node-count "${NODE_COUNT}" \
    --node-vm-size "${NODE_SIZE}" \
    --network-plugin "${NETWORK_PLUGIN}" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-keys \
    "${AKS_VERSION_FLAG[@]}" \
    "${AUTOSCALER_FLAGS[@]}" \
    >/dev/null
fi

echo "[5/7] Get kubeconfig..."
az aks get-credentials -g "${RG}" -n "${CLUSTER}" --overwrite-existing >/dev/null

echo "[6/7] Quick cluster checks..."
kubectl get nodes -o wide

echo "[7/7] Done ✅"
echo ""
echo "Next step: run your Gitea HA install script (CNPG + RWX + Valkey + Gitea)."
