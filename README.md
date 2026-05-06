# qwen-dflash-3090

Run [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) at **~70-108 tok/s** on a single NVIDIA GPU using [Luce DFlash](https://github.com/Luce-Org/lucebox-hub) speculative decoding. That's ~2x faster than autoregressive.

Serves an OpenAI-compatible API. Drop-in for Open WebUI, Cline, LM Studio, etc.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/sunapi386/qwen-dflash-3090/main/install.sh | bash
```

The installer:
1. Checks prerequisites (GPU, Docker, NVIDIA Container Toolkit)
2. Downloads models (~19 GB)
3. Builds the Docker image (~10 min)
4. Optionally installs the `llm` CLI with a `qwen` shell alias
5. Drops you into a control panel to start/stop/test/chat

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

Or manage directly:

```bash
cd ~/qwen-dflash-3090
docker compose up -d    # start
docker compose down     # stop
docker compose logs -f  # watch logs
```

### CLI Chat

The installer sets up a `qwen` alias using [llm](https://github.com/simonw/llm) (12k stars):

```bash
qwen 'Explain quicksort in 3 sentences'
echo "Summarize this" | qwen
qwen chat   # interactive REPL
```

### OpenAI-Compatible API

```bash
export OPENAI_API_BASE=http://localhost:8090/v1
export OPENAI_API_KEY=sk-any

curl http://localhost:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"luce-dflash","messages":[{"role":"user","content":"hi"}],"max_tokens":64}'
```

## How It Works

[Speculative decoding](https://arxiv.org/abs/2302.01318) uses two models:
- **Target** (big): Qwen3.6-27B Q4_K_M — the model that produces final output
- **Draft** (small): A ~3.5 GB model trained to predict what the target would say

The draft proposes a batch of tokens cheaply, then the target verifies them all in one forward pass. Instead of 1 token per pass (~35 tok/s), you get ~5-8 tokens accepted per step (~70-108 tok/s).

## Configuration

Environment variables (set before running `install.sh`):

| Variable | Default | Description |
|---|---|---|
| `QWEN_DFLASH_DIR` | `~/qwen-dflash-3090` | Install directory |
| `QWEN_DFLASH_PORT` | `8090` | API port |
| `HF_TOKEN` | — | HuggingFace token (prompted if not set) |

Edit `docker-compose.yml` to tune:

- **max-ctx**: Context window. Default 8192 fits on 24 GB with TQ3_0 KV. Short prompts (<2k tokens) are reliable; longer prompts may OOM if desktop apps consume VRAM.
- **CUDA_ARCH**: Build arg for your GPU (86=3090, 89=4090, 120=5090). Auto-detected by installer.

## Performance

Measured on RTX 3090, Qwen3.6-27B Q4_K_M, DFlash speculative decoding:

| Metric | Value |
|---|---|
| Generation speed | 70-108 tok/s |
| Acceptance length | ~5-8 tokens/step |
| Speedup vs autoregressive | ~2x |
| VRAM usage (model + draft) | ~19 GB |
| Max context (24 GB card) | 8192 tokens |

## Gotchas

- **BuildKit GPG failure**: The nvidia/cuda base image has GPG issues with BuildKit. The installer uses `DOCKER_BUILDKIT=0` automatically.
- **OOM on long prompts**: Model (15 GB) + draft (3.3 GB) + desktop apps leaves limited headroom. Prompts >4k tokens may OOM the compute graph. Close Slack/Zoom/Chrome to free VRAM.
- **TQ3_0 KV cache forced**: Required on 24 GB cards. The server only auto-enables it above 6144 ctx, but F16 KV doesn't fit regardless.
- **HF gated token permissions**: Fine-grained tokens need "Access public gated repos" enabled in token settings.
- **Qwen3.6 thinking mode**: The model outputs its reasoning by default. Responses include a thinking/planning section before the actual answer.
