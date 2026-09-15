ARG BUILDER_IMAGE
ARG RUNTIME_IMAGE
FROM ${BUILDER_IMAGE} AS builder
WORKDIR /app
COPY source/go.mod source/go.sum ./
RUN go mod download
COPY source/ ./
# These gates exercise the patch. Known baseline failures in the full upstream
# suite are recorded in docs/recovery-deadlines.md, not silently skipped there.
RUN go test ./sdk/cliproxy/auth ./sdk/api/handlers ./sdk/api/handlers/openai
RUN go test -run 'TestCodexStreamCancellation|TestCodexExecutorExecuteStream' ./internal/runtime/executor
RUN go test -count=3 -run '^TestGetPluginSyncCancellationInterruptsRead$' ./internal/home
ARG VERSION
ARG COMMIT
ARG BUILD_DATE
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -buildvcs=false -ldflags="-s -w -X main.Version=${VERSION} -X main.Commit=${COMMIT} -X main.BuildDate=${BUILD_DATE}" -o /CLIProxyAPI ./cmd/server

# Preserve the deployed runtime libraries, shell, config and entrypoint.
# No floating apt repositories or live state enter the image build.
FROM ${RUNTIME_IMAGE}
ARG VERSION
ARG COMMIT
ARG UPSTREAM_COMMIT
ARG PATCH_SHA256
LABEL org.opencontainers.image.source="https://github.com/prls-co/CLIProxyAPI-setup" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.licenses="MIT" \
      co.prls.cpa.upstream-commit="${UPSTREAM_COMMIT}" \
      co.prls.cpa.patch-sha256="${PATCH_SHA256}"
COPY --from=builder /CLIProxyAPI /CLIProxyAPI/CLIProxyAPI
COPY source/LICENSE /CLIProxyAPI/LICENSE
