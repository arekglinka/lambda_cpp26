# ============================================================
# Lambda C++26 — Podman Build Orchestration
# ============================================================

IMAGE_NAME    ?= lambda-cpp26
CONTAINERFILE ?= Containerfile
BUILD_TYPE    ?= Release

PODMAN        ?= podman
PODMAN_BUILD  := $(PODMAN) build -f $(CONTAINERFILE)
PODMAN_RUN    := $(PODMAN) run --rm

.PHONY: all build build-dev build-prod test test-prod shell clean help

all: build

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: build-dev build-prod ## Build both dev and prod images

build-dev: ## Build development image (with debug tools)
	@echo "==> Building dev image..."
	$(PODMAN_BUILD) \
		--target dev \
		-t $(IMAGE_NAME):dev \
		--build-arg BUILD_TYPE=$(BUILD_TYPE)
	@echo "==> Dev image ready: $(IMAGE_NAME):dev"

build-prod: ## Build production image (stripped, minimal)
	@echo "==> Building prod image..."
	$(PODMAN_BUILD) \
		--target prod \
		-t $(IMAGE_NAME):prod \
		--build-arg BUILD_TYPE=$(BUILD_TYPE)
	@echo "==> Prod image ready: $(IMAGE_NAME):prod"

test: build-dev ## Run local Lambda test via RIE (dev image)
	@echo "==> Starting Lambda container (dev)..."
	$(PODMAN_RUN) -d --name lambda-test \
		-p 9000:8080 \
		-e AWS_LAMBDA_FUNCTION_TIMEOUT=30 \
		-e AWS_LAMBDA_FUNCTION_MEMORY_SIZE=512 \
		$(IMAGE_NAME):dev
	@echo "==> Waiting for RIE..."
	@sleep 3
	@echo "==> Invoking handler..."
	@curl -s -X POST http://localhost:9000/2015-03-31/functions/function/invocations \
		-H "Content-Type: application/json" \
		-d @events/test-event.json || true
	@echo ""
	@echo "==> Stopping container..."
	@$(PODMAN) stop lambda-test > /dev/null 2>&1 || true
	@$(PODMAN) rm lambda-test > /dev/null 2>&1 || true
	@echo "==> Done"

test-prod: build-prod ## Test production image (smoke test only)
	@echo "==> Starting Lambda container (prod)..."
	$(PODMAN_RUN) -d --name lambda-test-prod \
		-p 9001:8080 \
		-e AWS_LAMBDA_FUNCTION_TIMEOUT=30 \
		$(IMAGE_NAME):prod
	@sleep 3
	@echo "==> Invoking handler..."
	@curl -s -X POST http://localhost:9001/2015-03-31/functions/function/invocations \
		-H "Content-Type: application/json" \
		-d @events/test-event.json || true
	@echo ""
	@$(PODMAN) stop lambda-test-prod > /dev/null 2>&1 || true
	@$(PODMAN) rm lambda-test-prod > /dev/null 2>&1 || true
	@echo "==> Done"

shell: build-dev ## Drop into dev container shell
	$(PODMAN_RUN) -it \
		--entrypoint /bin/bash \
		$(IMAGE_NAME):dev

debug: build-dev ## Start dev container in background for debugger attach
	$(PODMAN) run -d --name lambda-debug \
		-p 9000:8080 \
		-e AWS_LAMBDA_FUNCTION_TIMEOUT=900 \
		$(IMAGE_NAME):dev
	@echo "==> Dev container running as 'lambda-debug'. Attach VSCode debugger now."
	@echo "==> Invoke with: curl -X POST http://localhost:9000/2015-03-31/functions/function/invocations -H 'Content-Type: application/json' -d @events/test-event.json"

stop-debug: ## Stop the debug container
	@$(PODMAN) stop lambda-debug > /dev/null 2>&1 || true
	@$(PODMAN) rm lambda-debug > /dev/null 2>&1 || true
	@echo "==> Debug container stopped"

clean: ## Remove images and clean build artifacts
	@echo "==> Cleaning..."
	$(PODMAN) rmi -f $(IMAGE_NAME):dev 2>/dev/null || true
	$(PODMAN) rmi -f $(IMAGE_NAME):prod 2>/dev/null || true
	$(PODMAN) image prune -f 2>/dev/null || true
	rm -rf CMakeUserPresets.json CMakeCache.txt compile_commands.json
	@echo "==> Clean"
