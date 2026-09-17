#!/usr/bin/env bash
# One-shot diagnostic dump for whether nvidia-dcgm-exporter is actually being
# scraped into Prometheus/Thanos (root-causing why AIBOM gpu_utilization/
# gpu_memory_used/gpu_power telemetry comes back empty).
#
# Run this ONCE, as a cluster-admin (needs get/list on the nvidia-gpu-operator,
# openshift-monitoring, and openshift-user-workload-monitoring namespaces, plus
# cluster-scoped ServiceMonitor/PodMonitor/ClusterRoleBinding/ClusterPolicy).
# Read-only, except for one short-lived, self-deleting debug pod used to query
# Thanos from inside the cluster.
#
# Output: a single timestamped text file in the current directory.
#
# Every oc call below runs with --as="${AS_USER}" (default "system:admin" — this
# cluster has no "kube:admin" user; system:admin is the actual cluster-admin
# identity here) so the script itself enforces the "run as cluster-admin"
# requirement rather than assuming the invoker already switched context — this
# only works if the identity you're currently logged in as already holds the
# "impersonate" verb for that user/group; if not, override with e.g.:
#   AS_USER='' ./diagnose-gpu-telemetry.sh   # no impersonation, use current login as-is
set -uo pipefail

AS_USER="${AS_USER-system:admin}"
AS_FLAG=""
[[ -n "${AS_USER}" ]] && AS_FLAG="--as=${AS_USER}"

OUT="dcgm-config-diagnostic-$(date +%Y%m%d-%H%M%S).txt"

section() {
    {
        echo
        echo "=================================================================="
        echo "== $1"
        echo "=================================================================="
    } >>"${OUT}"
}

run() {
    echo "+ $*" >>"${OUT}"
    eval "$@" >>"${OUT}" 2>&1
    echo >>"${OUT}"
}

echo "Writing diagnostic report to ${OUT}"

section "NVIDIA GPU Operator namespace: dcgm-exporter"
run "oc ${AS_FLAG} get pods -n nvidia-gpu-operator -o wide"
run "oc ${AS_FLAG} get clusterpolicy -o yaml"
run "oc ${AS_FLAG} get svc -n nvidia-gpu-operator"
run "oc ${AS_FLAG} get svc -n nvidia-gpu-operator -o yaml"
run "oc ${AS_FLAG} get endpoints -n nvidia-gpu-operator"
run "oc ${AS_FLAG} get daemonset -n nvidia-gpu-operator"
run "oc ${AS_FLAG} logs -n nvidia-gpu-operator -l app=nvidia-dcgm-exporter --tail=100 --all-containers"

section "ServiceMonitors / PodMonitors (cluster-wide, and filtered for gpu/dcgm)"
run "oc ${AS_FLAG} get servicemonitor -A"
run "oc ${AS_FLAG} get podmonitor -A"
run "oc ${AS_FLAG} get servicemonitor -A -o yaml | grep -i -B10 -A30 dcgm"
run "oc ${AS_FLAG} get podmonitor -A -o yaml | grep -i -B10 -A30 dcgm"

section "Cluster monitoring configuration"
run "oc ${AS_FLAG} get cm cluster-monitoring-config -n openshift-monitoring -o yaml"
run "oc ${AS_FLAG} get cm user-workload-monitoring-config -n openshift-user-workload-monitoring -o yaml"
run "oc ${AS_FLAG} get pods -n openshift-user-workload-monitoring -o wide"

section "Prometheus active scrape targets and metric names (raw API dump, grep for dcgm)"
run "oc ${AS_FLAG} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- wget -qO- http://localhost:9090/api/v1/targets | tr ',' '\n' | grep -i -B2 -A10 dcgm"
run "oc ${AS_FLAG} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep -i dcgm"

section "cluster-monitoring-view RBAC (needed to auth to Thanos Querier)"
run "oc ${AS_FLAG} get clusterrolebinding -o wide | grep -i monitoring-view"
run "oc ${AS_FLAG} get clusterrolebinding -o yaml | grep -i -B5 -A15 'cluster-monitoring-view'"

section "Live GPU metric query against Thanos Querier, from an in-cluster debug pod"
# Uses query_range over the last 6h (5m step) rather than an instant query at
# "now" — an instant query can come back empty just from scrape/query timing
# even when the series exists and is being scraped fine, if updates are
# infrequent relative to the exact moment queried.
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
echo "--- up{job=~\".*dcgm.*\"}, last 6h (confirms the scrape target itself, independent of any single metric) ---"
curl -sk -H "Authorization: Bearer ${TOKEN}" --data-urlencode 'query=up{job=~".*dcgm.*"}' --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "step=300" "${BASE}/query_range"
PODSCRIPT
)
POD_SCRIPT_B64=$(printf '%s' "${POD_SCRIPT}" | base64 -w0)
run "oc ${AS_FLAG} run aibom-diag-thanos-check -n project-gavin-test --rm -i --restart=Never --image=registry.redhat.io/ubi9/ubi-minimal:latest --overrides='{\"spec\":{\"serviceAccountName\":\"default\"}}' -- /bin/sh -c \"echo ${POD_SCRIPT_B64} | base64 -d | sh\""

section "Done"
echo "Report written to: ${OUT}" >>"${OUT}"
echo "Diagnostic complete. Please send back the file: ${OUT}"
