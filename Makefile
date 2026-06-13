# ============================================================
# Lambda C++26 — Podman Build Orchestration
# ============================================================

# Configurable via environment or command line
IMAGE_NAME    ?= lambda-cpp26
CONTAINERFILE ?= Containerfile
BUILD_TYPE    ?= Release
PROFILE       ?= al2023

# Podman flags
PODMAN        ?= podman
PODMAN_BUILD  := $(PODMAN) build -f $(CONTAINERFILE)
PODMAN_RUN    := $(PODMAN) run --rm

# ============================================================
# Targets
# ============================================================
.PHONY: all build test shell clean help push

all: build

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the Lambda image
	@echo "==> Building Lambda image..."
	$(PODMAN_BUILD) \
		-t $(IMAGE_NAME) \
		--build-arg BUILD_TYPE=$(BUILD_TYPE)
	@echo "==> Image ready: $(IMAGE_NAME)"

test: build ## Build and run local Lambda test (starts RIE + curl invocation)
	@echo "==> Starting Lambda container with RIE..."
	$(PODMAN_RUN) -d --name lambda-test \
		-p 9000:8080 \
		-e AWS_LAMBDA_FUNCTION_TIMEOUT=30 \
		-e AWS_LAMBDA_FUNCTION_MEMORY_SIZE=512 \
		$(IMAGE_NAME)
	@echo "==> Waiting for RIE to be ready..."
	@sleep 2
	@echo "==> Invoking handler..."
	@curl -s -X POST http://localhost:9000/2015-03-31/functions/function/invocations \
		-H "Content-Type: application/json" \
		-d @events/test-event.json || true
	@echo ""
	@echo "==> Stopping container..."
	@$(PODMAN) stop lambda-test > /dev/null 2>&1 || true
	@$(PODMAN) rm lambda-test > /dev/null 2>&1 || true
	@echo "==> Done"

shell: build ## Drop into an interactive shell in the build image
	$(PODMAN_RUN) -it \
		--entrypoint /bin/bash \
		$(IMAGE_NAME)

clean: ## Remove image and build artifacts
	@echo "==> Cleaning..."
	$(PODMAN) rmi -f $(IMAGE_NAME) 2>/dev/null || true
	$(PODMAN) image prune -f 2>/dev/null || true
	rm -rf CMakeUserPresets.json CMakeCache.txt compile_commands.json
	@echo "==> Clean"

push: build ## Push image to ECR (requires AWS CLI + login)
	aws ecr get-login-password --region us-east-1 | \
		$(PODMAN) login --username AWS --password-stdin \
		$$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
	$(PODMAN) push $(IMAGE_NAME)
