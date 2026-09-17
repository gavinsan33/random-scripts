#!/usr/bin/env bash
# Follow-up diagnostic to scripts/diagnose-gpu-telemetry.sh.
#
# That first script confirmed: nvidia-dcgm-exporter is Running and healthy
# (logs show it serving metrics on :9400), and a correctly-configured
# ServiceMonitor for it exists in nvidia-gpu-operator, matching the Service's
# "gpu-metrics" port. So the config-on-paper looks right. What it could NOT
# confirm — several checks died mid-run to transient
# "TLS handshake timeout"/"unexpected EOF" connection errors — was whether
# Prometheus is actually reaching that endpoint and producing series.
#
# This script (a) retries the connectivity-flaky checks a few times instead of
# running them once, and (b) tests the network path directly — this cluster
# has had NetworkPolicy-caused scrape breakage before, so isolate that
# specifically: can prometheus-user-workload actually reach
# nvidia-dcgm-exporter:9400 over the network at all, independent of whether
# Prometheus's own target/scrape config is right.
#
# Run this ONCE, as a cluster-admin. Read-only except for one short-lived,
# self-deleting debug pod used to test reachability into nvidia-gpu-operator
# from inside the cluster (mirrors where Prometheus itself runs from).
#
# Output: a single timestamped text file in the current directory.
#
# Every oc call runs with --as="${AS_USER}" (default "system:admin" — this
# cluster has no "kube:admin" user). Override with e.g.:
#   AS_USER='' ./diagnose-gpu-telemetry-network.sh   # no impersonation
set -uo pipefail

AS_USER="${AS_USER-system:admin}"
AS_FLAG=""
[[ -n "${AS_USER}" ]] && AS_FLAG="--as=${AS_USER}"

OUT="dcgm-network-diagnostic-$(date +%Y%m%d-%H%M%S).txt"

section() {
    {
        echo
        echo "=================================================================="
        echo "== $1"
        echo "=================================================================="
    } >>"${OUT}"
}

# Retries a command up to 4 times (5s apart) if it errors, instead of running
# once — the previous run showed the client<->API-server connection itself is
# intermittently flaky ("TLS handshake timeout", "unexpected EOF"), which
# otherwise looks identical to a real "no data" finding.
run_retry() {
    local cmd="$1"
    local attempt
    for attempt in 1 2 3 4; do
        echo "+ [attempt ${attempt}/4] ${cmd}" >>"${OUT}"
        if eval "${cmd}" >>"${OUT}" 2>&1; then
            echo >>"${OUT}"
            return 0
        fi
        echo "  (failed, retrying in 5s...)" >>"${OUT}"
        sleep 5
    done
    echo "  GAVE UP after 4 attempts — treat this section as inconclusive, not a finding." >>"${OUT}"
    echo >>"${OUT}"
}

echo "Writing diagnostic report to ${OUT}"

section "Full Prometheus target list (user-workload), retried — looking for the dcgm-exporter target and its health/lastError"
run_retry "oc ${AS_FLAG} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- wget -qO- http://localhost:9090/api/v1/targets | python3 -m json.tool 2>/dev/null || oc ${AS_FLAG} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- wget -qO- http://localhost:9090/api/v1/targets"

section "All DCGM_* metric names known to Prometheus (user-workload), retried"
run_retry "oc ${AS_FLAG} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep -i dcgm"

section "cluster-monitoring-view RBAC, retried"
run_retry "oc ${AS_FLAG} get clusterrolebinding -o yaml | grep -i -B5 -A15 'cluster-monitoring-view'"

section "NetworkPolicies: nvidia-gpu-operator namespace (where dcgm-exporter lives)"
run_retry "oc ${AS_FLAG} get networkpolicy -n nvidia-gpu-operator -o yaml"

section "NetworkPolicies: openshift-user-workload-monitoring namespace (where the scraper lives)"
run_retry "oc ${AS_FLAG} get networkpolicy -n openshift-user-workload-monitoring -o yaml"

section "NetworkPolicies cluster-wide (any default-deny or ingress-restricting policy that could affect port 9400 scraping)"
run_retry "oc ${AS_FLAG} get networkpolicy -A"

