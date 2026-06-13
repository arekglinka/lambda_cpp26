# ============================================================
# Stage 1: Build environment (Amazon Linux 2023)
# ============================================================
FROM amazonlinux:2023 AS builder

ARG BUILD_TYPE=Release

# Install build tools
RUN dnf install -y \
        gcc gcc-c++ cmake ninja-build git \
        python3 python3-pip \
        tar xz curl ca-certificates \
        ncurses-devel which \
    && dnf clean all

# Install Conan 2.x
RUN pip3 install --no-cache-dir "conan>=2.4"

# Configure Conan
RUN conan remote add --url https://center2.conan.io conancenter

# Copy custom recipes and export them to the local Conan cache.
# conan install --build=missing will find these recipes and build from source.
COPY recipes/ /tmp/recipes/
RUN conan export /tmp/recipes/arrow/
RUN conan export /tmp/recipes/quantlib/

# Copy Conan profile
COPY profiles/ /root/.conan2/profiles/

# Copy project definition
WORKDIR /src
COPY conanfile.py .

# Copy source code
COPY src/ src/
COPY tests/ tests/

# Install ALL dependencies via Conan
# --build=missing: build Arrow, QuantLib, and any other deps without prebuilt binaries
# -pr:b default: use default build profile
# -pr:h al2023: use the AL2023 host profile
RUN conan install . \
    --build=missing \
    -pr:b default \
    -pr:h al2023 \
    -s:h build_type=${BUILD_TYPE} \
    -s:h compiler.cppstd=26

# Build the static library and handler binary
RUN conan build . --configure --build

# Smoke test: verify artifacts exist
RUN test -f /src/build/${BUILD_TYPE}/lib/liblambda_cpp26.a \
    && echo "✓ Static library built"
RUN test -f /src/build/${BUILD_TYPE}/bin/lambda_handler \
    && echo "✓ Handler binary built"

# ============================================================
# Stage 2: Lambda runtime image
# ============================================================
FROM public.ecr.aws/lambda/provided:al2023 AS runtime

ARG BUILD_TYPE=Release
ARG LAMBDA_DIR=/opt/lambda

# Copy the handler binary (statically linked against all deps)
COPY --from=builder /src/build/${BUILD_TYPE}/bin/lambda_handler ${LAMBDA_DIR}/bin/

# Copy the static library and headers (for downstream consumers)
COPY --from=builder /src/build/${BUILD_TYPE}/lib/ ${LAMBDA_DIR}/lib/
COPY --from=builder /src/build/${BUILD_TYPE}/include/ ${LAMBDA_DIR}/include/

# Copy bootstrap entrypoint
COPY src/bootstrap /lambda-entrypoint
RUN chmod +x /lambda-entrypoint

ENV LAMBDA_TASK_ROOT=${LAMBDA_DIR}
ENV LAMBDA_RUNTIME_DIR=/var/runtime

CMD ["/lambda-entrypoint"]
