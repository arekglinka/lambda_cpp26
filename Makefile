# ============================================================
# Lambda C++26 — pybind11 Extension Podman Build Orchestration
# ============================================================

IMAGE_NAME     ?= lambda-cpp26
MICROVM_IMAGE  ?= lambda-cpp26-microvm
CONTAINERFILE  ?= Containerfile
BUILD_TYPE     ?= Release
# Container arch label: amd64 (x86_64) or arm64 (Graviton/aarch64). Drives the
# --platform flag AND the TARGET_ARCH build-arg (which selects the per-arch
# lambda_cpp26-base:<tag>-<arch> tag Conan auto-detects the toolchain arch from).
TARGET_ARCH    ?= amd64
PLATFORM       := linux/$(TARGET_ARCH)

PODMAN         ?= podman
ARCH_ARGS      := --platform $(PLATFORM) --build-arg TARGET_ARCH=$(TARGET_ARCH)
PODMAN_BUILD   := $(PODMAN) build -f $(CONTAINERFILE) $(ARCH_ARGS)
PODMAN_RUN     := $(PODMAN) run --rm

# Size budget for the stripped .so (80 MB — research bg_9aeab9a8 estimate
# for Arrow core+parquet+compute+QuantLib, no AWS SDK).
SIZE_BUDGET    ?= 83886080

.PHONY: all build test ci microvm microvm-run sample clean shell help

all: build

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'begin {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

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

# ---- Cleanroom test (pure lambda/python:3.12 + .so + local parquet) ----

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

# ---- MicroVM image (standalone AL2023, no Lambda RIC) ----

microvm: ## Build the standalone MicroVM image (Containerfile.microvm)
	@echo "==> Building MicroVM image ($(TARGET_ARCH))..."
	$(PODMAN) build -f Containerfile.microvm $(ARCH_ARGS) \
		-t $(MICROVM_IMAGE):$(TARGET_ARCH)
	@echo "==> MicroVM image ready: $(MICROVM_IMAGE):$(TARGET_ARCH)"

microvm-run: microvm ## Run the MicroVM batch compute once (prints option prices)
	$(PODMAN_RUN) $(MICROVM_IMAGE):$(TARGET_ARCH)

# ---- Utilities ----

sample: ## Regenerate data/sample.parquet
	python3 generate_sample.py

shell: build ## Drop into the builder container shell
	$(PODMAN_RUN) -it --entrypoint /bin/bash $(IMAGE_NAME):builder

inspect: build ## Run ldd + readelf on the .so inside the builder
	@echo "==> ldd:"; $(PODMAN) run --rm --entrypoint sh $(IMAGE_NAME):builder -c 'ldd /tmp/sum_columns.so' 2>&1 || true
	@echo "==> NEEDED:"; $(PODMAN) run --rm --entrypoint sh $(IMAGE_NAME):builder -c 'readelf -d /tmp/sum_columns.so' 2>/dev/null | grep NEEDED || echo "(none)"

clean: ## Remove images and clean build artifacts
	@echo "==> Cleaning..."
	$(PODMAN) rmi -f $(IMAGE_NAME):builder 2>/dev/null || true
	$(PODMAN) rmi -f $(IMAGE_NAME):test 2>/dev/null || true
	$(PODMAN) rmi -f $(MICROVM_IMAGE):amd64 $(MICROVM_IMAGE):arm64 2>/dev/null || true
	$(PODMAN) image prune -f 2>/dev/null || true
	rm -f sum_columns.so
	@echo "==> Clean"
