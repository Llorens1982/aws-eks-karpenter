#!/bin/bash
# =============================================================================
# test-karpenter.sh
# Script para probar que Karpenter escala correctamente
# Despliega un deployment que necesita más nodos y verifica que se crean
# =============================================================================

set -euo pipefail

echo "🧪 Test de escalado con Karpenter"
echo "=================================="

# Desplegar un deployment de prueba con resource requests
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 10
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      # Seleccionar el NodePool de Karpenter (no el de sistema)
      nodeSelector:
        role: general
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
EOF

echo ""
echo "⏳ Esperando que Karpenter cree nuevos nodos..."
echo "   (Karpenter tarda ~30-60 segundos en provisionar un nodo)"
echo ""
echo "📊 Monitorea el progreso con:"
echo "   watch kubectl get nodes"
echo "   kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter -f"
echo ""

# Esperar a que los pods estén running
kubectl rollout status deployment/karpenter-test --timeout=300s

echo ""
echo "✅ Test completado. Pods corriendo:"
kubectl get pods -l app=karpenter-test -o wide

echo ""
echo "📋 Nodos en el cluster:"
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/instance-type

echo ""
echo "🧹 Limpiando recursos de prueba..."
kubectl delete deployment karpenter-test

echo ""
echo "⏳ Esperando consolidación de nodos (Karpenter termina nodos vacíos)..."
echo "   Los nodos se terminarán en ~1 minuto por la política de consolidación"
