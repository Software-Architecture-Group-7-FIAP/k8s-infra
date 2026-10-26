#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass/fail always return 0, so A && pass || fail is safe here
# Session smoke test for the k8s-infra platform (run after foundation + platform apply).
# Checks: nodes Ready, pod capacity from prefix delegation, add-ons Ready, NetworkPolicy allow/deny.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
CLUSTER="$(aws ssm get-parameter --region "$REGION" --name /auto-shop/staging/eks/cluster-name --query Parameter.Value --output text)"
# busybox's nc applet does not reliably support -z across versions; netshoot ships the
# netcat-openbsd build, where -z is well defined, plus nslookup for the DNS check.
IMAGE="ghcr.io/nicolaka/netshoot:v0.13"
MIN_PODS_PER_NODE=30
FAILURES=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILURES=$((FAILURES + 1)); }

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

echo "== Nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null && pass "all nodes Ready" || fail "nodes not Ready"
while read -r node pods; do
  if [ "$pods" -ge "$MIN_PODS_PER_NODE" ]; then pass "$node allocatable pods=$pods"; else fail "$node allocatable pods=$pods (< $MIN_PODS_PER_NODE, prefix delegation off?)"; fi
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.pods}{"\n"}{end}')

echo "== Add-ons"
for target in "kube-system deploy/coredns" "kube-system deploy/metrics-server" "kube-system deploy/aws-load-balancer-controller" "external-secrets deploy/external-secrets"; do
  # shellcheck disable=SC2086
  kubectl -n ${target% *} rollout status ${target#* } --timeout=180s >/dev/null && pass "$target" || fail "$target"
done
kubectl top nodes >/dev/null 2>&1 && pass "metrics API" || fail "metrics API"

echo "== NetworkPolicy"
pod_spec() {
  cat <<EOF
{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},
"containers":[{"name":"$1","image":"$IMAGE","command":["sh","-c","$2"],
"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"96Mi"}},
"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}
EOF
}

cleanup() {
  kubectl delete pod -n auto-shop-prd np-target --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n auto-shop-hml np-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# np-target carries the app's own Pod label and listens on the app port itself, so this is the exact
# path the allow-alb-to-api / allow-same-namespace NetworkPolicies are meant to allow or deny — not a
# stand-in on a different port.
kubectl run np-target -n auto-shop-prd --image="$IMAGE" --restart=Never \
  --labels="app=auto-shop-backend" \
  --overrides="$(pod_spec np-target "nc -lk -p 8000")" >/dev/null
kubectl run np-client -n auto-shop-hml --image="$IMAGE" --restart=Never \
  --overrides="$(pod_spec np-client 'sleep 600')" >/dev/null
kubectl wait -n auto-shop-prd --for=condition=Ready pod/np-target --timeout=120s >/dev/null
kubectl wait -n auto-shop-hml --for=condition=Ready pod/np-client --timeout=120s >/dev/null
TARGET_IP="$(kubectl get pod -n auto-shop-prd np-target -o jsonpath='{.status.podIP}')"

probe() { kubectl exec -n auto-shop-hml np-client -- sh -c "$1" >/dev/null 2>&1; }

probe "nslookup kubernetes.default.svc.cluster.local" && pass "DNS allowed" || fail "DNS blocked"
probe "nc -z -w 5 sts.${REGION}.amazonaws.com 443" && pass "HTTPS egress allowed" || fail "HTTPS egress blocked"
probe "nc -z -w 5 ${TARGET_IP} 8000" && fail "hml reached prd on the app port (must be denied; only the ALB subnets may reach it)" || pass "hml -> prd app port denied"
probe "nc -z -w 5 1.1.1.1 80" && fail "HTTP:80 egress allowed (must be denied)" || pass "HTTP:80 egress denied"

echo
if [ "$FAILURES" -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED ($FAILURES)"; exit 1; fi
