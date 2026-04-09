# llama-server

Optimized `llama.cpp` server builds tailored for specific hardware instruction sets.

Think of it as a lightweight, hardware-specific alternative to Ollama, providing high-performance GGUF inference with an OpenAI-compatible API.

## Why this exists?

Standard LLM runners like Ollama are great but often bloated (3GB+) because they bundle every possible driver and instruction set. These images are **minimal (~60MB for CPU variants)** and compiled specifically for your chip's architecture, ensuring maximum tokens-per-second without wasted space.

## Artifacts

| Variant | Artifact | Target Hardware | CPU Optimizations | GPU | Base OS |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `opi5` | `ghcr.io/raonigabriel/llama-server:opi5-latest` | Orange Pi 5 / RK3588 | ARM NEON (SIMD) | No | Alpine |
| `morefine` | `ghcr.io/raonigabriel/llama-server:morefine-latest` | Celeron N5105 / Older x86 | SSE4.2 (`x86-64-v2`) | No | Alpine |
| `xeon-cuda` | `ghcr.io/raonigabriel/llama-server:xeon-cuda-latest` | Xeon v3 + RTX 30/40 Series | AVX2/FMA (`x86-64-v3`) | CUDA 13.2 | Ubuntu 24.04 |
| `windows-v3-cuda` | `llama-server.exe` | Modern PC + RTX GPU | AVX2/FMA | CUDA 13.2 | Standalone |

## Features

- **Hardware Specific**: Forces the compiler to target your specific chip instead of generic binaries
- **Lightweight**: Alpine-based CPU images are ~60MB
- **OpenAI Compatible**: Drop-in backend for any OpenAI-ready software (Cursor, LibreChat, etc.)
- **KV Cache Quantization**: Support for `q8_0`/`q4_0` cache types to fit large context in small memory
- **Hugging Face Integration**: Download models directly via `--hf-repo`/`--hf-file`
- **Non-Root**: Runs as user `user` (UID/GID 1000) for security

## Usage Examples

All examples use **Gemma 4-E4B** with a **16K context window** and quantized KV cache (`q8_0` keys / `q4_0` values) to save memory.

### CPU-Only (opi5 / morefine)

For ARM SBCs (Orange Pi 5) or low-power mini PCs (Celeron N5105).

```yaml
services:
  gemma:
    image: ghcr.io/raonigabriel/llama-server:opi5-latest # or :morefine-latest
    container_name: gemma
    ports:
      - "11434:11434"
    environment:
      - LLAMA_ARG_HF_REPO=unsloth/gemma-4-E4B-it-GGUF
      - LLAMA_ARG_HF_FILE=gemma-4-E4B-it-UD-IQ3_XXS.gguf
      - LLAMA_ARG_CTX_SIZE=16384
      - LLAMA_ARG_CACHE_TYPE_K=q8_0
      - LLAMA_ARG_CACHE_TYPE_V=q4_0
    volumes:
      - ./models:/home/user/.cache/huggingface/hub
    restart: unless-stopped
```

### CUDA GPU (xeon-cuda)

For NVIDIA GPU systems. Uses `-ngl -1` to offload all model layers to VRAM.

```yaml
services:
  gemma:
    image: ghcr.io/raonigabriel/llama-server:xeon-cuda-latest
    container_name: gemma
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    ports:
      - "11434:11434"
    environment:
      - LLAMA_ARG_HF_REPO=unsloth/gemma-4-E4B-it-GGUF
      - LLAMA_ARG_HF_FILE=gemma-4-E4B-it-UD-IQ3_XXS.gguf
      - LLAMA_ARG_N_GPU_LAYERS=-1
      - LLAMA_ARG_CTX_SIZE=16384
      - LLAMA_ARG_CACHE_TYPE_K=q8_0
      - LLAMA_ARG_CACHE_TYPE_V=q4_0
    volumes:
      - ./models:/home/user/.cache/huggingface/hub
    restart: unless-stopped
```

### Windows Standalone

Download `llama-server.exe` from the [GitHub Actions artifacts](https://github.com/raonigabriel/llama-server/actions). You also need `cublas64_13.dll` in the same directory (from the [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads)).

```powershell
.\llama-server.exe `
  --hf-repo unsloth/gemma-4-E4B-it-GGUF `
  --hf-file gemma-4-E4B-it-UD-IQ3_XXS.gguf `
  -ngl -1 `
  -c 16384 `
  -ctk q8_0 `
  -ctv q4_0 `
  --port 11434
```

## Diagnostics

Check the build metadata inside any running container:

```bash
docker exec <container> cat /etc/llama-release
```

Verify shared library linking:

```bash
docker exec <container> ldd /usr/local/bin/llama-server
```

## FAQ

**Q: Where are the Docker images served from?**
A: GitHub Container Registry (ghcr.io). Images from DockerHub are not created by me.

**Q: Are you one of the developers of llama.cpp or Ollama?**
A: No. I just took llama.cpp, compiled it with hardware-specific optimizations, and packaged it as an easy-to-use Docker image / standalone binary.

**Q: Why port 11434?**
A: It is the same port used by Ollama. While the internal APIs differ (llama.cpp is OpenAI-compatible, Ollama has its own extensions), using this port makes it a drop-in replacement for tools that default to `http://localhost:11434`.

**Q: Does this support the full OpenAI API?**
A: Yes. Use the `/v1/chat/completions` and `/v1/embeddings` endpoints. It is compatible with LangChain, Cursor, LibreChat, and most OpenAI-ready SDKs.

**Q: Will 16K context fit on a 6GB GPU?**
A: Yes. By using `-ctk q8_0 -ctv q4_0`, the KV cache for 16K context drops from ~2GB to ~0.8GB. Combined with an IQ3_XXS model (~2.1GB), total VRAM usage is ~3.4GB -- well within 6GB.

**Q: What quantized versions do you recommend?**
A: `Q4_K_M` offers a good balance between speed and accuracy. For constrained memory, `IQ3_XXS` is excellent.

**Q: Why use this over Ollama?**
A: Ollama images are 3GB+ because they pack every possible instruction set and handle dynamic CPU detection at runtime. These images are ~60MB (CPU) because each variant is purpose-built for your specific hardware. No bloat, no detection overhead.

**Q: Is there a way to protect the endpoints with auth?**
A: Yes, set the `LLAMA_API_KEY` environment variable:
```yaml
environment:
  - LLAMA_API_KEY=sk-my-secret-key
```

**Q: How do I check my CPU's supported instruction set?**
A: On Linux:
```bash
# Check for AVX2 (v3)
grep -q avx2 /proc/cpuinfo && echo "x86-64-v3" || echo "x86-64-v2"
```
