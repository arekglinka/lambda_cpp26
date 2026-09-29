ARG BASE_TAG=latest
FROM ghcr.io/${REGISTRY_OWNER:-arekglinka}/lambda_cpp26-base:${BASE_TAG} AS builder

ARG BUILD_TYPE=Release

COPY src/ src/
COPY tests/ tests/

RUN conan build . \
        -pr:h /tmp/conan-profiles/al2023 \
        -pr:b /tmp/conan-profiles/al2023

RUN find build -name "sum_columns*.so" -exec cp {} /tmp/sum_columns.so \; && \
    strip --strip-unneeded /tmp/sum_columns.so || true

# ============================================================
# Stage 2: Test
# ============================================================
FROM public.ecr.aws/lambda/python:3.13 AS test

RUN pip3.13 install --no-cache-dir "pyarrow>=25"

COPY --from=builder /tmp/sum_columns.so ${LAMBDA_TASK_ROOT}/
COPY --from=builder /opt/gcc16/lib64/libstdc++.so.6 /lib64/
COPY --from=builder /opt/gcc16/lib64/libgcc_s.so.1 /lib64/
COPY handler.py ${LAMBDA_TASK_ROOT}/
COPY data/ ${LAMBDA_TASK_ROOT}/data/
COPY tests/cleanroom_test.py /tmp/cleanroom_test.py

RUN python3.13 -c "import sum_columns; print('import OK')"
RUN python3.13 /tmp/cleanroom_test.py
RUN ldd ${LAMBDA_TASK_ROOT}/sum_columns.so

CMD ["handler.lambda_handler"]
