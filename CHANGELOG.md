# Changelog

All notable changes to this infrastructure repository are documented here.

## [Unreleased]

### Added

- Terraform stacks for persistent GitHub OIDC bootstrap, ephemeral network and EKS foundation, and Kubernetes platform resources.
- VPC, internal ALB with separate HML/PRD listeners, EKS managed node group, add-ons, namespaces, and SSM contracts.
- Mocked Terraform tests for the network, ALB, and SSM contract modules.
- CI validation and plan workflows, conditional apply, scheduled destroy, smoke checks, and orphan detection.

### Security

- GitHub OIDC roles with repository-scoped state access and plan-role restrictions.
- EKS Pod Identity for the AWS Load Balancer Controller and External Secrets Operator.
- Namespace quotas, Pod Security Standards, RBAC, and default-deny NetworkPolicies.
- Restricted egress from `auto-shop-ops` to the EKS Pod Identity agent endpoint on TCP ports 80 and 2703.
