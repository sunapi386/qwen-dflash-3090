#!/usr/bin/env bash
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/sunapi386/qwen-dflash-3090.git"
INSTALL_DIR="${QWEN_DFLASH_DIR:-$HOME/qwen-dflash-3090}"
IMAGE_NAME="qwen-dflash-3090"
CONTAINER_NAME="qwen-dflash"
PORT="${QWEN_DFLASH_PORT:-8090}"
TARGET_GGUF="Qwen3.6-27B-Q4_K_M.gguf"
DRAFT_REPO="z-lab/Qwen3.6-27B-DFlash"
TARGET_REPO="unsloth/Qwen3.6-27B-GGUF"

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
    BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ── Platform Detection ───────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

detect_gpu() {
    GPU_NAME=""
    GPU_VRAM=""
    CUDA_ARCH=""

    if [ "$OS" = "Darwin" ]; then
        if system_profiler SPDisplaysDataType 2>/dev/null | grep -qi "nvidia"; then
            warn "NVIDIA GPU detected on macOS but CUDA Docker support is limited."
            warn "This setup requires the NVIDIA Container Toolkit (Linux only)."
            return 1
        fi
        err "No NVIDIA GPU found. Luce DFlash requires CUDA (NVIDIA GPU only)."
        err "Apple Silicon / AMD GPUs are not supported (no Metal/ROCm backend)."
        return 1
    fi

    if ! command -v nvidia-smi &>/dev/null; then
        err "nvidia-smi not found. Install NVIDIA drivers first."
        return 1
    fi

    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)

    case "$GPU_NAME" in
        *3090*|*3080*) CUDA_ARCH=86 ;;
        *4090*|*4080*) CUDA_ARCH=89 ;;
        *5090*|*5080*) CUDA_ARCH=120 ;;
        *A100*|*A6000*) CUDA_ARCH=80 ;;
        *) CUDA_ARCH=86; warn "Unknown GPU '$GPU_NAME', defaulting to CUDA arch 86" ;;
    esac

    ok "GPU: $GPU_NAME (${GPU_VRAM} MiB VRAM, sm_${CUDA_ARCH})"
    return 0
}

# ── Prerequisite Checks ─────────────────────────────────────────────────────
check_docker() {
    if ! command -v docker &>/dev/null; then
        err "Docker not found."
        if [ "$OS" = "Darwin" ]; then
            err "Install: https://docs.docker.com/desktop/install/mac-install/"
        else
            err "Install: https://docs.docker.com/engine/install/ubuntu/"
        fi
        return 1
    fi

    if ! docker info &>/dev/null; then
        err "Docker daemon not running, or current user lacks permission."
        err "Try: sudo usermod -aG docker \$USER && newgrp docker"
        return 1
    fi

    ok "Docker $(docker --version | grep -oP '[\d.]+'| head -1)"
    return 0
}

check_nvidia_docker() {
    if [ "$OS" = "Darwin" ]; then return 1; fi

    if docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi &>/dev/null; then
        ok "NVIDIA Container Toolkit working"
        return 0
    fi

    err "NVIDIA Container Toolkit not working."
    err "Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    return 1
}

check_hf_cli() {
    if command -v hf &>/dev/null; then
        ok "hf CLI found"
        return 0
    fi
    if command -v huggingface-cli &>/dev/null; then
        ok "huggingface-cli found"
        return 0
    fi
    return 1
}

install_hf_cli() {
    info "Installing huggingface-hub CLI..."
    if command -v uv &>/dev/null; then
        uv tool install huggingface_hub 2>&1 | tail -1
    elif command -v pipx &>/dev/null; then
        pipx install huggingface_hub 2>&1 | tail -1
    elif command -v pip3 &>/dev/null; then
        pip3 install --user huggingface_hub 2>&1 | tail -1
    elif command -v brew &>/dev/null; then
        brew install huggingface-cli 2>&1 | tail -1
    else
        die "No package manager found (uv, pipx, pip3, brew). Install one first."
    fi
    ok "hf CLI installed"
}

hf_download() {
    if command -v hf &>/dev/null; then
        hf download "$@"
    else
        huggingface-cli download "$@"
    fi
}

