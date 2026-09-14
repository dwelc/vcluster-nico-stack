#!/usr/bin/env bash
# Hands-off round trip: (wait for a Healthy site) -> platform -> uninstall both -> leftover audit
# -> install both -> summary. Stops at the first failure. CONTEXT/PROJECT as in the Makefile.
set -euo pipefail
cd "$(dirname "$0")/.."
CONTEXT="${CONTEXT:-$(kubectl config current-context)}"; PROJECT="${PROJECT:-p-default}"
SITE="${SITE:-instances/example-nico-site.yaml}"; PLATFORM="${PLATFORM:-instances/example-nico-platform.yaml}"
K=(kubectl --context "${CONTEXT}")
ts() { date -u +%H:%M:%S; }
log() { echo "[$(ts)] $*"; }
phase() { "${K[@]}" get stackinstances.management.loft.sh -n "${PROJECT}" "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true; }
wait_phase() { # name Healthy timeout-seconds
  local d=$(( $(date +%s) + $3 )) p
  while :; do
    p="$(phase "$1")"
    [[ "${p}" == "$2" ]] && { log "$1 is $2"; return 0; }
    if [[ "${p}" == Degraded ]]; then
      log "$1 is Degraded:"; ./scripts/status.sh "${CONTEXT}" "${PROJECT}" "$1" | grep -E 'Failed'; return 1
    fi
    (( $(date +%s) < d )) || { log "timeout waiting for $1 to be $2 (now: ${p:-absent})"; return 1; }
    sleep 30
  done
}
wait_gone() { # name timeout-seconds
  local d=$(( $(date +%s) + $2 ))
  while "${K[@]}" get stackinstances.management.loft.sh -n "${PROJECT}" "$1" >/dev/null 2>&1; do
    (( $(date +%s) < d )) || { log "timeout waiting for $1 to be deleted"; return 1; }
    sleep 20
  done
  log "$1 deleted"
}
wait_namespaces() { # namespaces are deleted asynchronously after the namespaces release is uninstalled
  local d=$(( $(date +%s) + 900 )) left
  while :; do
    left="$("${K[@]}" get ns -o name 2>/dev/null | grep -E '^namespace/(nico-system|nico-rest|temporal|vault|postgres|external-secrets|forge-system)$' | tr '\n' ' ' || true)"
    [[ -z "${left}" ]] && { log "stack namespaces gone"; return 0; }
    (( $(date +%s) < d )) || { log "namespaces still terminating: ${left}"; return 1; }
    sleep 15
  done
}
audit() {
  log "leftover audit"
  local bad=0
  "${K[@]}" get ns -o name | grep -E '^namespace/(nico-system|nico-rest|temporal|vault|postgres|external-secrets|forge-system|p-nico-demo--default)$' && bad=1
  "${K[@]}" get appinstances.management.loft.sh -n "${PROJECT}" -o name | grep -E 'nico-(site|platform)-' && bad=1
  "${K[@]}" get nodeproviders.management.loft.sh,networkenvironments.management.loft.sh,tenants.management.loft.sh -o name 2>/dev/null | grep -E '/(nico|nico-flat|nico-demo)$' && bad=1
  "${K[@]}" get clusterrolebindings -o name | grep nico-stack && bad=1
  "${K[@]}" get clusterissuers -o name | grep -E 'site-issuer|selfsigned-bootstrap|vault-nico|nico-rest' && bad=1
  "${K[@]}" get pvc -A --no-headers 2>/dev/null | grep -E '^(vault|postgres|temporal|nico-system|nico-rest) ' && bad=1
  local rel; rel="$("${K[@]}" get pv -o json | jq '[.items[]|select(.status.phase=="Released" and (.spec.claimRef.namespace|IN("vault","postgres")))]|length')"
  log "released Retain PVs from vault/postgres: ${rel} (kept by StorageClass policy; make clean-pvs removes them)"
  (( bad == 0 )) && log "audit clean" || { log "audit found leftovers above"; return 1; }
}

T0=$(date +%s)
if [[ -n "${SKIP_FIRST:-}" ]]; then
  log "SKIP_FIRST set: resuming at the leftover audit"; T1=$T0; wait_namespaces; audit; T2=$(date +%s)
else
log "waiting for nico-site (current install)"; wait_phase nico-site Healthy 3600
log "platform"; make -s platform CONTEXT="${CONTEXT}" PROJECT="${PROJECT}" SITE="${SITE}" PLATFORM="${PLATFORM}" >/dev/null; wait_phase nico-platform Healthy 900
"${K[@]}" get nodeproviders.management.loft.sh nico -o jsonpath='{"provider "}{.status.phase}{"\n"}'
"${K[@]}" get nodetypes.management.loft.sh -o name | grep 'nico\.' || { log "no NodeType"; exit 1; }
T1=$(date +%s)

log "uninstall-platform"; "${K[@]}" delete stackinstances.management.loft.sh -n "${PROJECT}" nico-platform --wait=false >/dev/null; wait_gone nico-platform 900
log "uninstall site"; "${K[@]}" delete stackinstances.management.loft.sh -n "${PROJECT}" nico-site --wait=false >/dev/null; wait_gone nico-site 2700
wait_namespaces
T2=$(date +%s)
audit
fi

log "install site"; "${K[@]}" apply -f "${SITE}" >/dev/null; wait_phase nico-site Healthy 3600
log "platform"; make -s platform CONTEXT="${CONTEXT}" PROJECT="${PROJECT}" SITE="${SITE}" PLATFORM="${PLATFORM}" >/dev/null; wait_phase nico-platform Healthy 900
T3=$(date +%s)
"${K[@]}" get nodeproviders.management.loft.sh nico -o jsonpath='{"provider "}{.status.phase}{"\n"}'
"${K[@]}" get tenants.management.loft.sh nico-demo -o json | jq -r '.status.conditions[]|"tenant \(.type)=\(.status)"'
"${K[@]}" get networkenvironments.management.loft.sh nico-flat -o jsonpath='{"NE "}{.status.phase}{"\n"}'
"${K[@]}" get machines.management.loft.sh -o name | grep -c '/nico\.' | sed 's/^/machines mirrored: /'
log "ROUND TRIP OK: first platform $((T1-T0))s, uninstall $((T2-T1))s, reinstall $((T3-T2))s"
