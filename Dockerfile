FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      dante-server \
      iproute2 \
      jq \
      tini \
    && adduser -D -H -s /sbin/nologin proxy

COPY aethercloud-agent.sh /usr/local/bin/aethercloud-agent
COPY healthcheck.sh /usr/local/bin/aethercloud-healthcheck
COPY sockd.conf /etc/sockd.conf.template

RUN chmod 0755 \
      /usr/local/bin/aethercloud-agent \
      /usr/local/bin/aethercloud-healthcheck

EXPOSE 1080/tcp 1080/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD ["/usr/local/bin/aethercloud-healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/aethercloud-agent"]
