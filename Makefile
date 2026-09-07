IMAGE       ?= cups-server
REGISTRY    ?= ghcr.io/SilentVoltage
DOCKERHUB   ?= docker.io/SilentVoltage
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLATFORMS   ?= linux/amd64,linux/arm64
DRIVERS     ?= printer-driver-cups-pdf printer-driver-gutenprint foomatic-db-compressed-ppds

.PHONY: help lint build push test shell scan sbom clean
help: ## Show targets
	@grep -hE "^[a-zA-Z_-]+:.*?## " $(MAKEFILE_LIST) | awk -F":.*?## " "{printf \"\\033[36m%-12s\\033[0m %s\n\", \$$1, \$$2}"

lint: ## hadolint + shellcheck
	docker run --rm -i hadolint/hadolint < Dockerfile
	docker run --rm -v $(PWD):/mnt -w /mnt koalaman/shellcheck:stable rootfs/usr/local/bin/*.sh

build: ## Local single-arch build
	docker buildx build --load \
	  --build-arg CUPS_DRIVER_PACKAGES="$(DRIVERS)" \
	  -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

push: ## Multi-arch build and push to both registries
	docker buildx build --push --platform $(PLATFORMS) \
	  --build-arg CUPS_DRIVER_PACKAGES="$(DRIVERS)" \
	  --provenance=true --sbom=true \
	  -t $(REGISTRY)/$(IMAGE):$(VERSION) -t $(REGISTRY)/$(IMAGE):latest \
	  -t $(DOCKERHUB)/$(IMAGE):$(VERSION) -t $(DOCKERHUB)/$(IMAGE):latest .

test: build ## Smoke test the built image
	./test/smoke.sh $(IMAGE):$(VERSION)

scan: ## Trivy scan
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(IMAGE):$(VERSION)

sbom: ## Generate SPDX SBOM
	syft $(IMAGE):$(VERSION) -o spdx-json=sbom.spdx.json

shell: ## Interactive shell in the image
	docker run --rm -it --entrypoint /bin/bash $(IMAGE):$(VERSION)

clean:
	docker rmi -f $(IMAGE):$(VERSION) $(IMAGE):latest 2>/dev/null || true
