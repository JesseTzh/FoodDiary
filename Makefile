.PHONY: dev check build
build: frontend/dist
	go build -o fooddiary ./backend/cmd/server
frontend/dist: frontend/src/main.tsx
	npm run build
check:
	go test ./...
	go vet ./...
	npm run type-check
	npm run build
dev:
	@trap 'kill 0' INT TERM; (go run ./backend/cmd/server) & (npm run dev)