section "AdminNetworkPolicy / BaselineAdminNetworkPolicy (cluster-scoped, can override namespace NetworkPolicies)"
run_retry "oc ${AS_FLAG} get adminnetworkpolicy -o yaml"
run_retry "oc ${AS_FLAG} get baselineadminnetworkpolicy -o yaml"

section "EgressFirewall in nvidia-gpu-operator (unlikely to matter for ingress scraping, but cheap to rule out)"
run_retry "oc ${AS_FLAG} get egressfirewall -n nvidia-gpu-operator -o yaml"

section "Namespace labels (NetworkPolicies commonly select on these — confirms whether monitoring traffic is allow-listed by label)"
run_retry "oc ${AS_FLAG} get ns nvidia-gpu-operator --show-labels"
run_retry "oc ${AS_FLAG} get ns openshift-user-workload-monitoring --show-labels"
run_retry "oc ${AS_FLAG} get ns openshift-monitoring --show-labels"

section "Direct reachability test: from a pod in nvidia-gpu-operator itself, curl the dcgm-exporter metrics endpoint (sanity check — confirms the exporter answers on its own Service, independent of any policy)"
POD_SCRIPT_LOCAL=$(cat <<'PODSCRIPT'
echo "--- curl http://nvidia-dcgm-exporter.nvidia-gpu-operator.svc:9400/metrics (from inside nvidia-gpu-operator) ---"
curl -s -m 10 -o /tmp/out -w 'HTTP %{http_code}, %{size_download} bytes\n' http://nvidia-dcgm-exporter.nvidia-gpu-operator.svc:9400/metrics
head -20 /tmp/out
PODSCRIPT
)
POD_SCRIPT_LOCAL_B64=$(printf '%s' "${POD_SCRIPT_LOCAL}" | base64 -w0)
run_retry "oc ${AS_FLAG} run aibom-diag-net-local -n nvidia-gpu-operator --rm -i --restart=Never --image=registry.redhat.io/ubi9/ubi-minimal:latest -- /bin/sh -c \"echo ${POD_SCRIPT_LOCAL_B64} | base64 -d | sh\""

section "Cross-namespace reachability test: same curl, but launched from openshift-user-workload-monitoring — this is the actual path Prometheus's scrape traffic takes, and the one a restrictive NetworkPolicy in nvidia-gpu-operator would block"
run_retry "oc ${AS_FLAG} run aibom-diag-net-cross -n openshift-user-workload-monitoring --rm -i --restart=Never --image=registry.redhat.io/ubi9/ubi-minimal:latest -- /bin/sh -c \"echo ${POD_SCRIPT_LOCAL_B64} | base64 -d | sh\""

section "Live GPU metric query against Thanos Querier, from an in-cluster debug pod, retried"
POD_SCRIPT=$(cat <<'PODSCRIPT'
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
BASE="https://thanos-querier.openshift-monitoring.svc:9091/api/v1"
END=$(date -u +%s)
START=$((END - 21600))
echo "--- DCGM_FI_DEV_GPU_UTIL, last 6h ---"
curl -sk -H "Authorization: Bearer ${TOKEN}" --data-urlencode "query=DCGM_FI_DEV_GPU_UTIL" --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "step=300" "${BASE}/query_range"
echo
echo "--- any DCGM_* metric names known to Prometheus at all (label metadata, not time-bound) ---"
curl -sk -H "Authorization: Bearer ${TOKEN}" "${BASE}/label/__name__/values" | tr ',' '\n' | grep -i dcgm
echo "--- up{job=~\".*dcgm.*\"}, last 6h ---"
curl -sk -H "Authorization: Bearer ${TOKEN}" --data-urlencode 'query=up{job=~".*dcgm.*"}' --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "step=300" "${BASE}/query_range"
PODSCRIPT
)
POD_SCRIPT_B64=$(printf '%s' "${POD_SCRIPT}" | base64 -w0)
run_retry "oc ${AS_FLAG} run aibom-diag-thanos-check -n project-gavin-test --rm -i --restart=Never --image=registry.redhat.io/ubi9/ubi-minimal:latest --overrides='{\"spec\":{\"serviceAccountName\":\"default\"}}' -- /bin/sh -c \"echo ${POD_SCRIPT_B64} | base64 -d | sh\""

section "Done"
echo "Report written to: ${OUT}" >>"${OUT}"
echo "Diagnostic complete. Please send back the file: ${OUT}"