# ── Setup Steps ──────────────────────────────────────────────────────────────
setup_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        ok "Repo already cloned at $INSTALL_DIR"
        info "Pulling latest..."
        git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
        return 0
    fi

    if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        warn "$INSTALL_DIR exists but is not a git repo. Using as-is."
        return 0
    fi

    info "Cloning repo to $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    ok "Repo cloned"
}

setup_models() {
    local models_dir="$INSTALL_DIR/models"
    mkdir -p "$models_dir/draft"

    local need_target=false need_draft=false

    if [ -f "$models_dir/$TARGET_GGUF" ]; then
        local size
        size=$(stat -c%s "$models_dir/$TARGET_GGUF" 2>/dev/null || stat -f%z "$models_dir/$TARGET_GGUF" 2>/dev/null || echo 0)
        if [ "$size" -gt 1000000000 ]; then
            ok "Target model already downloaded ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes"))"
        else
            need_target=true
        fi
    else
        need_target=true
    fi

    if [ -f "$models_dir/draft/model.safetensors" ]; then
        local size
        size=$(stat -c%s "$models_dir/draft/model.safetensors" 2>/dev/null || stat -f%z "$models_dir/draft/model.safetensors" 2>/dev/null || echo 0)
        if [ "$size" -gt 1000000000 ]; then
            ok "Draft model already downloaded ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes"))"
        else
            need_draft=true
        fi
    else
        need_draft=true
    fi

    if ! $need_target && ! $need_draft; then
        return 0
    fi

    if $need_draft && [ -z "${HF_TOKEN:-}" ]; then
        warn "The draft model ($DRAFT_REPO) is gated."
        echo ""
        echo "  1. Accept terms at https://huggingface.co/z-lab/Qwen3.6-27B-DFlash"
        echo "  2. Create a token at https://huggingface.co/settings/tokens"
        echo "     (enable 'Access public gated repos' if using a fine-grained token)"
        echo ""
        printf "  Enter HF token (or export HF_TOKEN first): "
        read -r HF_TOKEN
        export HF_TOKEN
        echo ""
    fi

    if $need_target; then
        info "Downloading target model (~16 GB)..."
        hf_download "$TARGET_REPO" "$TARGET_GGUF" --local-dir "$models_dir/"
        ok "Target model downloaded"
    fi

    if $need_draft; then
        info "Downloading draft model (~3.3 GB)..."
        HF_TOKEN="${HF_TOKEN:-}" hf_download "$DRAFT_REPO" --local-dir "$models_dir/draft/"
        ok "Draft model downloaded"
    fi
}

setup_image() {
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        ok "Docker image '$IMAGE_NAME' already built"
        printf "  Rebuild? [y/N] "
        read -r rebuild
        if [[ ! "$rebuild" =~ ^[Yy] ]]; then
            return 0
        fi
    fi

    info "Building Docker image (this takes ~10 min for CUDA compilation)..."

    local build_args=""
    if [ -n "${CUDA_ARCH:-}" ]; then
        build_args="--build-arg CUDA_ARCH=$CUDA_ARCH"
    fi

    # BuildKit has GPG signature issues with the nvidia/cuda base image
    DOCKER_BUILDKIT=0 docker build -t "$IMAGE_NAME" $build_args "$INSTALL_DIR"
    ok "Docker image built"
}

# ── Runtime Commands ─────────────────────────────────────────────────────────
do_start() {
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        warn "Already running"
        do_status
        return 0
    fi

    info "Starting on port $PORT..."
    cd "$INSTALL_DIR"

    # Update port in compose if needed
    if [ "$PORT" != "8090" ]; then
        sed -i.bak "s/\"[0-9]*:8080\"/\"${PORT}:8080\"/" docker-compose.yml
    fi

    # Use pre-built image name
    sed -i.bak "s|build:.*|image: ${IMAGE_NAME}|; /context:/d; /args:/d; /CUDA_ARCH:/d; /# RTX/d" docker-compose.yml 2>/dev/null || true

    docker compose up -d
    echo ""

    info "Waiting for model to load..."
    local tries=0
    while [ $tries -lt 30 ]; do
        if docker compose logs 2>&1 | grep -q "\[daemon\] ready"; then
            echo ""
            ok "Server ready at http://localhost:$PORT"
            echo ""
            echo "  OpenAI-compatible API:"
            echo "    OPENAI_API_BASE=http://localhost:$PORT/v1"
            echo "    OPENAI_API_KEY=sk-any"
            echo ""
            return 0
        fi
        if docker compose logs 2>&1 | grep -q "out of memory"; then
            echo ""
            err "GPU out of memory. Try closing other apps to free VRAM, or reduce --max-ctx."
            return 1
        fi
        printf "."
        sleep 2
        tries=$((tries + 1))
    done

    echo ""
    warn "Timed out waiting for model load. Check: docker compose logs"
}

