package main

import (
	"bytes"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestJWTValidation(t *testing.T) {
	a := &App{jwtKey: []byte("01234567890123456789012345678901")}
	valid, err := a.signAccess(strings.Repeat("a", 64), time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	claims, err := a.parseAccess(valid)
	if err != nil {
		t.Fatal(err)
	}
	if claims.ExpiresAt.Time.Sub(claims.IssuedAt.Time) != accessTTL {
		t.Fatal("wrong JWT lifetime")
	}
	cases := []struct {
		name   string
		mutate func(*accessClaims)
		method jwt.SigningMethod
		key    any
	}{
		{"wrong issuer", func(c *accessClaims) { c.Issuer = "evil" }, jwt.SigningMethodHS256, a.jwtKey},
		{"wrong audience", func(c *accessClaims) { c.Audience = jwt.ClaimStrings{"other"} }, jwt.SigningMethodHS256, a.jwtKey},
		{"wrong subject", func(c *accessClaims) { c.Subject = "guest" }, jwt.SigningMethodHS256, a.jwtKey},
		{"expired", func(c *accessClaims) { c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute)) }, jwt.SigningMethodHS256, a.jwtKey},
		{"missing expiry", func(c *accessClaims) { c.ExpiresAt = nil }, jwt.SigningMethodHS256, a.jwtKey},
		{"future issued", func(c *accessClaims) { c.IssuedAt = jwt.NewNumericDate(time.Now().Add(time.Hour)) }, jwt.SigningMethodHS256, a.jwtKey},
		{"future nbf", func(c *accessClaims) { c.NotBefore = jwt.NewNumericDate(time.Now().Add(time.Hour)) }, jwt.SigningMethodHS256, a.jwtKey},
		{"missing iat", func(c *accessClaims) { c.IssuedAt = nil }, jwt.SigningMethodHS256, a.jwtKey},
		{"missing nbf", func(c *accessClaims) { c.NotBefore = nil }, jwt.SigningMethodHS256, a.jwtKey},
		{"missing jti", func(c *accessClaims) { c.ID = "" }, jwt.SigningMethodHS256, a.jwtKey},
		{"missing session", func(c *accessClaims) { c.SessionID = "" }, jwt.SigningMethodHS256, a.jwtKey},
		{"long expiry", func(c *accessClaims) { c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(time.Hour)) }, jwt.SigningMethodHS256, a.jwtKey},
		{"wrong key", func(c *accessClaims) {}, jwt.SigningMethodHS256, []byte(strings.Repeat("z", 32))},
		{"wrong algorithm", func(c *accessClaims) {}, jwt.SigningMethodHS384, a.jwtKey},
		{"unsigned", func(c *accessClaims) {}, jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := *claims
			tc.mutate(&c)
			raw, err := jwt.NewWithClaims(tc.method, c).SignedString(tc.key)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = a.parseAccess(raw); err == nil {
				t.Fatal("accepted invalid JWT")
			}
		})
	}
	for _, raw := range []string{"legacy-opaque-token", valid + "x", strings.Repeat("x", 5000)} {
		if _, err := a.parseAccess(raw); err == nil {
			t.Fatal("accepted malformed token")
		}
	}
}
func nativeRequest(t *testing.T, ts *httptest.Server, method, path, credential string) *http.Response {
	t.Helper()
	body := bytes.NewBufferString(`{"password":"hunter2"}`)
	req, _ := http.NewRequest(method, ts.URL+path, body)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-FoodDiary-Client", "app")
	if credential != "" {
		req.Header.Set("Authorization", "Bearer "+credential)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}
func TestNativeRefreshReplayAndRevocation(t *testing.T) {
	ts, db := newTestServer(t)
	login := nativeRequest(t, ts, "POST", "/api/v1/auth/setup", "")
	access, refresh := login.Header.Get("X-Session-Token"), login.Header.Get("X-Refresh-Token")
	if statusOf(t, login) != 200 || access == "" || refresh == "" {
		t.Fatal("missing native tokens")
	}
	var expiry, stored string
	if err := db.QueryRow("SELECT s.expires_at,r.token_hash FROM sessions s JOIN refresh_tokens r ON r.session_hash=s.token_hash").Scan(&expiry, &stored); err != nil {
		t.Fatal(err)
	}
	deadline, _ := time.Parse(time.RFC3339, expiry)
	if d := time.Until(deadline); d < 30*24*time.Hour-time.Minute || d > 30*24*time.Hour {
		t.Fatalf("App lifetime %v", d)
	}
	if stored == refresh || stored != tokenHash(refresh) {
		t.Fatal("refresh token not hashed")
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", refresh)); got != 401 {
		t.Fatal("refresh token accepted as access")
	}
	res := nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", refresh)
	nextAccess, nextRefresh := res.Header.Get("X-Session-Token"), res.Header.Get("X-Refresh-Token")
	if statusOf(t, res) != 200 || nextRefresh == refresh || nextAccess == access {
		t.Fatal("refresh did not rotate")
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", nextAccess)); got != 200 {
		t.Fatalf("new access: %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", refresh)); got != 401 {
		t.Fatal("replayed refresh accepted")
	}
	for _, credential := range []string{access, nextAccess} {
		if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", credential)); got != 401 {
			t.Fatal("replay did not revoke JWT")
		}
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", nextRefresh)); got != 401 {
		t.Fatal("replay did not revoke refresh family")
	}
	login = nativeRequest(t, ts, "POST", "/api/v1/auth/login", "")
	access, refresh = login.Header.Get("X-Session-Token"), login.Header.Get("X-Refresh-Token")
	statusOf(t, login)
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/logout", refresh)); got != 200 {
		t.Fatalf("logout %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", access)); got != 401 {
		t.Fatal("logout did not revoke JWT")
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", refresh)); got != 401 {
		t.Fatal("logout did not revoke refresh")
	}
}

