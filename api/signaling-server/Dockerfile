FROM golang:1.26.5-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/signaling-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/signaling-server /signaling-server
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/signaling-server"]
