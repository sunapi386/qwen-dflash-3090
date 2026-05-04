# qwen-dflash-3090

Run [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) at ~70 tok/s on a single NVIDIA GPU using [Luce DFlash](https://github.com/Luce-Org/lucebox-hub) speculative decoding. That's ~2x faster than autoregressive.

Serves an OpenAI-compatible API. Drop-in for Open WebUI, Cline, LM Studio, etc.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/sunapi386/qwen-dflash-3090/main/install.sh | bash
```

The installer checks prerequisites, downloads models (~19 GB), builds the Docker image, and drops you into a control panel to start/stop/test the server.

## Requirements

- Linux with an NVIDIA GPU (RTX 3090 / 4090 / 5090 / A100)
- Docker with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- ~20 GB disk for models
- HuggingFace account (draft model is [gated](https://huggingface.co/z-lab/Qwen3.6-27B-DFlash) — accept terms first)

macOS is not supported (CUDA only, no Metal/ROCm backend).

## Usage

After install, re-run the script to get the control panel:

```bash
~/qwen-dflash-3090/install.sh
```

Or manage directly with Docker Compose:

```bash
cd ~/qwen-dflash-3090
docker compose up -d    # start
docker compose down     # stop
docker compose logs -f  # watch logs
```

### OpenAI API

```bash
export OPENAI_API_BASE=http://localhost:8090/v1
export OPENAI_API_KEY=sk-any

curl http://localhost:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"luce-dflash","messages":[{"role":"user","content":"hi"}],"max_tokens":64}'
```

## Configuration

Environment variables (set before running `install.sh`):

| Variable | Default | Description |
|---|---|---|
| `QWEN_DFLASH_DIR` | `~/qwen-dflash-3090` | Install directory |
| `QWEN_DFLASH_PORT` | `8090` | API port |
| `HF_TOKEN` | — | HuggingFace token (prompted if not set) |

Edit `docker-compose.yml` to tune:

- **max-ctx**: Context window. 2048 fits on 24 GB with desktop apps running. Bump to 4096+ if you free VRAM.
- **CUDA_ARCH**: Build arg for your GPU (86=3090, 89=4090, 120=5090). Auto-detected by installer.

## Gotchas

- **BuildKit GPG failure**: The nvidia/cuda base image has GPG issues with BuildKit. The installer uses `DOCKER_BUILDKIT=0` automatically.
- **OOM at large context**: Model (15 GB) + draft (3.3 GB) + desktop apps leaves little headroom on 24 GB. Default is conservative (2048 ctx).
- **TQ3_0 KV cache forced**: Required on 24 GB cards. The server only auto-enables it above 6144 ctx, but F16 KV doesn't fit regardless.
- **HF gated token permissions**: Fine-grained tokens need "Access public gated repos" enabled explicitly.
