# GitHub Environments and HML handoff

`branch-pipeline.yml` runs static checks for pull requests and pushes to `develop`. It does not use
OIDC, request AWS credentials, or apply Terraform. There is no production branch trigger. The
application coordinator must use the saved-plan/session-gated `ci.yml` and `apply.yml` path for HML.

The HML Apply/Destroy jobs run from `main` in the protected `staging` Environment after validating
the session ledger, trusted actor, one-use lifecycle dispatch, plan attestation, and confirmation.
HML credentials use `AWS_HML_DEPLOY_ROLE_ARN`, which must equal
`arn:aws:iam::035611741563:role/auto-shop/gh-deploy-k8s-hml`. The generic
`AWS_DEPLOY_ROLE_ARN` is used only for shared staging roots. PRD apply is disabled.

The existing `staging` Environment remains reserved for the lifecycle/session workflows in
`main`. Its branch policy must remain main-only so those gates are not bypassed or made unavailable.
Do not point the `develop` branch pipeline at the existing staging Terraform roots: both current roots
share the state objects `k8s-infra/staging/foundation.tfstate` and
`k8s-infra/staging/platform.tfstate` across branches.

## State ownership and deployment gate

The existing `k8s-infra/staging/foundation.tfstate` remains the owner of shared VPC, EKS, NAT, ALB,
and SSM resources. The existing `k8s-infra/staging/platform.tfstate` currently owns only the shared
ECR repository. No shared-resource migration is needed or intended. The `envs/hml/` and
`envs/production/` roots now exist, but the read-only inventory found no HML or production state
objects. Their backend keys, `k8s-infra/hml/terraform.tfstate` and
`k8s-infra/production/terraform.tfstate`, start empty and own only the respective environment's
namespace-scoped resources. They must not import, move, or declare shared foundation/platform
resources.

Both `K8S_HML_TERRAFORM_ROOT_READY` and `K8S_PRODUCTION_TERRAFORM_ROOT_READY` default to `false` when
unset. Keep them unset or `false` until issue #02's state/readiness review explicitly authorizes a
saved-plan deployment; root presence alone does not open the gate.

### HML namespace and RBAC prerequisite

The HML state does not own or create the Kubernetes Namespace. Before any HML plan or apply, an
authorized cluster administrator must apply `.github/hml-namespace-bootstrap.yaml`. It creates
`auto-shop-hml` with restricted Pod Security labels and two namespaced RoleBindings: one gives
`auto-shop-deployers` only TargetGroupBinding/ExternalSecret access; the other gives
`auto-shop-hml-infra` only quota, limit-range, and External Secrets resource access. The HML role's
`AmazonEKSAdminPolicy` association is scoped to `auto-shop-hml`; the app role's
`AmazonEKSEditPolicy` association is also scoped only to `auto-shop-hml`. The HML role has no
cluster-wide Kubernetes policy and cannot create or delete Namespace objects or access another
namespace.

Bootstrap order: create the IAM role by applying the reviewed bootstrap configuration; have the
cluster administrator apply the namespace/RBAC manifest; apply the shared foundation root so it can
install the two HML access entries; then create and review the HML saved plan and dispatch the
matching lifecycle-gated apply. Keep the namespace and its bootstrap RBAC outside HML state teardown;
remove them only through an explicitly authorized cluster-administrator operation after the HML
root has been destroyed and the shared cluster is ready for removal.

## OIDC subject migration

The bootstrap trust policies use only `token.actions.githubusercontent.com:aud` and
`token.actions.githubusercontent.com:sub` with `StringEquals`. They do not use direct `:workflow` or
`:ref` condition keys. The K8s repository ID is `1431503198`, and its owner ID is `279547328`. The
immutable repository segment is:

```text
repo:Software-Architecture-Group-7-FIAP@279547328/k8s-infra@1431503198
```

For migration, the four K8s GitHub roles accept both current default subjects and exact custom
subjects built from the immutable repository segment, `context`, and `workflow_ref`. With the GitHub
subject template `include_claim_keys=["repo","context","workflow_ref"]`, the custom subject shape is:

```text
repo:Software-Architecture-Group-7-FIAP@279547328/k8s-infra@1431503198:environment:<environment>:workflow_ref:Software-Architecture-Group-7-FIAP/k8s-infra/.github/workflows/<file>.yml@refs/heads/<branch>
```

The exact workflow/ref allowlist is:

| Role | Environment | Workflow file | Ref |
| --- | --- | --- | --- |
| `gh-plan-k8s-infra` | `staging` | `.github/workflows/ci.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/destroy.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/destroy.yml` | `refs/heads/main` |
| `gh-audit-k8s-infra` | `staging` | `.github/workflows/orphan-audit.yml` | `refs/heads/main` |

The repository-level subject template has not been changed and no IAM role has been updated by this
configuration-only change. Keep the current default-subject fallback until the GitHub template is
configured and every custom subject is verified. Configure the template only after the dual trust is
reviewed and deployed; then verify the `sub` for each listed workflow without exposing the OIDC
token. Remove the default-subject fallback only in a later reviewed change after successful
verification. Keep GitHub Environment deployment-branch policies, workflow branch guards, actor
authorization, and the lifecycle ledger gates in force throughout migration.

`session-open.yml` and `session-close.yml` are local preflights and do not assume an AWS role. The
application repository owns its separate operations/preflight and alert roles; they are not managed
by this bootstrap and are not changed here.
