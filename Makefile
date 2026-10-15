.PHONY: dev mock web backend build check apk appbundle
FLUTTER ?= flutter
API_BASE_URL ?=
build: web backend
web:
	./scripts/build-web.sh
backend:
	go build -o fooddiary ./backend/cmd/server
check:
	go vet ./...
	cd frontend && $(FLUTTER) analyze
apk:
	FLUTTER="$(FLUTTER)" bash scripts/build-flutter.sh apk --release --dart-define=API_BASE_URL=$(API_BASE_URL)
appbundle:
	FLUTTER="$(FLUTTER)" bash scripts/build-flutter.sh appbundle --release --dart-define=API_BASE_URL=$(API_BASE_URL)
dev:
	@trap 'kill 0' INT TERM EXIT; FOODDIARY_CORS_ORIGINS=http://localhost:5173 go run ./backend/cmd/server & cd frontend && $(FLUTTER) run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://localhost:8080

# Frontend-only local development with persistent mock data.
mock:
	cd frontend && $(FLUTTER) run -d chrome --web-port=5173 --dart-define=MOCK_API=true
