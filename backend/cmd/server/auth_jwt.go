package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	jwtIssuer         = "fooddiary"
	jwtAudience       = "fooddiary-api"
	refreshCookieName = "fooddiary_refresh"
	accessTTL         = 15 * time.Minute
)

type accessClaims struct {
	SessionID string `json:"sid"`
	jwt.RegisteredClaims
}

// A persistent, random 256-bit key survives restarts. Explicit keys must be
// hex-encoded and at least 256 bits; configuration errors fail closed.
func loadJWTKey(data string) ([]byte, error) {
	if value := os.Getenv("FOODDIARY_JWT_SECRET"); value != "" {
		key, err := hex.DecodeString(value)
		if err != nil || len(key) < 32 {
			return nil, errors.New("FOODDIARY_JWT_SECRET must be hex-encoded with at least 32 bytes")
		}
		return key, nil
	}
	path := filepath.Join(data, "jwt.key")
	key, err := os.ReadFile(path)
	if err == nil {
		if len(key) != 32 {
			return nil, errors.New("invalid jwt.key length")
		}
		if err := os.Chmod(path, 0600); err != nil {
			return nil, err
		}
		return key, nil
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if os.IsExist(err) {
		return loadJWTKey(data)
	}
	if err != nil {
		return nil, err
	}
	_, err = f.Write(key)
	closeErr := f.Close()
	if err != nil {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return key, nil
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func randomToken() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}
func bearerToken(r *http.Request) string {
	parts := strings.Fields(r.Header.Get("Authorization"))
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		return parts[1]
	}
	return ""
}
func sessionToken(r *http.Request) string {
	// Never fall back to a cookie when an invalid Authorization was provided.
	if r.Header.Get("Authorization") != "" {
		return bearerToken(r)
	}
	cookie, err := r.Cookie(sessionCookieName)
	if err != nil {
		return ""
	}
	return cookie.Value
}
func refreshToken(r *http.Request) string {
	if r.Header.Get("Authorization") != "" {
		return bearerToken(r)
	}
	cookie, err := r.Cookie(refreshCookieName)
	if err != nil {
		return ""
	}
	return cookie.Value
}
func (a *App) signAccess(sid string, deadline time.Time) (string, error) {
	issued := time.Now().UTC()
	expires := issued.Add(accessTTL)
	if deadline.Before(expires) {
		expires = deadline
	}
	jti, err := randomToken()
	if err != nil {
		return "", err
	}
	claims := accessClaims{SessionID: sid, RegisteredClaims: jwt.RegisteredClaims{
		Issuer: jwtIssuer, Subject: "owner", Audience: jwt.ClaimStrings{jwtAudience},
		ExpiresAt: jwt.NewNumericDate(expires), IssuedAt: jwt.NewNumericDate(issued),
		NotBefore: jwt.NewNumericDate(issued), ID: jti,
	}}
	if len(a.jwtKey) < 32 {
		return "", errors.New("JWT key is not configured")
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(a.jwtKey)
}
func (a *App) parseAccess(raw string) (*accessClaims, error) {
	if len(raw) == 0 || len(raw) > 4096 || len(a.jwtKey) < 32 {
		return nil, errors.New("invalid access token")
	}
	claims := &accessClaims{}
	token, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("invalid algorithm")
		}
		return a.jwtKey, nil
	}, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer(jwtIssuer), jwt.WithAudience(jwtAudience), jwt.WithSubject("owner"), jwt.WithExpirationRequired(), jwt.WithIssuedAt())
	if err != nil {
		return nil, err
	}
	if !token.Valid || claims.IssuedAt == nil || claims.NotBefore == nil || claims.ID == "" || len(claims.SessionID) != 64 || claims.ExpiresAt.Time.Sub(claims.IssuedAt.Time) > accessTTL || !claims.ExpiresAt.After(claims.IssuedAt.Time) {
		return nil, errors.New("invalid claims")
	}
	return claims, nil
}
func (a *App) sessionValid(token string) (time.Time, bool) {
	claims, err := a.parseAccess(token)
	if err != nil {
		return time.Time{}, false
	}
	var lastSeen, expires string
	if a.db.QueryRow("SELECT last_seen_at,expires_at FROM sessions WHERE token_hash=?", claims.SessionID).Scan(&lastSeen, &expires) != nil {
		return time.Time{}, false
	}
	deadline, err := time.Parse(time.RFC3339, expires)
	if err != nil || !time.Now().Before(deadline) {
		return time.Time{}, false
	}
	seen, _ := time.Parse(time.RFC3339, lastSeen)
	return seen, true
}
func (a *App) authed(r *http.Request) bool {
	_, ok := a.sessionValid(sessionToken(r))
	return ok
}
func (a *App) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.authed(r) {
			errJSON(w, 401, "UNAUTHORIZED", "authentication required")
			return
		}
		next.ServeHTTP(w, r)
	})
}
func setAuthCookie(w http.ResponseWriter, r *http.Request, name, token, path string, age int) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: token, Path: path, MaxAge: age, HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https"})
}
func (a *App) sendTokens(w http.ResponseWriter, r *http.Request, access, refresh string, deadline time.Time) {
	w.Header().Set("Cache-Control", "no-store")
	// Browser tokens stay in HttpOnly cookies; native clients explicitly opt in.
	if r.Header.Get("X-FoodDiary-Client") == "app" {
		w.Header().Set("X-Session-Token", access)
		w.Header().Set("X-Refresh-Token", refresh)
	} else {
		age := int(time.Until(deadline).Seconds())
		if age > int(accessTTL.Seconds()) {
			age = int(accessTTL.Seconds())
		}
		setAuthCookie(w, r, sessionCookieName, access, "/", age)
		setAuthCookie(w, r, refreshCookieName, refresh, "/api/v1/auth", int(time.Until(deadline).Seconds()))
	}
}
func (a *App) newSession(w http.ResponseWriter, r *http.Request) error {
	days := 7
	if r.Header.Get("X-FoodDiary-Client") == "app" {
		days = 30
	}
	deadline := time.Now().UTC().Add(time.Duration(days) * 24 * time.Hour)
	sid, err := randomToken()
	if err != nil {
		return err
	}
	refresh, err := randomToken()
	if err != nil {
		return err
	}
	access, err := a.signAccess(sid, deadline)
	if err != nil {
		return err
	}
	tx, err := a.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM refresh_tokens WHERE session_hash IN (SELECT token_hash FROM sessions WHERE expires_at < ?)", now()); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM sessions WHERE expires_at < ?", now()); err != nil {
		return err
	}
	if _, err := tx.Exec("INSERT INTO sessions(token_hash,created_at,last_seen_at,expires_at) VALUES(?,?,?,?)", sid, now(), now(), deadline.Format(time.RFC3339)); err != nil {
		return err
	}
	if _, err := tx.Exec("INSERT INTO refresh_tokens(token_hash,session_hash) VALUES(?,?)", tokenHash(refresh), sid); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	a.sendTokens(w, r, access, refresh, deadline)
	return nil
}
func (a *App) authRefresh(w http.ResponseWriter, r *http.Request) {
	raw := refreshToken(r)
	if len(raw) != 64 {
		errJSON(w, 401, "UNAUTHORIZED", "invalid refresh token")
		return
	}
	tx, err := a.db.Begin()
	if err != nil {
		errJSON(w, 500, "DB", "could not refresh session")
		return
	}
	defer tx.Rollback()
	var sid, expiry string
	var consumed int
	err = tx.QueryRow("SELECT r.session_hash,r.consumed,s.expires_at FROM refresh_tokens r JOIN sessions s ON s.token_hash=r.session_hash WHERE r.token_hash=?", tokenHash(raw)).Scan(&sid, &consumed, &expiry)
	deadline, dateErr := time.Parse(time.RFC3339, expiry)
	if err != nil || dateErr != nil {
		errJSON(w, 401, "UNAUTHORIZED", "invalid refresh token")
		return
	}
	if consumed != 0 || !time.Now().Before(deadline) {
		if _, err = tx.Exec("DELETE FROM sessions WHERE token_hash=?", sid); err != nil {
			errJSON(w, 500, "DB", "could not revoke session")
			return
		}
		if err = tx.Commit(); err != nil {
			errJSON(w, 500, "DB", "could not revoke session")
			return
		}
		errJSON(w, 401, "UNAUTHORIZED", "refresh token expired or reused")
		return
	}
	refresh, err := randomToken()
	if err != nil {
		errJSON(w, 500, "AUTH", "could not create token")
		return
	}
	access, err := a.signAccess(sid, deadline)
	if err != nil {
		errJSON(w, 500, "AUTH", "could not create token")
		return
	}
	result, err := tx.Exec("UPDATE refresh_tokens SET consumed=1 WHERE token_hash=? AND consumed=0", tokenHash(raw))
	if err != nil {
		errJSON(w, 500, "DB", "could not refresh session")
		return
	}
	if n, _ := result.RowsAffected(); n != 1 {
		errJSON(w, 401, "UNAUTHORIZED", "refresh token reused")
		return
	}
	if _, err = tx.Exec("INSERT INTO refresh_tokens(token_hash,session_hash) VALUES(?,?)", tokenHash(refresh), sid); err != nil {
		errJSON(w, 500, "DB", "could not refresh session")
		return
	}
	if _, err = tx.Exec("UPDATE sessions SET last_seen_at=? WHERE token_hash=?", now(), sid); err != nil {
		errJSON(w, 500, "DB", "could not refresh session")
		return
	}
	if err = tx.Commit(); err != nil {
		errJSON(w, 500, "DB", "could not refresh session")
		return
	}
	a.sendTokens(w, r, access, refresh, deadline)
	writeJSON(w, 200, map[string]any{"ok": true})
}
func (a *App) authLogout(w http.ResponseWriter, r *http.Request) {
	// Logout works with an expired access JWT, provided the refresh credential is valid.
	sid := ""
	if claims, err := a.parseAccess(sessionToken(r)); err == nil {
		sid = claims.SessionID
	}
	if sid == "" {
		a.db.QueryRow("SELECT session_hash FROM refresh_tokens WHERE token_hash=?", tokenHash(refreshToken(r))).Scan(&sid)
	}
	if sid != "" {
		if _, err := a.db.Exec("DELETE FROM sessions WHERE token_hash=?", sid); err != nil {
			errJSON(w, 500, "DB", "could not revoke session")
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	setAuthCookie(w, r, sessionCookieName, "", "/", -1)
	setAuthCookie(w, r, refreshCookieName, "", "/api/v1/auth", -1)
	writeJSON(w, 200, map[string]any{"ok": true})
}

// Reject cross-site writes (including login CSRF), even from sibling domains.
// Origin is mandatory for cookie writes; non-browser clients use an explicit
// custom header, which browsers can only send after a permitted CORS preflight.
func (a *App) protectBrowserWrites(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			w.Header().Set("Cache-Control", "no-store")
			if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions {
				origin := r.Header.Get("Origin")
				if origin != "" {
					parsed, err := url.Parse(origin)
					scheme := "http"
					if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
						scheme = "https"
					}
					sameOrigin := err == nil && origin != "null" && parsed.Scheme == scheme && parsed.Host == r.Host && parsed.Path == "" && parsed.RawQuery == "" && parsed.Fragment == "" && parsed.User == nil
					if !sameOrigin && !a.corsAllowed(origin) {
						errJSON(w, 403, "FORBIDDEN", "untrusted request origin")
						return
					}
				} else if r.Header.Get("X-FoodDiary-Client") != "app" {
					errJSON(w, 403, "FORBIDDEN", fmt.Sprintf("Origin required for %s", r.Method))
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

// Preserve device sessions on restart with the same configured password.
// A real password change and session revocation commit together.
func (a *App) configurePassword(password string) (bool, error) {
	if len(password) < 6 || len(password) > 128 {
		return false, errors.New("password must be 6-128 chars")
	}
	tx, err := a.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var stored string
	err = tx.QueryRow("SELECT value FROM app_settings WHERE key=?", passwordSettingKey).Scan(&stored)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if stored != "" && verifyPassword(stored, password) {
		return false, nil
	}
	hash, err := hashPassword(password)
	if err != nil {
		return false, err
	}
	if _, err = tx.Exec("INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", passwordSettingKey, hash); err != nil {
		return false, err
	}
	if _, err = tx.Exec("DELETE FROM sessions"); err != nil {
		return false, err
	}
	if err = tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}
