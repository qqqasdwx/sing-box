# 构建阶段
FROM alpine:latest AS builder
ARG TARGETARCH
ARG TARGETVARIANT
ARG S6_OVERLAY_VERSION=3.2.3.2
ENV ARCH=$TARGETARCH

# 安装构建依赖
RUN set -ex &&\
  apk add --no-cache wget xz ca-certificates

# 下载并解压 s6-overlay
RUN set -ex &&\
  BUILD_ARCH="${ARCH:-$(uname -m)}${TARGETVARIANT:+/${TARGETVARIANT}}"; \
  case "$BUILD_ARCH" in \
    amd64|x86_64) S6_ARCH=x86_64 ;; \
    arm64|aarch64) S6_ARCH=aarch64 ;; \
    arm/v7|armv7|armv7l) S6_ARCH=armhf ;; \
    *) echo "Unsupported architecture: $BUILD_ARCH" >&2; exit 1 ;; \
  esac &&\
  for ASSET in noarch "$S6_ARCH"; do \
    FILE="s6-overlay-${ASSET}.tar.xz"; \
    URL="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/${FILE}"; \
    wget -qO "/tmp/${FILE}" "$URL"; \
    wget -qO "/tmp/${FILE}.sha256" "${URL}.sha256"; \
    (cd /tmp && sha256sum -c "${FILE}.sha256"); \
    tar -C / -Jxf "/tmp/${FILE}"; \
  done

# 运行阶段
FROM alpine:latest
ARG TARGETARCH
ENV ARCH=$TARGETARCH

# 设置工作目录
WORKDIR /sing-box

# 从构建阶段复制 s6-overlay 文件
COPY --from=builder / /

# 复制初始化脚本
COPY docker_init.sh /sing-box/init.sh

# 安装运行时依赖并生成证书
RUN set -ex &&\
  apk add --no-cache wget curl nginx bash openssl ca-certificates tar iproute2 iputils procps coreutils xxd &&\
  mkdir -p /sing-box/cert /sing-box/conf /sing-box/custom /sing-box/state /sing-box/subscribe /sing-box/logs &&\
  chmod +x /sing-box/init.sh &&\
  ln -s /sing-box/init.sh /usr/local/bin/sb &&\
  rm -rf /var/cache/apk/*

CMD [ "./init.sh" ]
