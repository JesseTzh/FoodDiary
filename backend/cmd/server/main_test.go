package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"mime/multipart"
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

func dataOf(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	defer resp.Body.Close()
	var j struct {
		Data map[string]any `json:"data"`
	}
	if e := json.NewDecoder(resp.Body).Decode(&j); e != nil {
		t.Fatal(e)
	}
	return j.Data
}

// 以已登录身份创建一条记录，返回记录 ID。
func createEntry(t *testing.T, c *http.Client, base, title string) string {
	t.Helper()
	resp := postJSON(t, c, base+"/api/v1/entries", map[string]any{
		"cooked_on": "2026-10-01", "title": title, "category": "home",
		"ingredients": []any{}, "steps": []string{}, "tags": []string{},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create entry %s: got %d", title, resp.StatusCode)
	}
	return dataOf(t, resp)["id"].(string)
}

func guestListIDs(t *testing.T, base string) []string {
	t.Helper()
	resp := get(t, newClient(), base+"/api/v1/guest/entries")
	if resp.StatusCode != 200 {
		t.Fatalf("guest entries: got %d, want 200", resp.StatusCode)
	}
	items := dataOf(t, resp)["items"].([]any)
	ids := []string{}
	for _, it := range items {
		ids = append(ids, it.(map[string]any)["id"].(string))
	}
	return ids
}

func TestGuestShareFlow(t *testing.T) {
	ts, _ := newTestServer(t)
	owner := newClient()
	postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	idA := createEntry(t, owner, ts.URL, "番茄炒蛋")
	idB := createEntry(t, owner, ts.URL, "青椒肉丝")

	guest := newClient()
	if ids := guestListIDs(t, ts.URL); len(ids) != 0 {
		t.Fatalf("no entries should be shared initially, got %v", ids)
	}
	if got := statusOf(t, get(t, guest, ts.URL+"/api/v1/guest/entries/"+idA)); got != 404 {
		t.Fatalf("unshared entry to guest: got %d, want 404", got)
	}

	// 游客不能自己开启分享
	if got := statusOf(t, postJSON(t, guest, ts.URL+"/api/v1/entries/"+idA+"/guest-share", map[string]bool{"enabled": true})); got != 401 {
		t.Fatalf("guest guest-share: got %d, want 401", got)
	}

	// 开放 idA 给游客
	if got := statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/entries/"+idA+"/guest-share", map[string]bool{"enabled": true})); got != 200 {
		t.Fatalf("enable share: got %d", got)
	}
	if ids := guestListIDs(t, ts.URL); len(ids) != 1 || ids[0] != idA {
		t.Fatalf("guest list should only contain %s, got %v", idA, ids)
	}
	if got := statusOf(t, get(t, guest, ts.URL+"/api/v1/guest/entries/"+idA)); got != 200 {
		t.Fatalf("shared entry to guest: got %d, want 200", got)
	}
	if got := statusOf(t, get(t, guest, ts.URL+"/api/v1/guest/entries/"+idB)); got != 404 {
		t.Fatalf("unshared entryB to guest: got %d, want 404", got)
	}
	if n := authStatusOf(t, guest, ts.URL)["guest_shared_count"].(float64); n != 1 {
		t.Fatalf("guest_shared_count: got %v, want 1", n)
	}

	// 取消开放后游客立即不可见
	if got := statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/entries/"+idA+"/guest-share", map[string]bool{"enabled": false})); got != 200 {
		t.Fatalf("disable share: got %d", got)
	}
	if got := statusOf(t, get(t, guest, ts.URL+"/api/v1/guest/entries/"+idA)); got != 404 {
		t.Fatalf("unshared again: got %d, want 404", got)
	}
	if got := statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/entries/missing/guest-share", map[string]bool{"enabled": true})); got != 404 {
		t.Fatalf("share missing entry: got %d, want 404", got)
	}
}

func uploadMedia(t *testing.T, c *http.Client, base, entryID, name string) string {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, _ := w.CreateFormFile("file", name)
	fw.Write([]byte("jpeg-bytes"))
	w.Close()
	resp, e := c.Post(base+"/api/v1/entries/"+entryID+"/media", w.FormDataContentType(), &buf)
	if e != nil {
		t.Fatal(e)
	}
	if resp.StatusCode != 201 {
		t.Fatalf("upload media: got %d", resp.StatusCode)
	}
	return dataOf(t, resp)["id"].(string)
}

