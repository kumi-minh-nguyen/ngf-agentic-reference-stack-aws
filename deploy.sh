#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Install all Kubernetes components on the EKS cluster
# Run this AFTER the EKS cluster and node groups are created via AWS Console.
#
# Prerequisites:
#   1. EKS cluster "ngf-agentic-demo" is Active
#   2. cpu-workers node group (t3.medium) is Active
#   3. gpu-workers node group (g4dn.xlarge, 100GB disk) is Active
#   4. kubectl is configured: aws eks update-kubeconfig --region <YOUR_REGION> --name <YOUR_CLUSTER_NAME>
#
# Usage: bash deploy.sh <HF_TOKEN>
# =============================================================================

set -euo pipefail

HF_TOKEN="${1:-}"
if [ -z "$HF_TOKEN" ]; then
  echo "ERROR: Hugging Face token required."
  echo "Usage: bash deploy.sh hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  exit 1
fi

echo ""
echo "============================================================"
echo " Step 1: Verify cluster is healthy"
echo "============================================================"
kubectl get nodes
echo ""

echo "============================================================"
echo " Step 2: Install NVIDIA device plugin"
echo "============================================================"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
helm repo update nvdp
helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia \
  --create-namespace \
  --version 0.17.4

# Label GPU nodes with NFD label required by nvidia-device-plugin v0.15+
# and role=gpu label required by vLLM nodeSelector
echo "Labeling GPU nodes..."
kubectl get nodes -l node.kubernetes.io/instance-type=g4dn.xlarge -o name | while read node; do
  kubectl label $node feature.node.kubernetes.io/pci-10de.present=true --overwrite
  kubectl label $node role=gpu --overwrite
done

# Label CPU node
kubectl get nodes -l node.kubernetes.io/instance-type=t3.medium -o name | while read node; do
  kubectl label $node role=cpu --overwrite
done

echo "Waiting for NVIDIA device plugin to be ready..."
kubectl rollout status daemonset/nvdp-nvidia-device-plugin -n nvidia --timeout=180s
echo ""

echo "============================================================"
echo " Step 3: Verify GPUs are visible"
echo "============================================================"
kubectl get nodes -o custom-columns="NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"
echo ""

echo "============================================================"
echo " Step 4: Install Gateway API CRDs"
echo "============================================================"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
echo ""

echo "============================================================"
echo " Step 5: Install Inference Extension CRDs (InferencePool)"
echo "============================================================"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.3.0/manifests.yaml
echo ""

echo "============================================================"
echo " Step 6: Install NGF CRDs + NGF v2.5.0"
echo "============================================================"
kubectl apply --server-side -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.0/deploy/crds.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.0/deploy/inference/deploy.yaml

echo "Waiting for NGF to be ready..."
kubectl rollout status deployment/nginx-gateway -n nginx-gateway --timeout=300s
echo ""

echo "============================================================"
echo " Step 7: Create namespaces"
echo "============================================================"
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace backend  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vllm     --dry-run=client -o yaml | kubectl apply -f -
echo ""

echo "============================================================"
echo " Step 8: Create Hugging Face token secret"
echo "============================================================"
kubectl create secret generic hf-token \
  --from-literal=token="$HF_TOKEN" \
  --namespace vllm \
  --dry-run=client -o yaml | kubectl apply -f -
echo ""

echo "============================================================"
echo " Step 9: Deploy Gateway"
echo "============================================================"
kubectl -n nginx-gateway apply -f inference-gateway/gateway.yaml
echo ""

echo "============================================================"
echo " Step 10: Deploy Frontend + Backend"
echo "============================================================"
kubectl -n frontend apply -f frontend/
kubectl -n backend  apply -f backend/
echo ""

echo "============================================================"
echo " Step 11: Deploy vLLM + EPP"
echo "============================================================"
kubectl -n vllm apply -f vllm/deployment.yaml
kubectl -n vllm apply -f vllm/inferencepool.yaml
kubectl -n vllm apply -f vllm/endpoint-picker/
kubectl -n vllm apply -f vllm/httproute.yaml
echo ""

echo "============================================================"
echo " All done! Watching pods come up..."
echo " (vLLM will take ~5-10 mins to download the model)"
echo " Press Ctrl+C when you're satisfied"
echo "============================================================"
kubectl get pods -A