do_stop() {
    if ! docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        warn "Not running"
        return 0
    fi
    cd "$INSTALL_DIR"
    docker compose down
    ok "Stopped"
}

do_test() {
    if ! docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        err "Server not running. Start it first."
        return 1
    fi

    info "Sending test request..."
    local response
    response=$(curl -s --max-time 30 "http://localhost:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"model":"luce-dflash","messages":[{"role":"user","content":"Say hello in exactly 5 words."}],"max_tokens":64}')

    local content
    content=$(echo "$response" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['choices'][0]['message']['content'])" 2>/dev/null || echo "")

    if [ -n "$content" ]; then
        ok "Response received:"
        echo ""
        echo "  $content"
        echo ""

        # Show perf from logs
        local perf
        perf=$(cd "$INSTALL_DIR" && docker compose logs --tail 5 2>&1 | grep "tok/s" | tail -1 || true)
        if [ -n "$perf" ]; then
            info "Performance: $(echo "$perf" | grep -oP '[\d.]+ tok/s')"
        fi
    else
        err "Empty or invalid response."
        echo "  Raw: $response"
        echo ""
        echo "  Check logs: cd $INSTALL_DIR && docker compose logs --tail 20"
    fi
}

do_status() {
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        ok "Running on port $PORT"
        local vram
        vram=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)
        if [ -n "$vram" ]; then
            info "GPU VRAM: $vram"
        fi
    else
        warn "Not running"
    fi
}

do_logs() {
    cd "$INSTALL_DIR"
    docker compose logs --tail 40
}

# ── Menu ─────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    printf "${BOLD}  Qwen3.6-27B DFlash — Control Panel${NC}\n"
    echo "  ──────────────────────────────────────"
    do_status
    echo ""
    echo "  1) Start server"
    echo "  2) Stop server"
    echo "  3) Test (send a prompt)"
    echo "  4) View logs"
    echo "  5) Rebuild Docker image"
    echo "  6) Re-download models"
    echo "  q) Quit"
    echo ""
    printf "  Choose: "
}

menu_loop() {
    while true; do
        show_menu
        read -r choice
        echo ""
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_test ;;
            4) do_logs ;;
            5) setup_image ;;
            6) HF_TOKEN="${HF_TOKEN:-}" setup_models ;;
            q|Q) echo "Bye."; exit 0 ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "${BOLD}  Qwen3.6-27B DFlash Installer${NC}\n"
    echo "  ═══════════════════════════════"
    echo "  ~70 tok/s speculative decoding on consumer NVIDIA GPUs"
    echo ""

    # Platform check
    info "Platform: $OS $ARCH"

    if [ "$OS" = "Darwin" ]; then
        die "macOS is not supported — Luce DFlash requires CUDA (NVIDIA GPU).
    Apple Silicon and AMD GPUs have no backend (no Metal/ROCm).
    Run this on a Linux machine with an NVIDIA GPU (RTX 3090+)."
    fi

    # Prerequisites
    local prereqs_ok=true

    detect_gpu || prereqs_ok=false
    check_docker || prereqs_ok=false

    if $prereqs_ok; then
        check_nvidia_docker || prereqs_ok=false
    fi

    if ! $prereqs_ok; then
        die "Fix the above issues and re-run this script."
    fi

    check_hf_cli || install_hf_cli

    echo ""

    # Setup
    setup_repo
    setup_models
    setup_image

    echo ""
    ok "Setup complete!"

    # Hand off to menu
    menu_loop
}

# Allow sourcing without running
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
