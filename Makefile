# osnova — automation entrypoint. `make` or `make help` lists targets.

.DEFAULT_GOAL := help

PRE_COMMIT ?= pre-commit

.PHONY: help lint format test install-hooks clean build smoke scan digests

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "; printf "\nosnova — make targets\n"} \
		/^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
		/^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST)
	@echo ""

##@ Quality

lint: ## Run every linter (pre-commit on all files)
	@$(PRE_COMMIT) run --all-files

format: ## Auto-fix whitespace and end-of-file
	@$(PRE_COMMIT) run trailing-whitespace --all-files
	@$(PRE_COMMIT) run end-of-file-fixer --all-files

test: ## Run every suite under tests/
	@bash tests/run.sh

##@ Development

install-hooks: ## Install the pre-commit git hooks
	@$(PRE_COMMIT) install

clean: ## Remove throwaway scratch and editor leftovers
	@rm -rf .tmp/ ./*.bak ./*.orig
	@echo "Cleaned: .tmp/ *.bak *.orig"

##@ Images

IMAGE ?= ghcr.io/denyka/osnova/debian13:latest

build: ## Resolve the bases, then bake every target for this host's architecture, loaded locally
	@bases="$$(bash tools/resolve_bases.sh)" || exit 1; \
	epoch="$$(date -u +%s)"; \
	created="$$(date -u -d "@$${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$${epoch}" +%Y-%m-%dT%H:%M:%SZ)"; \
	env $${bases} \
		REVISION="$$(git rev-parse HEAD)" CREATED="$${created}" SOURCE_DATE_EPOCH="$${epoch}" \
		docker buildx bake --load

smoke: ## Boot IMAGE=<ref> under both run contracts and assert the systemd contract
	@OSNOVA_SMOKE_IMAGE="$(IMAGE)" bash tests/smoke.sh

scan: ## Trivy IMAGE=<ref> with the pipeline's settings: fixable HIGH and CRITICAL fail
	@trivy image --image-src docker --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 "$(IMAGE)"

digests: ## Print the live base digests the next build would use
	@bash tools/resolve_bases.sh
