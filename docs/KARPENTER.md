# 🎯 Guía Karpenter en EKS

## ¿Qué es Karpenter y por qué usarlo?

Karpenter es un autoscaler de nodos **nativo de Kubernetes** que reemplaza al Cluster Autoscaler. La diferencia clave es que Karpenter interactúa **directamente con la API de EC2**, sin depender de AutoScaling Groups.

### Cluster Autoscaler vs Karpenter

| Aspecto | Cluster Autoscaler | Karpenter |
|---------|-------------------|-----------|
| Tiempo de escalado | 3-5 min | 30-60 seg |
| Selección de instancias | Fijo por ASG | Dinámico (cualquier tipo EC2) |
| Optimización de costes | Manual | Automática (Spot fallback) |
| Consolidación de nodos | No | Sí (WhenEmptyOrUnderutilized) |
| Multi-arquitectura | Difícil | Nativo (x86 + ARM64) |
| Configuración | Compleja | Simple (NodePool + EC2NodeClass) |

---

## Arquitectura de Karpenter

```
                    ┌────────────────────┐
                    │   Karpenter        │
                    │   Controller       │
                    │   (en K8s)         │
                    └────────┬───────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
    ┌─────────────────┐          ┌────────────────────┐
    │  Kubernetes API │          │    AWS EC2 API      │
    │  - Pods Pending │          │  - RunInstances     │
    │  - NodeClaims   │          │  - TerminateInst.   │
    │  - NodePools    │          │  - DescribeTypes    │
    └─────────────────┘          └────────────────────┘
                                          │
                             ┌────────────┴───────────┐
                             │                        │
                    ┌────────▼────────┐    ┌─────────▼───────┐
                    │   Spot Instances│    │  On-Demand Inst. │
                    │   (~70% ahorro) │    │  (Fallback)      │
                    └─────────────────┘    └─────────────────┘
```

---

## Recursos de Karpenter

### EC2NodeClass

Define **CÓMO** son los nodos (propiedades del EC2):

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023           # Amazon Linux 2023 (recomendado)
  
  # Karpenter usa tags para descubrir subnets (multi-AZ automático)
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: mi-cluster
  
  # Mismo para Security Groups
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: mi-cluster
  
  instanceProfile: KarpenterNodeInstanceProfile-mi-cluster
  
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
```

### NodePool

Define **QUÉ** nodos se crean (requisitos de Kubernetes):

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      
      requirements:
        # Prioriza Spot, fallback a On-Demand
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        
        # Familias de instancias permitidas
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        
        # Tamaño mínimo (evita micro/nano)
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: ["nano", "micro", "small", "medium"]
  
  limits:
    cpu: "1000"           # Límite de seguridad en costes
    memory: 4000Gi
  
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m  # Consolida nodos poco usados tras 1 min
```

---

## Casos de uso comunes

### 1. Pod que requiere GPU

```yaml
apiVersion: v1
kind: Pod
spec:
  nodeSelector:
    karpenter.k8s.aws/instance-gpu-name: nvidia-a10g
  containers:
  - name: ml-job
    resources:
      limits:
        nvidia.com/gpu: "1"
```

### 2. Carga de trabajo spot-tolerant

```yaml
spec:
  tolerations:
  - key: karpenter.sh/capacity-type
    operator: Equal
    value: spot
    effect: NoSchedule
  nodeSelector:
    karpenter.sh/capacity-type: spot
```

### 3. Workload que prefiere Graviton (ARM64)

```yaml
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
  containers:
  - image: myapp:latest  # La imagen debe ser multi-arch o arm64
```

---

## Comandos útiles

```bash
# Ver todos los NodePools
kubectl get nodepools

# Ver estado detallado de un NodePool  
kubectl describe nodepool general

# Ver EC2NodeClasses
kubectl get ec2nodeclasses

# Ver nodos gestionados por Karpenter
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/instance-type,karpenter.k8s.aws/instance-size

# Ver NodeClaims (requests de nodos activos)
kubectl get nodeclaims

# Logs del controller
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter -f

# Forzar consolidación (útil en dev)
kubectl annotate nodepool general karpenter.sh/do-not-disrupt-

# Ver por qué un pod está Pending
kubectl describe pod <pod-name> | grep -A5 Events
```

---

## Troubleshooting

### Pod pending - Karpenter no crea nodo

1. Verificar que el NodePool tiene capacity disponible (no ha alcanzado `limits`)
2. Verificar que los resource requests del pod caben en algún tipo de instancia
3. Ver logs: `kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter`
4. Verificar que las subnets tienen IPs disponibles

### Karpenter no consolida nodos

- Verificar que no hay `do-not-disrupt` annotations en los pods
- Los DaemonSets impiden la consolidación si son los únicos pods
- `PodDisruptionBudgets` demasiado restrictivos

### Error de IAM

```bash
# Verificar que el IRSA está bien configurado
kubectl -n karpenter get sa karpenter -o yaml | grep eks.amazonaws.com
aws iam simulate-principal-policy \
  --policy-source-arn <karpenter-role-arn> \
  --action-names ec2:RunInstances \
  --resource-arns "*"
```
