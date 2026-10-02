package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func newTestServer(t *testing.T) (*httptest.Server, *sql.DB) {
	t.Helper()
	db, e := sql.Open("sqlite3", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000")
	if e := loadMigrations(db, "../../migrations"); e != nil {
		t.Fatal(e)
	}
	a := &App{db: db, data: t.TempDir(), sessionDays: 30, limiter: newIPLimiter()}
	ts := httptest.NewServer(routes(a))
	t.Cleanup(func() { ts.Close(); db.Close() })
	return ts, db
}

func newClient() *http.Client {
	jar, _ := cookiejar.New(nil)
	return &http.Client{Jar: jar}
}

func postJSON(t *testing.T, c *http.Client, url string, body any) *http.Response {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, e := c.Post(url, "application/json", bytes.NewReader(b))
	if e != nil {
		t.Fatal(e)
	}
	return resp
}

func get(t *testing.T, c *http.Client, url string) *http.Response {
	t.Helper()
	resp, e := c.Get(url)
	if e != nil {
		t.Fatal(e)
	}
	return resp
}

func statusOf(t *testing.T, resp *http.Response) int {
	t.Helper()
	defer resp.Body.Close()
	return resp.StatusCode
}

func authStatusOf(t *testing.T, c *http.Client, base string) map[string]any {
	t.Helper()
	resp := get(t, c, base+"/api/v1/auth/status")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("auth status: got %d", resp.StatusCode)
	}
	var j struct {
		Data map[string]any `json:"data"`
	}
	json.NewDecoder(resp.Body).Decode(&j)
	return j.Data
}

func TestPasswordProtectsAPI(t *testing.T) {
	ts, _ := newTestServer(t)
	plain := newClient()
	if got := statusOf(t, get(t, plain, ts.URL+"/api/v1/entries")); got != 401 {
		t.Fatalf("entries without session: got %d, want 401", got)
	}
	if got := statusOf(t, get(t, plain, ts.URL+"/media/assets/x/original")); got != 401 {
		t.Fatalf("media without session: got %d, want 401", got)
	}

	s := authStatusOf(t, plain, ts.URL)
	if s["auth_required"].(bool) || s["authenticated"].(bool) {
		t.Fatalf("fresh instance should need setup: %v", s)
	}

	if got := statusOf(t, postJSON(t, plain, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "123"})); got != 400 {
		t.Fatalf("short password: got %d, want 400", got)
	}
	c := newClient()
	if got := statusOf(t, postJSON(t, c, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})); got != 200 {
		t.Fatalf("setup: got %d, want 200", got)
	}
	if got := statusOf(t, postJSON(t, newClient(), ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter3"})); got != 409 {
		t.Fatalf("second setup: got %d, want 409", got)
	}

	s = authStatusOf(t, c, ts.URL)
	if !s["auth_required"].(bool) || !s["authenticated"].(bool) {
		t.Fatalf("after setup should be authenticated: %v", s)
	}
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 200 {
		t.Fatalf("entries with session: got %d, want 200", got)
	}
}

func TestLoginWrongPasswordAndRateLimit(t *testing.T) {
	ts, _ := newTestServer(t)
	c := newClient()
	if got := statusOf(t, postJSON(t, c, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})); got != 200 {
		t.Fatalf("setup: got %d", got)
	}
	if got := statusOf(t, postJSON(t, newClient(), ts.URL+"/api/v1/auth/login", map[string]string{"password": "nope"})); got != 401 {
		t.Fatalf("wrong password: got %d, want 401", got)
	}
	for i := 0; i < 9; i++ {
		statusOf(t, postJSON(t, newClient(), ts.URL+"/api/v1/auth/login", map[string]string{"password": "nope"}))
	}
	if got := statusOf(t, postJSON(t, newClient(), ts.URL+"/api/v1/auth/login", map[string]string{"password": "hunter2"})); got != 429 {
		t.Fatalf("11th attempt should be rate limited: got %d, want 429", got)
	}
}

func TestLogoutInvalidatesSession(t *testing.T) {
	ts, _ := newTestServer(t)
	c := newClient()
	postJSON(t, c, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	if got := statusOf(t, postJSON(t, c, ts.URL+"/api/v1/auth/logout", nil)); got != 200 {
		t.Fatalf("logout: got %d", got)
	}
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 401 {
		t.Fatalf("entries after logout: got %d, want 401", got)
	}
}

func TestExpiredSessionRejected(t *testing.T) {
	ts, db := newTestServer(t)
	c := newClient()
	postJSON(t, c, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 200 {
		t.Fatalf("entries after setup: got %d", got)
	}

	// 模拟一个月未访问：把所有会话过期时间改到过去
	if _, e := db.Exec("UPDATE sessions SET last_seen_at=?,expires_at=?", time.Now().UTC().Add(-31*24*time.Hour).Format(time.RFC3339), time.Now().UTC().Add(-1*time.Hour).Format(time.RFC3339)); e != nil {
		t.Fatal(e)
	}
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 401 {
		t.Fatalf("expired session: got %d, want 401", got)
	}
	// 过期后应能重新登录
	if got := statusOf(t, postJSON(t, c, ts.URL+"/api/v1/auth/login", map[string]string{"password": "hunter2"})); got != 200 {
		t.Fatalf("login after expiry: got %d, want 200", got)
	}
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 200 {
		t.Fatalf("entries after re-login: got %d, want 200", got)
	}
}

func TestSessionSlidingRenewal(t *testing.T) {
	ts, db := newTestServer(t)
	c := newClient()
	postJSON(t, c, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})

	// 把会话改成“29 天前最后活跃、今天到期”，一次访问后应续期 30 天
	past := time.Now().UTC().Add(-29 * 24 * time.Hour).Format(time.RFC3339)
	if _, e := db.Exec("UPDATE sessions SET created_at=?,last_seen_at=?", past, past); e != nil {
		t.Fatal(e)
	}
	if got := statusOf(t, get(t, c, ts.URL+"/api/v1/entries")); got != 200 {
		t.Fatalf("entries: got %d, want 200", got)
	}
	var expires string
	if e := db.QueryRow("SELECT expires_at FROM sessions LIMIT 1").Scan(&expires); e != nil {
		t.Fatal(e)
	}
	exp, e := time.Parse(time.RFC3339, expires)
	if e != nil {
		t.Fatal(e)
	}
	if d := time.Until(exp); d < 29*24*time.Hour {
		t.Fatalf("session should be renewed to ~30 days, got %.1f days", d.Hours()/24)
	}
}

func TestVerifyPassword(t *testing.T) {
	h, e := hashPassword("hunter2")
	if e != nil {
		t.Fatal(e)
	}
	if !verifyPassword(h, "hunter2") {
		t.Fatal("correct password rejected")
	}
	if verifyPassword(h, "hunter3") {
		t.Fatal("wrong password accepted")
	}
	if verifyPassword("garbage", "hunter2") {
		t.Fatal("malformed hash accepted")
	}
}
