# syntax=docker/dockerfile:1
# Multi-arch static build. No runtime image: the binary is fully static.
#
#   docker build -t zs3 .
#   docker run -p 9000:9000 -v zs3-data:/data zs3
#
# Credentials via command args (do not bake secrets into the image):
#   docker run -p 9000:9000 -v zs3-data:/data zs3 --acl=admin:local-access:local-secret
ARG ZIG_VERSION=0.16.0

FROM alpine:3.21 AS build
ARG ZIG_VERSION
# TARGETARCH is set by BuildKit/buildx; fall back to uname for the legacy builder.
ARG TARGETARCH
RUN apk add --no-cache curl xz && \
    ARCH="${TARGETARCH:-$(uname -m)}" && \
    case "$ARCH" in \
      amd64|x86_64) ZIG_ARCH="x86_64" ;; \
      arm64|aarch64) ZIG_ARCH="aarch64" ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    echo "$ZIG_ARCH" > /tmp/zig_arch && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig && \
    rm /tmp/zig.tar.xz
WORKDIR /src
COPY main.zig acl.zig build.zig console.html ./
RUN /opt/zig/zig build -Dtarget=$(cat /tmp/zig_arch)-linux-musl -Dcpu=baseline -Doptimize=ReleaseSmall && \
    ls -l zig-out/bin/zs3

FROM scratch
COPY --from=build /src/zig-out/bin/zs3 /zs3
VOLUME /data
EXPOSE 9000
ENTRYPOINT ["/zs3", "--data-dir=/data"]
