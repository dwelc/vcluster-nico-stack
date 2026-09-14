#!/usr/bin/env bash
# Package the five NiCo charts from an upstream checkout and push them to an OCI registry, then
# build and push the hook image. Stacks pull charts from a registry; upstream only ships source.
#   NICO_SRC=/path/to/infra-controller REGISTRY=oci://registry.example.com/nico ./push-charts.sh
set -euo pipefail
NICO_SRC="${NICO_SRC:?path to the NVIDIA/infra-controller checkout}"
REGISTRY="${REGISTRY:?oci://host/project}"
HOOK_IMAGE="${HOOK_IMAGE:-${REGISTRY#oci://}/hook:1.33.4}"
OUT="$(mktemp -d)"; trap 'rm -rf "${OUT}"' EXIT
for c in helm helm-prereqs helm/rest/nico-rest helm/rest/nico-rest-site-agent rest-api/temporal-helm/temporal; do
    helm package "${NICO_SRC}/${c}" -d "${OUT}" >/dev/null
done
for tgz in "${OUT}"/*.tgz; do helm push "${tgz}" "${REGISTRY}"; done
echo "charts: $(ls "${OUT}" | tr '\n' ' ')"
docker build -q -t "${HOOK_IMAGE}" "$(dirname "$0")/../hook-image" >/dev/null && docker push -q "${HOOK_IMAGE}"
echo "hook image: ${HOOK_IMAGE}"
