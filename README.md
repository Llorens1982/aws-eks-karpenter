# 🚀 EKS + Karpenter con Terraform

Repositorio de referencia para desplegar **Amazon EKS** production-ready con **Karpenter** como autoscaler, VPC privada, IAM roles con IRSA, private endpoints y addons gestionados.

## 📁 Estructura del repositorio

```
eks-karpenter-terraform/
├── modules/
│   ├── vpc/                    # VPC, subnets privadas/públicas, NAT GW, endpoints
│   ├── eks/                    # Cluster EKS, node groups, addons
│   ├── iam/                    # Roles IRSA, políticas, KMS
│   └── karpenter/              # NodePool, EC2NodeClass, IRSA
├── environments/
│   ├── dev/                    # Variables y backend de desarrollo
│   └── prod/                   # Variables y backend de producción
├── scripts/                    # kubectl config, helpers
├── docs/                       # Arquitectura y guías
└── .github/workflows/          # CI/CD con Terraform
```

## 🏗️ Arquitectura

```
┌─────────────────────────────────────────────────────┐
│                    AWS Account                       │
│  ┌─────────────────────────────────────────────┐   │
│  │                  VPC (10.0.0.0/16)           │   │
│  │  ┌──────────────┐    ┌──────────────────┐   │   │
│  │  │ Public Subnets│    │ Private Subnets  │   │   │
│  │  │ (3 AZs)       │    │ (3 AZs)          │   │   │
│  │  │  - NAT GW     │    │  - EKS Nodes     │   │   │
│  │  │  - ALB        │    │  - Karpenter     │   │   │
│  │  └──────────────┘    └──────────────────┘   │   │
│  │                                               │   │
│  │  ┌─────────────────────────────────────┐     │   │
│  │  │         EKS Control Plane           │     │   │
│  │  │  Private Endpoint + OIDC Provider   │     │   │
│  │  └─────────────────────────────────────┘     │   │
│  │                                               │   │
│  │  VPC Endpoints: ECR, S3, STS, EC2, Logs      │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## ⚡ Quick Start

### Prerequisites
- Terraform >= 1.5
- AWS CLI configurado
- kubectl
- helm >= 3.12

### 1. Configurar backend S3

```bash
cd environments/dev
# Editar backend.tf con tu bucket S3
terraform init
```

### 2. Desplegar VPC + EKS

```bash
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### 3. Configurar kubectl

```bash
./scripts/setup-kubeconfig.sh dev eu-west-1
kubectl get nodes
```

### 4. Verificar Karpenter

```bash
kubectl get nodepools
kubectl get ec2nodeclasses
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter
```

## 🔑 Features

| Feature | Estado |
|---------|--------|
| VPC con subnets privadas/públicas | ✅ |
| EKS Private Endpoint | ✅ |
| Managed Node Groups (sistem) | ✅ |
| Karpenter (workloads) | ✅ |
| IRSA (IAM Roles for Service Accounts) | ✅ |
| CoreDNS, kube-proxy, VPC-CNI addons | ✅ |
| AWS Load Balancer Controller | ✅ |
| EBS CSI Driver | ✅ |
| KMS encryption at rest | ✅ |
| CloudWatch Container Insights | ✅ |
| GitHub Actions CI/CD | ✅ |

## 📖 Documentación

- [Arquitectura detallada](docs/ARCHITECTURE.md)
- [Guía Karpenter](docs/KARPENTER.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [IAM y IRSA](docs/IAM.md)
