# ============================================================
# Stage 1: Builder — Conan package (library + handler)
# ============================================================
FROM amazonlinux:2023 AS builder

ARG BUILD_TYPE=Release

RUN dnf install -y \
        gcc gcc-c++ binutils cmake ninja-build git \
        python3 python3-pip \
        tar xz curl ca-certificates \
        ncurses-devel which \
    && dnf clean all

RUN pip3 install --no-cache-dir "conan>=2.4"
RUN conan remote add --url https://center2.conan.io conancenter

WORKDIR /src

# Export custom recipes to local Conan cache
COPY recipes/ /tmp/recipes/
RUN conan export /tmp/recipes/arrow/
RUN conan export /tmp/recipes/quantlib/

COPY profiles/ /root/.conan2/profiles/
COPY conanfile.py .
COPY src/ src/
COPY tests/ tests/

# Resolve and build all dependencies from source
RUN conan install . \
    --build=missing \
    -pr:b default \
    -pr:h al2023 \
    -s:h build_type=${BUILD_TYPE} \
    -s:h compiler.cppstd=26

# Build the library and handler
RUN conan build .

# Install to a known prefix (fixes the missing cmake.install bug)
RUN cmake --install build/${BUILD_TYPE} --prefix /src/install

# Create a stripped copy of the handler for production
RUN cp /src/install/bin/lambda_handler /src/install/bin/lambda_handler.stripped \
    && strip --strip-all /src/install/bin/lambda_handler.stripped

# Smoke tests
RUN test -f /src/install/lib/liblambda_cpp26.a && echo "OK: static library"
RUN test -f /src/install/bin/lambda_handler && echo "OK: handler binary"

# ============================================================
# Stage 2: Development image (full tools + debug support)
# ============================================================
FROM public.ecr.aws/lambda/provided:al2023 AS dev

ARG BUILD_TYPE=Release
ARG LAMBDA_DIR=/opt/lambda

# Debug tools for local development
RUN dnf install -y gdb gdb-gdbserver strace valgrind && dnf clean all

COPY --from=builder /src/install/bin/lambda_handler ${LAMBDA_DIR}/bin/
COPY --from=builder /src/install/lib/ ${LAMBDA_DIR}/lib/
COPY --from=builder /src/install/include/ ${LAMBDA_DIR}/include/
COPY src/bootstrap /lambda-entrypoint
RUN chmod +x /lambda-entrypoint

ENV LAMBDA_TASK_ROOT=${LAMBDA_DIR}
ENV LAMBDA_RUNTIME_DIR=/var/runtime
EXPOSE 8080

CMD ["/lambda-entrypoint"]

# ============================================================
# Stage 3: Production image (stripped, minimal)
# ============================================================
FROM public.ecr.aws/lambda/provided:al2023 AS prod

ARG BUILD_TYPE=Release
ARG LAMBDA_DIR=/opt/lambda

# Only the stripped handler binary — no debug symbols, no lib, no headers
COPY --from=builder /src/install/bin/lambda_handler.stripped ${LAMBDA_DIR}/bin/lambda_handler
COPY src/bootstrap /lambda-entrypoint
RUN chmod +x /lambda-entrypoint

ENV LAMBDA_TASK_ROOT=${LAMBDA_DIR}
ENV LAMBDA_RUNTIME_DIR=/var/runtime
EXPOSE 8080

CMD ["/lambda-entrypoint"]
