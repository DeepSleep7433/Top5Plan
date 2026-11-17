# syntax=docker/dockerfile:1.7
FROM golang:1.25-alpine AS build
WORKDIR /src
RUN apk add --no-cache ca-certificates git
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=1.0.0" -o /out/t5d ./cmd/t5d

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata && addgroup -S t5 && adduser -S -G t5 t5
WORKDIR /app
COPY --from=build /out/t5d /app/t5d
USER t5
EXPOSE 8080
HEALTHCHECK --interval=20s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/readyz >/dev/null || exit 1
ENTRYPOINT ["/app/t5d"]
CMD ["serve"]