func TestMultipleDeviceSessionsAreIndependent(t *testing.T) {
	ts, db := newTestServer(t)
	web := newClient()
	first := nativeRequest(t, ts, "POST", "/api/v1/auth/setup", "")
	firstAccess, firstRefresh := first.Header.Get("X-Session-Token"), first.Header.Get("X-Refresh-Token")
	if got := statusOf(t, first); got != 200 {
		t.Fatalf("setup: %d", got)
	}
	second := nativeRequest(t, ts, "POST", "/api/v1/auth/login", "")
	secondAccess, secondRefresh := second.Header.Get("X-Session-Token"), second.Header.Get("X-Refresh-Token")
	if got := statusOf(t, second); got != 200 {
		t.Fatalf("second login: %d", got)
	}
	if got := statusOf(t, postJSON(t, web, ts.URL+"/api/v1/auth/login", map[string]string{"password": "hunter2"})); got != 200 {
		t.Fatalf("Web login: %d", got)
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&count); err != nil || count != 3 {
		t.Fatalf("expected three independent sessions, got %d (%v)", count, err)
	}
	if firstAccess == secondAccess || firstRefresh == secondRefresh {
		t.Fatal("device sessions reused credentials")
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", firstAccess)); got != 200 {
		t.Fatalf("first device: %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", secondAccess)); got != 200 {
		t.Fatalf("second device: %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/logout", firstRefresh)); got != 200 {
		t.Fatalf("first logout: %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", firstAccess)); got != 401 {
		t.Fatal("first device remained active after logout")
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", secondAccess)); got != 200 {
		t.Fatal("second device was revoked by first logout")
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", secondRefresh)); got != 200 {
		t.Fatalf("second refresh: %d", got)
	}
	// Refresh replay revokes only the second device, leaving the Web session active.
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", secondRefresh)); got != 401 {
		t.Fatal("refresh replay accepted")
	}
	if got := statusOf(t, get(t, web, ts.URL+"/api/v1/entries")); got != 200 {
		t.Fatal("App revocation affected Web session")
	}
	if got := statusOf(t, postJSON(t, web, ts.URL+"/api/v1/auth/refresh", nil)); got != 200 {
		t.Fatal("Web refresh failed after App replay")
	}
}

