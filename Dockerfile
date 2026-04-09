# --- STAGE 1: BUILDER ---
ARG BASE_IMAGE="alpine:latest"
FROM ${BASE_IMAGE} AS builder

ARG ARCH_FLAGS
ARG USE_CUDA="OFF"
ARG LLAMA_SHA="unknown"

# Install build dependencies (Alpine vs Ubuntu)
RUN if [ -f /etc/alpine-release ]; then \
        apk add --no-cache build-base cmake linux-headers openblas-dev curl-dev; \
    else \
        apt-get update && \
        apt-get install -y build-essential cmake libopenblas-dev libcurl4-openssl-dev && \
        rm -rf /var/lib/apt/lists/*; \
    fi

COPY llama-src/ /src/
WORKDIR /src

RUN cmake -B build \
    -DGGML_NATIVE=OFF \
    -DCMAKE_C_FLAGS="${ARCH_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${ARCH_FLAGS}" \
    -DGGML_CUDA=${USE_CUDA} \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release -j $(nproc)

# --- STAGE 2: RUNTIME ---
ARG RUNTIME_IMAGE="alpine:latest"
FROM ${RUNTIME_IMAGE} AS runtime

ARG ARCH_FLAGS
ARG VARIANT="unknown"
ARG LLAMA_SHA="unknown"

# Install runtime dependencies (Alpine vs Ubuntu)
RUN if [ -f /etc/alpine-release ]; then \
        apk add --no-cache libstdc++ openblas libcurl; \
    else \
        apt-get update && \
        apt-get install -y libopenblas0 libcurl4 libgomp1 && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user (UID/GID 1000)
RUN if [ -f /etc/alpine-release ]; then \
        addgroup -g 1000 user && adduser -u 1000 -G user -D user; \
    else \
        groupadd -g 1000 user && useradd -u 1000 -g user -m user; \
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
    chown -R user:user /home/user/.cache

USER user
WORKDIR /home/user
EXPOSE 11434
ENTRYPOINT ["llama-server"]
