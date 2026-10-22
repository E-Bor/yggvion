FROM golang:1.26.10-bookworm AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /yggvion ./cmd/yggvion
RUN mkdir -p /data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /yggvion /yggvion
COPY --from=build --chown=65532:65532 /data /data
ENV YGGVION_LISTEN=0.0.0.0:8080 YGGVION_DATA_DIR=/data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/yggvion"]
