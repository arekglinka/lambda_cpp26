ARG BASE_TAG=latest
ARG REGISTRY_OWNER=arekglinka
# Selects the per-architecture base image (lambda_cpp26-base:<tag>-<arch>).
# CI passes --build-arg TARGET_ARCH=arm64 alongside --platform linux/arm64
# for Graviton builds. Default amd64 preserves local `podman build` behaviour.
ARG TARGET_ARCH=amd64
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-base:${BASE_TAG}-${TARGET_ARCH} AS builder

ARG BUILD_TYPE=Release
ARG CONAN_PROFILE=al2023

COPY src/ src/
COPY tests/ tests/

RUN conan build . \
        -pr:h /tmp/conan-profiles/${CONAN_PROFILE} \
        -pr:b /tmp/conan-profiles/${CONAN_PROFILE}

RUN find build -name "sum_columns*.so" -exec cp {} /tmp/sum_columns.so \; && \
    strip --strip-unneeded /tmp/sum_columns.so || true

# ============================================================
# Stage 2: Test
# ============================================================
FROM public.ecr.aws/lambda/python:3.12 AS test

RUN pip3.12 install --no-cache-dir "pyarrow>=15.0"

COPY --from=builder /tmp/sum_columns.so ${LAMBDA_TASK_ROOT}/
COPY --from=builder /opt/gcc16/lib64/libstdc++.so.6 /lib64/
COPY --from=builder /opt/gcc16/lib64/libgcc_s.so.1 /lib64/
COPY handler.py ${LAMBDA_TASK_ROOT}/
COPY data/ ${LAMBDA_TASK_ROOT}/data/
COPY tests/cleanroom_test.py /tmp/cleanroom_test.py

RUN python3.12 -c "import sum_columns; print('import OK')"
RUN python3.12 /tmp/cleanroom_test.py
RUN ldd ${LAMBDA_TASK_ROOT}/sum_columns.so

CMD ["handler.lambda_handler"]
