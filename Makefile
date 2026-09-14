CONTEXT   ?= $(shell kubectl config current-context)
KUBECTL   := kubectl --context $(CONTEXT)
NICO_SRC  ?= /var/tmp/nico-src            # NVIDIA/infra-controller checkout at the pinned tag
REGISTRY  ?= oci://registry.example.com/nico   # OCI project holding the five NiCo charts and the hook image
SITE      ?= instances/example-nico-site.yaml
PLATFORM  ?= instances/example-nico-platform.yaml
PROJECT   ?= p-default

.PHONY: charts catalog validate install status outputs platform clean-pvs uninstall uninstall-platform roundtrip

charts:            ## package + push the five NiCo charts and the hook image
	NICO_SRC=$(NICO_SRC) REGISTRY=$(REGISTRY) ./scripts/push-charts.sh

catalog:           ## Apps and StackTemplates (cluster-scoped catalog). chart.repoURL is not templated by the Platform, so REGISTRY is substituted here.
	cat apps/*.yaml | sed 's|oci://registry.example.com/nico|$(REGISTRY)|' | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f stacktemplates/

validate:          ## admission-only dry run of the catalog and the site instance
	cat apps/*.yaml | sed 's|oci://registry.example.com/nico|$(REGISTRY)|' | $(KUBECTL) apply --dry-run=server -f -
	$(KUBECTL) apply --dry-run=server -f stacktemplates/ -f $(SITE)

install:           ## the site
	$(KUBECTL) apply -f $(SITE)

status:
	@./scripts/status.sh $(CONTEXT) $(PROJECT) nico-site

outputs:
	@$(KUBECTL) get --raw /apis/management.loft.sh/v1/namespaces/$(PROJECT)/stackinstances/nico-site/outputs | jq -r '.outputs[] | "\(.name)\t\(.value)"'

platform:          ## fills siteId/siteIpBlockId/instanceTypeId from the site's published outputs, then applies
	@O=$$($(KUBECTL) get --raw /apis/management.loft.sh/v1/namespaces/$(PROJECT)/stackinstances/nico-site/outputs); \
	v() { echo "$$O" | jq -r --arg n "$$1" '.outputs[]|select(.name==$$n)|.value'; }; \
	sed -i -e "s|^    siteId: .*|    siteId: $$(v siteId)|" -e "s|^    siteIpBlockId: .*|    siteIpBlockId: $$(v siteIPBlockID)|" \
	       -e "s|^    instanceTypeId: .*|    instanceTypeId: $$(v instanceTypeId)|" $(PLATFORM)
	$(KUBECTL) apply -f $(PLATFORM)

clean-pvs:         ## Released Retain PVs from vault/postgres of torn-down installs (data is gone with them)
	$(KUBECTL) get pv -o json | jq -r '.items[] | select(.status.phase=="Released" and (.spec.claimRef.namespace|IN("vault","postgres"))) | .metadata.name' | xargs -r $(KUBECTL) delete pv

uninstall:
	$(KUBECTL) delete stackinstance.management.loft.sh -n $(PROJECT) nico-site --wait=true

uninstall-platform:
	$(KUBECTL) delete stackinstance.management.loft.sh -n $(PROJECT) nico-platform --wait=true

roundtrip:         ## hands-off install/uninstall/install regression (scripts/roundtrip.sh)
	CONTEXT=$(CONTEXT) PROJECT=$(PROJECT) SITE=$(SITE) PLATFORM=$(PLATFORM) ./scripts/roundtrip.sh
