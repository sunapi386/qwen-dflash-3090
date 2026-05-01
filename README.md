# qwen-dflash-3090

Docker setup for running [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) with [Luce DFlash](https://github.com/Luce-Org/lucebox-hub) speculative decoding on an RTX 3090.

~70 tok/s generation (vs ~35 tok/s autoregressive) — a ~2x speedup from DDTree speculative decoding with a matched draft model.

Serves an OpenAI-compatible API on port 8090.

## Requirements

- NVIDIA RTX 3090 (24 GB)
- Docker with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- ~20 GB disk for models
- HuggingFace account (draft model is gated)

## Setup

```bash
# 1. Download models (~19 GB total)
#    First: accept terms at https://huggingface.co/z-lab/Qwen3.6-27B-DFlash
export HF_TOKEN=hf_your_token
./download-models.sh

# 2. Build (first time takes ~10 min for CUDA compilation)
#    IMPORTANT: BuildKit has GPG issues with the CUDA base image.
#    Use legacy builder:
DOCKER_BUILDKIT=0 docker build -t qwen-dflash-3090 .

# 3. Run
docker compose up -d

# 4. Test
curl http://localhost:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"luce-dflash","messages":[{"role":"user","content":"hi"}],"max_tokens":64}'
```

## Use as OpenAI drop-in

```bash
export OPENAI_API_BASE=http://localhost:8090/v1
export OPENAI_API_KEY=sk-any
```

Works with Open WebUI, LM Studio, Cline, etc.

## Gotchas we hit

- **BuildKit GPG failure**: The `nvidia/cuda` Docker base image has GPG signature issues with BuildKit. Use `DOCKER_BUILDKIT=0` for the build.
- **CUDA stubs**: The devel image needs `LIBRARY_PATH=/usr/local/cuda/lib64/stubs` to link `libcuda.so` at build time (no real driver in the build container).
- **libgomp1**: The runtime image doesn't include OpenMP. The binary needs it — installed explicitly.
- **jinja2**: Not pulled in by `transformers` by default, but required for `apply_chat_template`.
- **OOM at default context**: Model (15 GB) + draft (3.3 GB) + desktop apps (~1 GB) leaves little room. Default `max_ctx=16384` OOMs. Use 2048-4096 depending on free VRAM.
- **TQ3_0 KV cache**: Must be forced via `DFLASH27B_KV_TQ3=1` when `max_ctx <= 6144` (server only auto-enables it above that threshold, but F16 KV doesn't fit on 24 GB regardless).
- **HF fine-grained tokens**: Must enable "Access public gated repos" permission — not on by default.

## Tuning

Edit `docker-compose.yml`:

- **max-ctx**: Increase if you free VRAM (close browser, Slack, etc). 4096+ works with ~1 GB freed.
- **CUDA_ARCH**: Change build arg for other GPUs (89 for 4090, 120 for 5090).
- **Port**: Change `8090:8080` mapping as needed.