func TestBrowserCookiesAndCSRF(t *testing.T) {
	ts, _ := newTestServer(t)
	res := postJSON(t, newClient(), ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	defer res.Body.Close()
	if res.Header.Get("X-Session-Token") != "" || res.Header.Get("X-Refresh-Token") != "" {
		t.Fatal("browser tokens exposed")
	}
	if len(res.Cookies()) != 2 {
		t.Fatal("missing cookies")
	}
	for _, c := range res.Cookies() {
		if !c.HttpOnly || c.SameSite != http.SameSiteLaxMode {
			t.Fatal("unsafe cookie")
		}
		if c.Name == refreshCookieName && (c.Path != "/api/v1/auth" || c.MaxAge > 7*86400 || c.MaxAge < 7*86400-5) {
			t.Fatalf("refresh cookie %+v", c)
		}
	}
	for _, origin := range []string{"", "null", "https://evil.example"} {
		req, _ := http.NewRequest("POST", ts.URL+"/api/v1/auth/logout", nil)
		req.Header.Set("Origin", origin)
		req.Header.Set("X-FoodDiary-Client", "app") // Header does not bypass explicit malicious Origin.
		if origin == "" {
			req.Header.Del("X-FoodDiary-Client")
		}
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if got := statusOf(t, r); got != 403 {
			t.Fatalf("origin %q: %d", origin, got)
		}
	}
	a := &App{}
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "https://food.example/api/v1/auth/login", nil)
	req.Header.Set("Origin", "https://food.example")
	a.sendTokens(recorder, req, "access", "refresh", time.Now().Add(7*24*time.Hour))
	for _, c := range recorder.Result().Cookies() {
		if !c.Secure {
			t.Fatal("HTTPS cookie missing Secure")
		}
	}
}
func TestJWTKeyPersistence(t *testing.T) {
	t.Setenv("FOODDIARY_JWT_SECRET", "")
	dir := t.TempDir()
	key, err := loadJWTKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	again, err := loadJWTKey(dir)
	if err != nil || !bytes.Equal(key, again) {
		t.Fatal("key changed on restart")
	}
	info, err := os.Stat(filepath.Join(dir, "jwt.key"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("key permissions")
	}
	for _, bad := range []string{"weak", hex.EncodeToString([]byte("short"))} {
		t.Setenv("FOODDIARY_JWT_SECRET", bad)
		if _, err := loadJWTKey(dir); err == nil {
			t.Fatal("weak secret accepted")
		}
	}
	t.Setenv("FOODDIARY_JWT_SECRET", hex.EncodeToString(key))
	if configured, err := loadJWTKey(dir); err != nil || !bytes.Equal(configured, key) {
		t.Fatal("configured key failed")
	}
}

func TestConcurrentRefreshAndSessionExpiry(t *testing.T) {
	ts, db := newTestServer(t)
	login := nativeRequest(t, ts, "POST", "/api/v1/auth/setup", "")
	access, refresh := login.Header.Get("X-Session-Token"), login.Header.Get("X-Refresh-Token")
	statusOf(t, login)
	statuses := make(chan int, 2)
	for range 2 {
		go func() {
			req, _ := http.NewRequest("POST", ts.URL+"/api/v1/auth/refresh", nil)
			req.Header.Set("X-FoodDiary-Client", "app")
			req.Header.Set("Authorization", "Bearer "+refresh)
			res, err := http.DefaultClient.Do(req)
			if err != nil {
				statuses <- 0
				return
			}
			res.Body.Close()
			statuses <- res.StatusCode
		}()
	}
	first, second := <-statuses, <-statuses
	if !((first == 200 && second == 401) || (first == 401 && second == 200)) {
		t.Fatalf("concurrent rotation: %d %d", first, second)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", access)); got != 401 {
		t.Fatal("concurrent replay failed to revoke family")
	}
	login = nativeRequest(t, ts, "POST", "/api/v1/auth/login", "")
	access, refresh = login.Header.Get("X-Session-Token"), login.Header.Get("X-Refresh-Token")
	statusOf(t, login)
	if _, err := db.Exec("UPDATE sessions SET expires_at=?", time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", access)); got != 401 {
		t.Fatal("expired family accepted access JWT")
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", refresh)); got != 401 {
		t.Fatal("expired family refreshed")
	}
}

func TestExpiredAccessCanRefresh(t *testing.T) {
	ts, _ := newTestServer(t)
	login := nativeRequest(t, ts, "POST", "/api/v1/auth/setup", "")
	raw, refresh := login.Header.Get("X-Session-Token"), login.Header.Get("X-Refresh-Token")
	statusOf(t, login)
	a := &App{jwtKey: []byte("01234567890123456789012345678901")}
	claims, err := a.parseAccess(raw)
	if err != nil {
		t.Fatal(err)
	}
	claims.IssuedAt = jwt.NewNumericDate(time.Now().Add(-time.Hour))
	claims.NotBefore = claims.IssuedAt
	claims.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-45 * time.Minute))
	expired, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(a.jwtKey)
	if err != nil {
		t.Fatal(err)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", expired)); got != 401 {
		t.Fatal("expired JWT accepted")
	}
	response := nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", refresh)
	renewed := response.Header.Get("X-Session-Token")
	if got := statusOf(t, response); got != 200 {
		t.Fatalf("refresh expired access: %d", got)
	}
	if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", renewed)); got != 200 {
		t.Fatalf("renewed access: %d", got)
	}
}

func TestConfiguredPasswordPreservesSessionsUnlessChanged(t *testing.T) {
	ts, db := newTestServer(t)
	first := nativeRequest(t, ts, "POST", "/api/v1/auth/setup", "")
	firstAccess := first.Header.Get("X-Session-Token")
	statusOf(t, first)
	second := nativeRequest(t, ts, "POST", "/api/v1/auth/login", "")
	secondAccess, secondRefresh := second.Header.Get("X-Session-Token"), second.Header.Get("X-Refresh-Token")
	statusOf(t, second)
	a := &App{db: db}
	before := a.passwordHash()
	changed, err := a.configurePassword("hunter2")
	if err != nil || changed || before != a.passwordHash() {
		t.Fatalf("same password changed state: %v %v", changed, err)
	}
	for _, access := range []string{firstAccess, secondAccess} {
		if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", access)); got != 200 {
			t.Fatal("unchanged password revoked a device")
		}
	}
	changed, err = a.configurePassword("hunter3")
	if err != nil || !changed || !verifyPassword(a.passwordHash(), "hunter3") {
		t.Fatalf("password change failed: %v %v", changed, err)
	}
	for _, access := range []string{firstAccess, secondAccess} {
		if got := statusOf(t, nativeRequest(t, ts, "GET", "/api/v1/entries", access)); got != 401 {
			t.Fatal("password change failed to revoke a device")
		}
	}
	if got := statusOf(t, nativeRequest(t, ts, "POST", "/api/v1/auth/refresh", secondRefresh)); got != 401 {
		t.Fatal("password change allowed stale refresh")
	}
}
