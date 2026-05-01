FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS builder

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG CUDA_ARCH=86
ARG LUCEBOX_REF=main

RUN git clone --recurse-submodules https://github.com/Luce-Org/lucebox-hub.git src

ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs
RUN cd src/dflash && \
    cmake -B build -S . \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH} && \
    cmake --build build --target test_dflash -j"$(nproc)"

FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip ca-certificates libgomp1 && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages \
    fastapi uvicorn transformers huggingface_hub[cli] gguf jinja2

WORKDIR /app
COPY --from=builder /app/src/dflash/build/ dflash/build/
COPY --from=builder /app/src/dflash/scripts/ dflash/scripts/
COPY --from=builder /app/src/dflash/include/ dflash/include/

RUN mkdir -p models/draft

EXPOSE 8080

ENTRYPOINT ["python3", "dflash/scripts/server.py"]
