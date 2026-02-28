#!/bin/bash
# =============================================================================
# setup-kubeconfig.sh
# Configura kubectl para acceder al cluster EKS
# Uso: ./scripts/setup-kubeconfig.sh <environment> <region>
# =============================================================================

set -euo pipefail

ENVIRONMENT=${1:-dev}
REGION=${2:-eu-west-1}

echo "🔍 Obteniendo configuración del cluster para environment: ${ENVIRONMENT}"

# Obtener el nombre del cluster desde los outputs de Terraform
cd "environments/${ENVIRONMENT}"
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")

if [ -z "$CLUSTER_NAME" ]; then
  echo "❌ No se pudo obtener el nombre del cluster. ¿Has ejecutado terraform apply?"
  exit 1
fi

echo "✅ Cluster encontrado: ${CLUSTER_NAME}"
echo "🔧 Configurando kubeconfig..."

aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --alias "${CLUSTER_NAME}"

echo ""
echo "✅ kubectl configurado correctamente"
echo ""
echo "🧪 Verificando acceso..."
kubectl cluster-info
echo ""
kubectl get nodes
echo ""
echo "🚀 Verificando Karpenter..."
kubectl get nodepools
kubectl get ec2nodeclasses
echo ""
echo "📊 Estado de los addons:"
kubectl get pods -n kube-system
