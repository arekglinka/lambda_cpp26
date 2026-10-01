# ============================================================
# Lambda C++26 — pybind11 Extension Podman Build Orchestration
# ============================================================

IMAGE_NAME    ?= lambda-cpp26
CONTAINERFILE ?= Containerfile
BUILD_TYPE    ?= Release

PODMAN        ?= podman
PODMAN_BUILD  := $(PODMAN) build -f $(CONTAINERFILE)
PODMAN_RUN    := $(PODMAN) run --rm

# Size budget for the stripped .so (80 MB — research bg_9aeab9a8 estimate
# for Arrow core+parquet+compute+QuantLib, no AWS SDK).
SIZE_BUDGET   ?= 83886080

.PHONY: all base dev-exec dev-up build test ci sample clean shell check-wheels help

all: build

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'begin {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ---- Shared toolchain base (same stages as CI base-image.yml) ----
# Per-stage content hashes come from scripts/base-stage-hash.sh (single
# source of truth, shared with CI and build-devcontainer.sh): editing one
# stage only invalidates that stage and its descendants.

BASE_IMAGE ?= ghcr.io/arekglinka/lambda_cpp26-base

H_TC    := $(shell scripts/base-stage-hash.sh toolchain)
H_PY    := $(shell scripts/base-stage-hash.sh python-stack)
H_CONAN := $(shell scripts/base-stage-hash.sh conan-deps)
H_AG    := $(shell scripts/base-stage-hash.sh agents)

base: ## Build cached base stages locally (tagged by content hash; CI-only by default)
	@set -e; \
	stages="toolchain:$(H_TC)-toolchain python-stack:$(H_PY)-python conan-deps:$(H_CONAN)-conan agents:$(H_AG)"; \
	missing=""; \
	for pair in $$stages; do \
		stage=$${pair%%:*}; tag=$${pair#*:}; \
		if $(PODMAN) image exists $(BASE_IMAGE):$$tag; then \
			echo "==> Base stage $$stage ($$tag) already local"; \
		else \
			missing="$$missing $$pair"; \
		fi; \
	done; \
	if [ -n "$$missing" ] && [ "$${ALLOW_LOCAL_BASE_BUILD:-0}" != "1" ]; then \
		echo "ERROR: missing base stage(s):$$missing" >&2; \
		echo "Heavy base builds run in CI only (GCC/Arrow/QuantLib compiles stress this machine)." >&2; \
		echo "  -> Trigger CI: push to main, or: gh workflow run base-image.yml" >&2; \
		echo "  -> Local override (at your own risk): ALLOW_LOCAL_BASE_BUILD=1 make base" >&2; \
		exit 1; \
	fi; \
	for pair in $$missing; do \
		stage=$${pair%%:*}; tag=$${pair#*:}; \
		echo "==> Building base stage $$stage ($$tag) (ALLOW_LOCAL_BASE_BUILD=1)..."; \
		$(PODMAN) build -f Containerfile.base --target $$stage -t $(BASE_IMAGE):$$tag .; \
	done; \
	$(PODMAN) tag $(BASE_IMAGE):$(H_AG) $(BASE_IMAGE):latest

# ---- Exec into the running devcontainer ----

dev-exec: ## Shell into the running devcontainer (VS Code names it vsc-lambda_cpp26-*; first-run omo auth happens here)
	@$(PODMAN) exec -it $$(podman ps --filter name=vsc-lambda_cpp26 --format '{{.Names}}' | head -1) bash

dev-up: ## Pre-flight + pull + smoke-test the devcontainer image locally
	@bash scripts/dev-up.sh

# ---- Build the pybind11 extension .so (builder stage) ----

build: ## Build the pybind11 .so extension (builder stage)
	@echo "==> Building pybind11 extension..."
	$(PODMAN_BUILD) \
		--target builder \
		-t $(IMAGE_NAME):builder \
		--build-arg BUILD_TYPE=$(BUILD_TYPE)
	@echo "==> Builder image ready: $(IMAGE_NAME):builder"
	@echo "==> Extracting .so..."
	@$(PODMAN) run --rm --entrypoint sh $(IMAGE_NAME):builder -c 'cat /tmp/sum_columns.so' > sum_columns.so 2>/dev/null || \
		echo "==> WARNING: .so not found — check the builder stage"
	@ls -lh sum_columns.so 2>/dev/null || true

# ---- Cleanroom test (pure Lambda python base + .so + local parquet) ----

test: ## Build + run the Lambda Python cleanroom test (test stage)
	@echo "==> Building test image..."
	$(PODMAN_BUILD) \
		--target test \
		-t $(IMAGE_NAME):test \
		--build-arg BUILD_TYPE=$(BUILD_TYPE)
	@echo "==> Cleanroom test passed (built into the test stage)."

# ---- Full CI sequence: build → test → size budget ----

ci: build test ## Full pipeline: build .so, run cleanroom test, check size budget
	@echo "==> Checking size budget..."
	@SIZE=$$(stat -c%s sum_columns.so 2>/dev/null || echo 0); \
	if [ "$$SIZE" -gt $(SIZE_BUDGET) ]; then \
		echo "FAIL: .so is $$SIZE bytes (budget: $(SIZE_BUDGET))"; \
		exit 1; \
	else \
		echo "OK: .so is $$SIZE bytes (budget: $(SIZE_BUDGET))"; \
	fi
	@echo "==> CI PASS"

# ---- RIE invocation (local Lambda emulator) ----

run: test ## Start the test image via RIE and invoke the handler
	@echo "==> Starting Lambda container (RIE)..."
	-$(PODMAN) rm -f lambda-test 2>/dev/null
	$(PODMAN) run -d --name lambda-test \
		-p 9000:8080 \
		$(IMAGE_NAME):test
	@echo "==> Waiting for RIE..."
	@sleep 3
	@echo "==> Invoking handler..."
	@curl -s -X POST http://localhost:9000/2015-03-31/functions/function/invocations \
		-H "Content-Type: application/json" \
		-d '{"input": "test"}' || true
	@echo ""
	@$(PODMAN) stop lambda-test > /dev/null 2>&1 || true
	@$(PODMAN) rm lambda-test > /dev/null 2>&1 || true
	@echo "==> Done"

# ---- Utilities ----

sample: ## Regenerate data/sample.parquet
	python3 generate_sample.py

shell: build ## Drop into the builder container shell
	$(PODMAN_RUN) -it --entrypoint /bin/bash $(IMAGE_NAME):builder

check-wheels: ## Probe cp-wheel availability for a Python version (default 3.14)
	@bash scripts/check-wheels.sh ${PY}

inspect: build ## Run ldd + readelf on the .so inside the builder
	@echo "==> ldd:"; $(PODMAN) run --rm --entrypoint sh $(IMAGE_NAME):builder -c 'ldd /tmp/sum_columns.so' 2>&1 || true
	@echo "==> NEEDED:"; $(PODMAN) run --rm --entrypoint sh $(IMAGE_NAME):builder -c 'readelf -d /tmp/sum_columns.so' 2>/dev/null | grep NEEDED || echo "(none)"

clean: ## Remove images and clean build artifacts
	@echo "==> Cleaning..."
	$(PODMAN) rmi -f $(IMAGE_NAME):builder 2>/dev/null || true
	$(PODMAN) rmi -f $(IMAGE_NAME):test 2>/dev/null || true
	$(PODMAN) image prune -f 2>/dev/null || true
	rm -f sum_columns.so
	@echo "==> Clean"
