# syntax=docker/dockerfile:1.7

# ============================================================
# Build stage
# ============================================================
FROM --platform=$BUILDPLATFORM golang:1.26.6-bookworm AS builder

WORKDIR /src

ARG TARGETOS
ARG TARGETARCH

ENV GOTOOLCHAIN=local

COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH \
    go build \
      -mod=readonly \
      -trimpath \
      -ldflags="-s -w" \
      -o /out/ping-pong-app \
      .


# ============================================================
# Production runtime stage
# ============================================================
FROM gcr.io/distroless/static-debian13:nonroot

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="ping-pong-app" \
      org.opencontainers.image.description="Authenticated Ping-Pong HTTP service" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.created=$BUILD_DATE

WORKDIR /app

COPY --from=builder \
     --chown=65532:65532 \
     --chmod=0555 \
     /out/ping-pong-app \
     /app/ping-pong-app

ENV PORT=8080 \
    SECRET_FILE_PATH=/run/secrets/ping-pong-secret

EXPOSE 8080/tcp

# Distroless nonroot user
USER 65532:65532

STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/ping-pong-app"]

CMD ["--mode=server"]