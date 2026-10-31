# GitHub Environments and HML handoff

`branch-pipeline.yml` runs static checks for pull requests and pushes to `develop`. It does not use
OIDC, request AWS credentials, or apply Terraform. There is no production branch trigger. The
application coordinator uses the hosted `ci.yml`/`apply.yml` workflows for foundation and the
session-gated `cluster-ci.yml`/`cluster-apply.yml` workflows for platform and HML.

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
SSM resources, and persistent CodeBuild runner resources. The existing `k8s-infra/staging/platform.tfstate` currently owns only the shared
ECR repository; the reviewed platform apply adds its shared controllers, IAM, namespaces, and RBAC.
No shared-resource migration is needed or intended. The `envs/hml/` and
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
`auto-shop-hml-infra` only quota, limit-range, and External Secrets resource access. The reviewed
shared `platform` root separately binds that group in `auto-shop-ops` for ServiceAccount creation
and named get/update/patch/delete access to `auto-shop-db-bootstrap-hml`. The HML role cannot manage
other resources in `auto-shop-ops`, create/delete Namespace objects, or access another namespace.
Its `AmazonEKSAdminPolicy` association is scoped to `auto-shop-hml`; the app role's
`AmazonEKSEditPolicy` association is also scoped only to `auto-shop-hml`. Shared foundation owns the
EKS access entries; the HML state owns its database-bootstrap ServiceAccount and Pod Identity
association so an authorized HML teardown removes both.

Bootstrap order: create the IAM role by applying the reviewed bootstrap configuration; have the
cluster administrator apply the namespace/RBAC manifest; apply the shared foundation root so it can
install the two HML access entries; confirm the shared `platform` root is current, since its External
Secrets Operator install for `auto-shop-hml` (`external-secrets-hml` namespace, scoped to that
namespace) must already be running — `envs/hml`'s `SecretStore` and `ExternalSecret` resources are
`kubernetes_manifest` objects, and `terraform plan` fails on a missing CRD if ESO has not reconciled.
Next, provision the HML database role and SSM metadata, then create and review the HML saved plan and
dispatch the matching lifecycle-gated apply; that HML root creates the bootstrap ServiceAccount and
Pod Identity association. Run database bootstrap only after that association exists. For teardown,
destroy the HML root first so it removes the ServiceAccount and association, then destroy the HML
database role and metadata. Keep the namespace and its bootstrap RBAC outside HML state teardown;
remove them only through an explicitly authorized cluster-administrator operation after the shared
cluster is ready for removal.

### Private cluster runner prerequisite

The k8s-infra repository is public, so HML/platform lifecycle jobs use an organization runner group
restricted to selected workflows. Before opening a coordinated session:

1. Create the GitHub organization runner group `k8s-private-eks`, restrict repository access to
   `Software-Architecture-Group-7-FIAP/k8s-infra`, and allow only `.github/workflows/cluster-ci.yml`,
   `.github/workflows/cluster-apply.yml`, and `.github/workflows/cluster-destroy.yml` from
   `refs/heads/main`.
2. Complete the pending GitHub CodeConnections connection `auto-shop-k8s-private-runner` in AWS
   account `035611741563`, region `us-east-1`. Authorize the GitHub organization and select only the
   `k8s-infra` repository; the connection must report `AVAILABLE` before the foundation apply.
3. Set repository variables `ENABLE_PRIVATE_EKS_RUNNER=true`, `PRIVATE_EKS_RUNNER_GROUP_ID` to the custom
   group ID (greater than the default ID `1`), and `AWS_CODECONNECTION_ARN` to the authorized
   connection ARN.
4. Set the application repository variable `K8S_PRIVATE_RUNNER_PREREQUISITES_READY=true` only after
   the group and connection are configured. The coordinator then provisions the CodeBuild project in
   the foundation apply before it dispatches platform/HML plans.

The CodeBuild project runs in the private workload subnets, uses a dedicated outbound-only security
group, and reaches EKS through private DNS/TCP 443. The public EKS administrator CIDRs are unchanged.
The runner service role can write its one-day CloudWatch log stream, create VPC interfaces in the
workload subnets, and read the configured CodeConnections connection; it has no EKS, lifecycle-ledger,
or `iam:PassRole` permission. The foundation compute teardown preserves the runner project. NAT is
disabled last, after EKS and foundation compute teardown; the NAT-only plan permits an absent cluster
but still enforces the NAT-only resource guard.

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
| `gh-plan-k8s-infra` | `staging` | `.github/workflows/cluster-ci.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/destroy.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/cluster-apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-infra` | `staging` | `.github/workflows/cluster-destroy.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/destroy.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/cluster-apply.yml` | `refs/heads/main` |
| `gh-deploy-k8s-hml` | `staging` | `.github/workflows/cluster-destroy.yml` | `refs/heads/main` |
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
