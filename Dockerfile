# Global ARGs (must be declared before any FROM to be used in FROM instructions)
ARG BASE_IMAGE="alpine:latest"
ARG RUNTIME_IMAGE="alpine:latest"

# --- STAGE 1: BUILDER ---
FROM ${BASE_IMAGE} AS builder

ARG ARCH_FLAGS
ARG USE_CUDA="OFF"
ARG USE_BLAS="ON"
ARG USE_OPENSSL="ON"
ARG CUDA_ARCH="native"
ARG LLAMA_SHA="unknown"
ARG LLAMA_BUILD_NUMBER="0"

# Install build dependencies (Alpine vs Ubuntu)
RUN if [ -f /etc/alpine-release ]; then \
        pkgs="build-base cmake linux-headers"; \
        if [ "${USE_OPENSSL}" = "ON" ]; then pkgs="$pkgs curl-dev"; fi; \
        if [ "${USE_BLAS}" = "ON" ]; then pkgs="$pkgs openblas-dev"; fi; \
        apk add --no-cache $pkgs; \
    else \
        pkgs="build-essential cmake pkg-config"; \
        if [ "${USE_OPENSSL}" = "ON" ]; then pkgs="$pkgs libcurl4-openssl-dev"; fi; \
        if [ "${USE_BLAS}" = "ON" ]; then pkgs="$pkgs libopenblas-dev"; fi; \
        apt-get update && \
        apt-get install -y $pkgs && \
        rm -rf /var/lib/apt/lists/*; \
    fi

COPY llama-src/ /src/
WORKDIR /src

RUN cmake -B build \
    -DGGML_NATIVE=OFF \
    -DCMAKE_C_FLAGS="${ARCH_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${ARCH_FLAGS}" \
    -DGGML_CUDA=${USE_CUDA} \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH} \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_BLAS=${USE_BLAS} \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_OPENSSL=${USE_OPENSSL} \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_COMMIT=${LLAMA_SHA} \
    -DLLAMA_BUILD_NUMBER=${LLAMA_BUILD_NUMBER:-0} \
    -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release -j $(nproc) || \
    (echo "=== Parallel build failed, retrying single-threaded for error details ===" && \
     cmake --build build --config Release -j 1 2>&1 | tail -80 && exit 1)

# --- STAGE 2: RUNTIME ---
FROM ${RUNTIME_IMAGE} AS runtime

ARG ARCH_FLAGS
ARG VARIANT="unknown"
ARG LLAMA_SHA="unknown"
ARG USE_BLAS="ON"
ARG USE_OPENSSL="ON"

# Install runtime dependencies (Alpine vs Ubuntu)
RUN if [ -f /etc/alpine-release ]; then \
        pkgs="libstdc++ libgomp"; \
        if [ "${USE_OPENSSL}" = "ON" ]; then pkgs="$pkgs libcurl"; fi; \
        if [ "${USE_BLAS}" = "ON" ]; then pkgs="$pkgs openblas"; fi; \
        apk add --no-cache $pkgs; \
    else \
        pkgs="libgomp1"; \
        if [ "${USE_OPENSSL}" = "ON" ]; then pkgs="$pkgs libcurl4"; fi; \
        if [ "${USE_BLAS}" = "ON" ]; then pkgs="$pkgs libopenblas0"; fi; \
        apt-get update && \
        apt-get install -y $pkgs && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user (UID/GID 1000)
# On some base images (e.g. nvidia/cuda), UID 1000 already exists as 'ubuntu'
RUN if [ -f /etc/alpine-release ]; then \
        addgroup -g 1000 user && adduser -u 1000 -G user -D user; \
    else \
        id -u 1000 >/dev/null 2>&1 || (groupadd -g 1000 user && useradd -u 1000 -g 1000 -m -d /home/user user); \
        mkdir -p /home/user && chown 1000:1000 /home/user; \
    fi

# Copy shared libraries to system path (default search path for musl and glibc)
COPY --from=builder /src/build/bin/*.so* /usr/lib/

# Copy binaries
COPY --from=builder /src/build/bin/llama-server /usr/local/bin/
COPY --from=builder /src/build/bin/llama-cli /usr/local/bin/

# Default environment
ENV LLAMA_ARG_HOST=0.0.0.0 \
    LLAMA_ARG_PORT=11434

# Bake build metadata
RUN echo "VARIANT=${VARIANT}" > /etc/llama-release && \
    echo "LLAMA_SHA=${LLAMA_SHA}" >> /etc/llama-release && \
    echo "ARCH_FLAGS=${ARCH_FLAGS}" >> /etc/llama-release && \
    echo "BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> /etc/llama-release

# Prepare Hugging Face cache directory
RUN mkdir -p /home/user/.cache/huggingface/hub && \
    chown -R 1000:1000 /home/user/.cache

USER 1000:1000
WORKDIR /home/user
EXPOSE 11434
ENTRYPOINT ["llama-server"]
