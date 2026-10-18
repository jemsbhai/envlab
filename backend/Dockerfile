# NEX's native runtime executes the Python worker in the runtime container.
# Pin the source revision: its current CLI differs from older NEX releases.
FROM --platform=$BUILDPLATFORM golang:1.26.1-bookworm AS nex-build
ARG NEX_REF=12609378dbb5402ef94a1b283704e0441fea4754
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0 GOMAXPROCS=1 GOMEMLIMIT=384MiB
ADD https://codeload.github.com/synadia-io/nex/tar.gz/${NEX_REF} /tmp/nex.tar.gz
RUN mkdir /src && tar -xzf /tmp/nex.tar.gz --strip-components=1 -C /src \
    && cd /src/cmd/nex && GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -p=1 -trimpath -ldflags="-s -w" -o /out/nex .

FROM --platform=$BUILDPLATFORM python:3.13-slim-bookworm AS python-deps
ARG TARGETARCH
COPY requirements.txt /tmp/requirements.txt
# Assemble target wheels with native Python; no QEMU package install is needed.
RUN case "$TARGETARCH" in \
      arm64) wheel_platform=manylinux2014_aarch64 ;; \
      amd64) wheel_platform=manylinux2014_x86_64 ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && pip install --no-cache-dir --no-compile --only-binary=:all: \
       --platform "$wheel_platform" --python-version 3.13 --implementation cp --abi cp313 \
       --target /deps -r /tmp/requirements.txt

FROM python:3.13-slim-bookworm
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOME=/data
WORKDIR /app
COPY --from=nex-build /out/nex /usr/local/bin/nex
COPY --from=python-deps /deps/ /usr/local/lib/python3.13/site-packages/
COPY water_monitor /usr/local/lib/python3.13/site-packages/water_monitor
COPY deploy ./deploy
COPY docs/api-v1.* ./docs/
COPY docs/architecture ./docs/architecture/
COPY --chown=10001:10001 deploy/data/ /data/
USER 10001:10001
CMD ["python", "-m", "water_monitor.nex_boot"]
