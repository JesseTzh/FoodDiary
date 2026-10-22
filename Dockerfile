FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS frontend
ARG FLUTTER_VERSION=3.47.7
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git libglu1-mesa python3 unzip xz-utils zip \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter precache --web
WORKDIR /app/frontend
COPY frontend/pubspec.yaml frontend/pubspec.lock ./
RUN flutter pub get
COPY frontend ./
COPY scripts/build-pwa.py /app/scripts/build-pwa.py
RUN flutter build web --release --no-web-resources-cdn && python3 /app/scripts/build-pwa.py
FROM golang:1.26-alpine AS backend
ARG BUILD_COMMIT
ARG BUILD_RELEASE_TAG
RUN apk add --no-cache gcc musl-dev
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY backend ./backend
RUN go build -trimpath -ldflags "-X main.buildCommit=${BUILD_COMMIT} -X main.buildReleaseTag=${BUILD_RELEASE_TAG}" -o /fooddiary ./backend/cmd/server
FROM alpine:3.21
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=backend /fooddiary /app/fooddiary
COPY --from=backend /app/backend/migrations /app/backend/migrations
COPY --from=frontend /app/frontend/build/web /app/frontend/build/web
ENV FOODDIARY_ADDR=:8080 FOODDIARY_DATA_DIR=/data FOODDIARY_FRONTEND_DIR=/app/frontend/build/web
VOLUME /data
EXPOSE 8080
CMD ["/app/fooddiary"]
