FROM node:22-alpine AS frontend
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend ./frontend
COPY vite.config.ts tsconfig.json ./
RUN npm run build
FROM golang:1.26-alpine AS backend
RUN apk add --no-cache gcc musl-dev
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY backend ./backend
RUN go build -o /fooddiary ./backend/cmd/server
FROM alpine:3.21
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=backend /fooddiary /app/fooddiary
COPY --from=backend /app/backend/migrations /app/backend/migrations
COPY --from=frontend /app/frontend/dist /app/frontend/dist
ENV FOODDIARY_ADDR=:8080 FOODDIARY_DATA_DIR=/data FOODDIARY_FRONTEND_DIR=/app/frontend/dist
VOLUME /data
EXPOSE 8080
CMD ["/app/fooddiary"]
