# Build context: the peak/ directory (the server depends on ../Packages/PeakKit).
#   docker build -f Server/Dockerfile -t peak-server .

FROM swift:6.2-noble AS build
WORKDIR /build
COPY Packages/PeakKit Packages/PeakKit
COPY Server/Package.swift Server/Package.resolved* Server/
RUN cd Server && swift package resolve
COPY Server Server
RUN cd Server && swift build -c release --product peak-server --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/peak-server" /build/peak-server

FROM ubuntu:noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libcurl4 libxml2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app peak
WORKDIR /app
COPY --from=build /build/peak-server /app/peak-server
USER peak
EXPOSE 8080
ENV PORT=8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["/bin/sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q ok <&3"]
ENTRYPOINT ["/app/peak-server"]
