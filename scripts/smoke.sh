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
  kubectl delete pod -n auto-shop-prd np-target np-prd-peer --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n auto-shop-hml np-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# np-target carries the app's own Pod label and listens on the app port itself, so this is the exact
# path the allow-alb-to-api / allow-same-namespace NetworkPolicies are meant to allow or deny — not a
# stand-in on a different port. "-l PORT" (not "-l -p PORT"): netcat-openbsd rejects -p with -l,
# since -p is the source port for outbound connections and the listen port is positional.
kubectl run np-target -n auto-shop-prd --image="$IMAGE" --restart=Never \
  --labels="app=auto-shop-backend" \
  --overrides="$(pod_spec np-target "nc -lk 8000")" >/dev/null
kubectl run np-prd-peer -n auto-shop-prd --image="$IMAGE" --restart=Never \
  --overrides="$(pod_spec np-prd-peer 'sleep 600')" >/dev/null
kubectl run np-client -n auto-shop-hml --image="$IMAGE" --restart=Never \
  --overrides="$(pod_spec np-client 'sleep 600')" >/dev/null
kubectl wait -n auto-shop-prd --for=condition=Ready pod/np-target --timeout=300s >/dev/null
kubectl wait -n auto-shop-prd --for=condition=Ready pod/np-prd-peer --timeout=300s >/dev/null
kubectl wait -n auto-shop-hml --for=condition=Ready pod/np-client --timeout=300s >/dev/null
TARGET_IP="$(kubectl get pod -n auto-shop-prd np-target -o jsonpath='{.status.podIP}')"

probe() { kubectl exec -n "$1" "$2" -- sh -c "$3" >/dev/null 2>&1; }

# Positive control first: if np-target can't even be reached from its own namespace (allow-same-
# namespace), np-target itself is broken (crashed, wrong port, image pull failure) and the two
# cross-namespace denies below would read as "denied" for the wrong reason — a dead target looks
# identical to a correctly blocked one. Fail loud and skip the misleading negative checks.
if probe auto-shop-prd np-prd-peer "nc -z -w 5 ${TARGET_IP} 8000"; then
  pass "np-target reachable from its own namespace (positive control)"
  probe auto-shop-hml np-client "nc -z -w 5 ${TARGET_IP} 8000" \
    && fail "hml reached prd on the app port (must be denied; only the ALB subnets may reach it)" \
    || pass "hml -> prd app port denied"
else
  fail "np-target unreachable even within its own namespace — the deny checks below would be meaningless, skipping them"
fi

probe auto-shop-hml np-client "nslookup kubernetes.default.svc.cluster.local" && pass "DNS allowed" || fail "DNS blocked"
probe auto-shop-hml np-client "nc -z -w 5 sts.${REGION}.amazonaws.com 443" && pass "HTTPS egress allowed" || fail "HTTPS egress blocked"
probe auto-shop-hml np-client "nc -z -w 5 1.1.1.1 80" && fail "HTTP:80 egress allowed (must be denied)" || pass "HTTP:80 egress denied"

echo
if [ "$FAILURES" -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED ($FAILURES)"; exit 1; fi
