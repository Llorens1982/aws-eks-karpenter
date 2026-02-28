# 🔐 IAM y IRSA en EKS

## IRSA (IAM Roles for Service Accounts)

IRSA permite que los **pods de Kubernetes asuman roles IAM** sin usar credenciales estáticas. Es el patrón recomendado por AWS para dar permisos a pods.

### Flujo de autenticación IRSA

```
Pod (con SA anotado)
      │
      │ 1. Solicita token JWT al webhook de K8s
      ▼
Kubernetes TokenRequest API
      │
      │ 2. Genera token JWT firmado con OIDC
      ▼
AWS STS (AssumeRoleWithWebIdentity)
      │
      │ 3. Valida JWT contra OIDC Provider
      │ 4. Comprueba condiciones del role
      ▼
Credenciales temporales AWS (15 min TTL)
      │
      ▼
Pod puede llamar a APIs de AWS
```

### Crear un IRSA para tu aplicación

```hcl
# 1. Obtener datos del OIDC provider
data "aws_iam_openid_connect_provider" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

# 2. Política de trust con condiciones específicas
data "aws_iam_policy_document" "myapp_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:sub"
      # namespace:serviceaccount - MUY específico para evitar escalada de privilegios
      values   = ["system:serviceaccount:myapp:myapp-sa"]
    }
    
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# 3. Crear el role
resource "aws_iam_role" "myapp" {
  name               = "${var.cluster_name}-myapp"
  assume_role_policy = data.aws_iam_policy_document.myapp_assume.json
}

# 4. Adjuntar permisos necesarios
resource "aws_iam_role_policy" "myapp_s3" {
  name = "s3-access"
  role = aws_iam_role.myapp.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::my-bucket/*"
    }]
  })
}
```

```yaml
# 5. Anotar el ServiceAccount en K8s
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp-sa
  namespace: myapp
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/myproject-dev-myapp
    # Token expiry (default 86400s = 24h)
    eks.amazonaws.com/token-expiration: "3600"
```

---

## Roles del módulo IAM

| Role | Para qué | Policies |
|------|----------|----------|
| `{cluster}-cluster-role` | EKS Control Plane | AmazonEKSClusterPolicy, AmazonEKSVPCResourceController |
| `{cluster}-node-role` | EC2 worker nodes | AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy, AmazonEC2ContainerRegistryReadOnly, AmazonSSMManagedInstanceCore |
| `{cluster}-ebs-csi-role` | EBS CSI Driver (IRSA) | AmazonEBSCSIDriverPolicy |
| `{cluster}-efs-csi-role` | EFS CSI Driver (IRSA) | AmazonEFSCSIDriverPolicy |
| `{cluster}-karpenter-controller` | Karpenter (IRSA) | Custom policy para EC2 + SQS |

---

## Verificar que IRSA funciona

```bash
# Ver anotación del ServiceAccount
kubectl get sa -n kube-system ebs-csi-controller-sa -o jsonpath='{.metadata.annotations}'

# Exec en el pod y verificar identidad
kubectl exec -it -n kube-system <ebs-csi-pod> -- \
  aws sts get-caller-identity

# Debe mostrar el ARN del role, NO del role del nodo
# ✅ Correcto: arn:aws:sts::123456789012:assumed-role/myproject-dev-ebs-csi-role/...
# ❌ Incorrecto: arn:aws:sts::123456789012:assumed-role/myproject-dev-node-role/...
```

---

## Buenas prácticas IAM en EKS

1. **Principio de mínimo privilegio**: Cada SA con el role más restrictivo posible
2. **Condiciones específicas**: Siempre incluir `StringEquals` en `sub` para evitar que otros SA del mismo namespace asuman el role
3. **No usar credenciales del nodo**: Los pods NO deben usar el instance role del nodo
4. **IMDSv2 obligatorio**: Configurado en launch templates con `http_tokens = "required"` y `hop_limit = 1`
5. **Auditar regularmente**: Revisar roles con CloudTrail y AWS IAM Access Analyzer
