#!/usr/bin/env bash
# Offline render of every App with the example instance parameters plus placeholder task outputs.
# manifests Apps: helm-render the manifests and parse the result. chart Apps: render the values
# string, then helm-template the real chart with them. Catches template and values mistakes before
# the Platform does.  CHARTS=<dir with the packaged NiCo .tgz> ./render-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CHARTS="${CHARTS:-/nonexistent}"   # local .tgz dir; otherwise charts are pulled from REGISTRY
REGISTRY="${REGISTRY:?oci://host/project holding the NiCo charts}"
SITE="${SITE:-instances/example-nico-site.yaml}"; PLATFORM="${PLATFORM:-instances/example-nico-platform.yaml}"
P="$(mktemp -d)"; trap 'rm -rf "${P}"' EXIT
yq '.spec.parameters' "${SITE}" > "${P}/params.yaml"
yq '.spec.parameters' "${PLATFORM}" | yq 'del(.hookImage)' >> "${P}/params.yaml"
cat >> "${P}/params.yaml" <<'EOF'
vaultToken: hvs.placeholder
pgUser: nico-rest.nico
pgPassword: placeholder
siteId: 00000000-0000-0000-0000-000000000000
siteIpBlockId: 00000000-0000-0000-0000-000000000001
instanceTypeId: 00000000-0000-0000-0000-000000000002
temporalNamespaces: cloud site flow
prereqsChartVersion: "0.1.0"
metallbNamespace: metallb-system
lbInternalRange: 198.51.100.236-198.51.100.244
lbExternalRange: 198.51.100.245-198.51.100.245
osImageUrl: http://images.example/noble.img
osImageSha: "0000"
EOF
rc=0
for f in apps/*.yaml; do
  n=$(yq ea '[.metadata.name] | length' "${f}")
  for ((i = 0; i < n; i++)); do
    name="$(yq "select(document_index == ${i}) | .metadata.name" "${f}")"
    ns="$(yq "select(document_index == ${i}) | .spec.defaultNamespace" "${f}")"
    d="${P}/${name}"; mkdir -p "${d}/templates"
    printf 'apiVersion: v2\nname: t\nversion: 0.0.1\n' > "${d}/Chart.yaml"
    if [[ "$(yq "select(document_index == ${i}) | .spec.config.manifests // \"\"" "${f}")" != "" ]]; then
      yq "select(document_index == ${i}) | .spec.config.manifests" "${f}" > "${d}/templates/m.yaml"
      if helm template "${name}" "${d}" -f "${P}/params.yaml" --namespace "${ns}" > "${d}/out.yaml" 2> "${d}/err" \
         && yq ea '[.kind] | length' "${d}/out.yaml" > "${d}/kinds" 2>> "${d}/err"; then
        echo "ok   ${name}  ($(grep -c '^kind:' "${d}/out.yaml") objects)"
      else
        echo "FAIL ${name}: $(tail -3 "${d}/err" | tr '\n' ' ')"; rc=1
      fi
    else
      yq "select(document_index == ${i}) | .spec.config.values" "${f}" > "${d}/templates/values.yaml"
      chart="$(yq "select(document_index == ${i}) | .spec.config.chart.name" "${f}")"
      ver="$(yq "select(document_index == ${i}) | .spec.config.chart.version" "${f}")"
      repo="$(yq "select(document_index == ${i}) | .spec.config.chart.repoURL" "${f}" | sed "s|oci://registry.example.com/nico|${REGISTRY}|")"
      if ! helm template "${name}" "${d}" -f "${P}/params.yaml" --namespace "${ns}" 2> "${d}/err" | sed -e '/^---$/d' -e '/^# Source:/d' > "${d}/values.yaml"; then
        echo "FAIL ${name} (values render): $(tail -3 "${d}/err" | tr '\n' ' ')"; rc=1; continue
      fi
      src=("${CHARTS}/${chart}-${ver}.tgz")
      if [[ ! -f "${src[0]}" ]]; then
        if [[ "${repo}" == oci://* ]]; then src=("${repo}/${chart}" --version "${ver}"); else src=("${chart}" --repo "${repo}" --version "${ver}"); fi
      fi
      if helm template "${chart}" "${src[@]}" -f "${d}/values.yaml" --namespace "${ns}" > "${d}/out.yaml" 2> "${d}/err"; then
        echo "ok   ${name}  (${chart} ${ver}, $(grep -c '^kind:' "${d}/out.yaml") objects)"
      else
        echo "FAIL ${name} (${chart}): $(tail -3 "${d}/err" | tr '\n' ' ')"; rc=1
      fi
    fi
  done
done
exit "${rc}"