func TestGuestMediaAccess(t *testing.T) {
	ts, _ := newTestServer(t)
	owner := newClient()
	postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	sharedID := createEntry(t, owner, ts.URL, "开放菜")
	privateID := createEntry(t, owner, ts.URL, "私密菜")
	sharedMedia := uploadMedia(t, owner, ts.URL, sharedID, "a.jpg")
	privateMedia := uploadMedia(t, owner, ts.URL, privateID, "b.jpg")

	guest := newClient()
	if got := statusOf(t, get(t, guest, ts.URL+"/media/assets/"+sharedMedia+"/original")); got != 401 {
		t.Fatalf("media of unshared entry: got %d, want 401", got)
	}
	postJSON(t, owner, ts.URL+"/api/v1/entries/"+sharedID+"/guest-share", map[string]bool{"enabled": true})
	resp := get(t, guest, ts.URL+"/media/assets/"+sharedMedia+"/original")
	if resp.StatusCode != 200 {
		t.Fatalf("media of shared entry: got %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "jpeg-bytes" {
		t.Fatalf("media content: got %q", body)
	}
	if got := statusOf(t, get(t, guest, ts.URL+"/media/assets/"+privateMedia+"/original")); got != 401 {
		t.Fatalf("private media stays protected: got %d, want 401", got)
	}
	// 登录用户访问未开放记录的照片不受影响
	if got := statusOf(t, get(t, owner, ts.URL+"/media/assets/"+privateMedia+"/original")); got != 200 {
		t.Fatalf("owner media access: got %d, want 200", got)
	}
}

func TestMigrationsIdempotent(t *testing.T) {
	db, e := sql.Open("sqlite3", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if e := loadMigrations(db, "../../migrations"); e != nil {
		t.Fatalf("first run: %v", e)
	}
	if e := loadMigrations(db, "../../migrations"); e != nil {
		t.Fatalf("second run must skip applied migrations: %v", e)
	}
	var n int
	if e := db.QueryRow("SELECT COUNT(*) FROM diary_entries WHERE shared_with_guests=0").Scan(&n); e != nil {
		t.Fatalf("shared_with_guests column missing: %v", e)
	}
	var applied int
	if e := db.QueryRow("SELECT COUNT(*) FROM schema_migrations").Scan(&applied); e != nil || applied != 3 {
		t.Fatalf("schema_migrations rows: got %d (%v), want 3", applied, e)
	}
}

func newCORSTestServer(t *testing.T, origins ...string) *httptest.Server {
	t.Helper()
	db, e := sql.Open("sqlite3", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000")
	if e := loadMigrations(db, "../../migrations"); e != nil {
		t.Fatal(e)
	}
	a := &App{db: db, data: t.TempDir(), sessionDays: 30, limiter: newIPLimiter(), corsOrigins: origins}
	ts := httptest.NewServer(routes(a))
	t.Cleanup(func() { ts.Close(); db.Close() })
	return ts
}

func TestCORSAllowedOrigin(t *testing.T) {
	ts := newCORSTestServer(t, "http://localhost:5173")
	req, _ := http.NewRequest("OPTIONS", ts.URL+"/api/v1/entries", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	req.Header.Set("Access-Control-Request-Method", "POST")
	resp, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight: got %d, want 204", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "http://localhost:5173" {
		t.Fatalf("preflight ACAO: got %q", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Fatalf("preflight ACAC: got %q", got)
	}

	req, _ = http.NewRequest("GET", ts.URL+"/api/v1/auth/status", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	resp, e = http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status: got %d, want 200", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "http://localhost:5173" {
		t.Fatalf("status ACAO: got %q", got)
	}
}

func TestCORSDisallowedOrigin(t *testing.T) {
	ts := newCORSTestServer(t, "http://localhost:5173")
	req, _ := http.NewRequest("GET", ts.URL+"/api/v1/auth/status", nil)
	req.Header.Set("Origin", "http://evil.example")
	resp, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("unlisted origin must not get ACAO, got %q", got)
	}
}

func TestCORSDisabledByDefault(t *testing.T) {
	ts, _ := newTestServer(t)
	req, _ := http.NewRequest("GET", ts.URL+"/api/v1/auth/status", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	resp, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("CORS must stay off by default, got ACAO %q", got)
	}
}
