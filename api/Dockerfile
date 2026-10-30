FROM golang:1.26.5-alpine AS server-build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
COPY certs ./certs
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/viewvee-web .
# Writable home for the entitlement store; mount a persistent volume here.
RUN mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=server-build /out/viewvee-web /app/viewvee-web
COPY web /app/web
COPY --from=server-build --chown=nonroot:nonroot /out/data /data
VOLUME /data
ENV HTTP_ADDR=:8080 STATIC_DIR=/app/web
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/viewvee-web"]
