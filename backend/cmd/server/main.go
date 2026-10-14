package main

import (
	"archive/zip"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	_ "github.com/mattn/go-sqlite3"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type Entry struct {
	// Kept for database migration compatibility; meal is no longer part of the API.
	Meal        string           `json:"-"`
	Mood        int              `json:"mood"`
	Favorite    bool             `json:"favorite"`
	ID          string           `json:"id"`
	CookedOn    string           `json:"cooked_on"`
	Title       string           `json:"title"`
	Category    string           `json:"category"`
	Duration    *int             `json:"duration_minutes,omitempty"`
	Difficulty  *int             `json:"difficulty,omitempty"`
	Rating      *int             `json:"rating,omitempty"`
	Ingredients []map[string]any `json:"ingredients"`
	Steps       []string         `json:"steps"`
	Tags        []string         `json:"tags"`
	Notes       string           `json:"notes"`
	CreatedAt   string           `json:"created_at"`
	UpdatedAt   string           `json:"updated_at"`
	Version     int              `json:"version"`
	Media       []Media          `json:"media,omitempty"`
	Dishes      []Dish           `json:"dishes,omitempty"`
	// 游客浏览：true 表示该记录开放给未登录的游客查看
	SharedWithGuests bool `json:"shared_with_guests"`
}
type Dish struct {
	ID     string   `json:"id"`
	Title  string   `json:"title"`
	Notes  string   `json:"notes,omitempty"`
	Tags   []string `json:"tags,omitempty"`
	Rating int      `json:"rating,omitempty"`
}
type Media struct {
	ID         string  `json:"id"`
	EntryID    string  `json:"entry_id"`
	Mime       string  `json:"mime"`
	Size       int64   `json:"size_bytes"`
	URL        string  `json:"url"`
	RecipeID   string  `json:"recipe_id,omitempty"`
	CropX      float64 `json:"crop_x,omitempty"`
	CropY      float64 `json:"crop_y,omitempty"`
	CropWidth  float64 `json:"crop_width,omitempty"`
	CropHeight float64 `json:"crop_height,omitempty"`
}
type App struct {
	db      *sql.DB
	data    string
	jwtKey  []byte
	limiter *ipLimiter
	// 跨源白名单（FOODDIARY_CORS_ORIGINS），为空时禁用 CORS，行为与原来一致
	corsOrigins []string
}

// cors 为 Flutter Web 等跨源开发前端放行带凭据的请求；
// 仅当白名单非空时由 routes() 挂载，生产同源托管不受影响。
func (a *App) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && a.corsAllowed(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Expose-Headers", "X-Session-Token, X-Refresh-Token")
			if r.Method == http.MethodOptions {
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-FoodDiary-Client")
				w.Header().Set("Access-Control-Expose-Headers", "X-Session-Token, X-Refresh-Token")
				w.Header().Set("Access-Control-Max-Age", "86400")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) corsAllowed(origin string) bool {
	for _, o := range a.corsOrigins {
		if strings.EqualFold(strings.TrimSpace(o), origin) {
			return true
		}
	}
	return false
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }
func id() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b[:])
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"data": v, "error": nil})
}
func errJSON(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"data": nil, "error": map[string]any{"code": code, "message": msg}})
}
func decode(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(v)
}

const (
	sessionCookieName  = "fooddiary_session"
	passwordSettingKey = "auth_password_hash"
	pbkdf2Iterations   = 600000
)

func hashPassword(password string) (string, error) {
	salt := make([]byte, 16)
	if _, e := rand.Read(salt); e != nil {
		return "", e
	}
	h, e := pbkdf2.Key(sha256.New, password, salt, pbkdf2Iterations, 32)
	if e != nil {
		return "", e
	}
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iterations, hex.EncodeToString(salt), hex.EncodeToString(h)), nil
}

func verifyPassword(stored, password string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	iter, e := strconv.Atoi(parts[1])
	if e != nil || iter < 1 {
		return false
	}
	salt, e := hex.DecodeString(parts[2])
	if e != nil {
		return false
	}
	want, e := hex.DecodeString(parts[3])
	if e != nil || len(want) == 0 {
		return false
	}
	got, e := pbkdf2.Key(sha256.New, password, salt, iter, len(want))
	if e != nil {
		return false
	}
	return subtle.ConstantTimeCompare(got, want) == 1
}

type ipLimiter struct {
	mu    sync.Mutex
	fails map[string]*attempt
}
type attempt struct {
	count int
	until time.Time
}

func newIPLimiter() *ipLimiter { return &ipLimiter{fails: map[string]*attempt{}} }

func (l *ipLimiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	a, ok := l.fails[ip]
	return ok && a.count >= 10 && time.Now().Before(a.until)
}
func (l *ipLimiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	a := l.fails[ip]
	if a == nil {
		if len(l.fails) > 1000 {
			l.fails = map[string]*attempt{}
		}
		a = &attempt{}
		l.fails[ip] = a
	}
	a.count++
	if a.count >= 10 {
		a.until = time.Now().Add(15 * time.Minute)
	}
}
func (l *ipLimiter) reset(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.fails, ip)
}

func clientIP(r *http.Request) string {
	if host, _, e := net.SplitHostPort(r.RemoteAddr); e == nil {
		return host
	}
	return r.RemoteAddr
}

func (a *App) passwordHash() string {
	var h string
	a.db.QueryRow("SELECT value FROM app_settings WHERE key=?", passwordSettingKey).Scan(&h)
	return h
}
func (a *App) setPasswordHash(hash string) error {
	_, e := a.db.Exec("INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", passwordSettingKey, hash)
	return e
}

func (a *App) authStatus(w http.ResponseWriter, r *http.Request) {
	authed := a.authed(r)
	var guestCount int
	a.db.QueryRow("SELECT COUNT(*) FROM diary_entries WHERE deleted_at IS NULL AND shared_with_guests=1").Scan(&guestCount)
	writeJSON(w, 200, map[string]any{"auth_required": a.passwordHash() != "", "authenticated": authed, "guest_shared_count": guestCount})
}

func (a *App) authSetup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	if len(body.Password) < 6 || len(body.Password) > 128 {
		errJSON(w, 400, "VALIDATION_ERROR", "password must be 6-128 chars")
		return
	}
	if a.passwordHash() != "" {
		errJSON(w, 409, "CONFLICT", "password already configured")
		return
	}
	h, e := hashPassword(body.Password)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	result, e := a.db.Exec("INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", passwordSettingKey, h)
	if e != nil {
		errJSON(w, 500, "DB", "could not configure password")
		return
	}
	if n, _ := result.RowsAffected(); n != 1 {
		errJSON(w, 409, "CONFLICT", "password already configured")
		return
	}
	if e := a.newSession(w, r); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (a *App) authLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if a.limiter.blocked(ip) {
		errJSON(w, 429, "TOO_MANY_ATTEMPTS", "too many attempts, try again later")
		return
	}
	var body struct {
		Password string `json:"password"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	if len(body.Password) > 128 {
		a.limiter.fail(ip)
		errJSON(w, 401, "UNAUTHORIZED", "wrong password")
		return
	}
	stored := a.passwordHash()
	if stored == "" {
		errJSON(w, 400, "NO_PASSWORD", "password not configured yet")
		return
	}
	if !verifyPassword(stored, body.Password) {
		a.limiter.fail(ip)
		errJSON(w, 401, "UNAUTHORIZED", "wrong password")
		return
	}
	a.limiter.reset(ip)
	if e := a.newSession(w, r); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (a *App) entries(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	args := []any{}
	where := []string{"deleted_at IS NULL"}
	if x := q.Get("from"); x != "" {
		where = append(where, "cooked_on >= ?")
		args = append(args, x)
	}
	if x := q.Get("to"); x != "" {
		where = append(where, "cooked_on <= ?")
		args = append(args, x)
	}
	if x := q.Get("q"); x != "" {
		where = append(where, "title LIKE ?")
		args = append(args, "%"+x+"%")
	}
	if x := q.Get("category"); x != "" {
		where = append(where, "category = ?")
		args = append(args, x)
	}
	if q.Get("favorite") == "true" {
		where = append(where, "favorite=1")
	}
	if x := q.Get("month"); x != "" {
		where = append(where, "substr(cooked_on,1,7)=?")
		args = append(args, x)
	}
	if x := q.Get("rating"); x != "" {
		where = append(where, "rating = ?")
		args = append(args, x)
	}
	rows, e := a.db.Query("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version,shared_with_guests,meal,mood,favorite FROM diary_entries WHERE "+strings.Join(where, " AND ")+" ORDER BY cooked_on DESC,created_at DESC", args...)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer rows.Close()
	out := []Entry{}
	for rows.Next() {
		var x Entry
		var ij, sj string
		var shared int
		if e := rows.Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version, &shared, &x.Meal, &x.Mood, &x.Favorite); e != nil {
			continue
		}
		x.SharedWithGuests = shared == 1
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		x.Tags = a.tags(x.ID)
		x.Media = a.media(x.ID)
		x.Dishes = a.entryDishes(x.ID, x.Title)
		out = append(out, x)
	}
	writeJSON(w, 200, map[string]any{"items": out, "total": len(out)})
}
func (a *App) tags(entry string) []string {
	rows, _ := a.db.Query("SELECT tag FROM entry_tags WHERE entry_id=? ORDER BY tag", entry)
	defer func() {
		if rows != nil {
			rows.Close()
		}
	}()
	o := []string{}
	if rows != nil {
		for rows.Next() {
			var t string
			rows.Scan(&t)
			o = append(o, t)
		}
	}
	return o
}
func (a *App) media(entry string) []Media {
	rows, _ := a.db.Query("SELECT id,entry_id,mime,size_bytes,COALESCE(recipe_id,''),crop_x,crop_y,crop_width,crop_height FROM media_assets WHERE entry_id=? ORDER BY created_at", entry)
	defer func() {
		if rows != nil {
			rows.Close()
		}
	}()
	o := []Media{}
	if rows != nil {
		for rows.Next() {
			var m Media
			rows.Scan(&m.ID, &m.EntryID, &m.Mime, &m.Size, &m.RecipeID, &m.CropX, &m.CropY, &m.CropWidth, &m.CropHeight)
			m.URL = "/media/assets/" + m.ID + "/original"
			o = append(o, m)
		}
	}
	return o
}
func (a *App) entryDishes(entry, fallback string) []Dish {
	var raw string
	if a.db.QueryRow("SELECT dishes_json FROM diary_entries WHERE id=?", entry).Scan(&raw) == nil {
		var dishes []Dish
		if json.Unmarshal([]byte(raw), &dishes) == nil && len(dishes) > 0 {
			return dishes
		}
	}
	var dish Dish
	if a.db.QueryRow("SELECT id,title FROM recipes WHERE title=? COLLATE NOCASE", fallback).Scan(&dish.ID, &dish.Title) == nil {
		return []Dish{dish}
	}
	return []Dish{{Title: fallback}}
}
func (a *App) get(w http.ResponseWriter, r *http.Request) {
	var x Entry
	id := chi.URLParam(r, "id")
	var ij, sj string
	var shared int
	if e := a.db.QueryRow("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version,shared_with_guests,meal,mood,favorite FROM diary_entries WHERE id=? AND deleted_at IS NULL", id).Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version, &shared, &x.Meal, &x.Mood, &x.Favorite); e != nil {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	x.SharedWithGuests = shared == 1
	json.Unmarshal([]byte(ij), &x.Ingredients)
	json.Unmarshal([]byte(sj), &x.Steps)
	x.Tags = a.tags(id)
	x.Media = a.media(id)
	x.Dishes = a.entryDishes(id, x.Title)
	writeJSON(w, 200, x)
}

// 切换某条记录对游客的开放状态（仅登录用户）。
func (a *App) guestShare(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	res, e := a.db.Exec("UPDATE diary_entries SET shared_with_guests=? WHERE id=? AND deleted_at IS NULL", map[bool]int{true: 1, false: 0}[body.Enabled], id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	writeJSON(w, 200, map[string]any{"id": id, "shared_with_guests": body.Enabled})
}

// 游客（未登录）可见的记录列表：只返回开放且未删除的记录。
func (a *App) guestEntries(w http.ResponseWriter, r *http.Request) {
	rows, e := a.db.Query("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version FROM diary_entries WHERE deleted_at IS NULL AND shared_with_guests=1 ORDER BY cooked_on DESC,created_at DESC")
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer rows.Close()
	out := []Entry{}
	for rows.Next() {
		var x Entry
		var ij, sj string
		if e := rows.Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version); e != nil {
			continue
		}
		x.SharedWithGuests = true
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		x.Tags = a.tags(x.ID)
		x.Media = a.media(x.ID)
		out = append(out, x)
	}
	writeJSON(w, 200, map[string]any{"items": out, "total": len(out)})
}

// 游客查看单条开放记录；未开放的记录一律 404，不暴露存在性。
func (a *App) guestGet(w http.ResponseWriter, r *http.Request) {
	var x Entry
	id := chi.URLParam(r, "id")
	var ij, sj string
	if e := a.db.QueryRow("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version FROM diary_entries WHERE id=? AND deleted_at IS NULL AND shared_with_guests=1", id).Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version); e != nil {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	x.SharedWithGuests = true
	json.Unmarshal([]byte(ij), &x.Ingredients)
	json.Unmarshal([]byte(sj), &x.Steps)
	x.Tags = a.tags(id)
	x.Media = a.media(id)
	x.Dishes = a.entryDishes(id, x.Title)
	writeJSON(w, 200, x)
}
func valid(x Entry) error {
	if len(strings.TrimSpace(x.Title)) < 1 || utf8.RuneCountInString(x.Title) > 80 {
		return fmt.Errorf("title must be 1-80 chars")
	}
	if _, e := time.Parse("2006-01-02", x.CookedOn); e != nil {
		return fmt.Errorf("cooked_on must be YYYY-MM-DD")
	}
	if x.Rating != nil && (*x.Rating < 1 || *x.Rating > 5) {
		return fmt.Errorf("rating must be 1-5")
	}
	if x.Difficulty != nil && (*x.Difficulty < 1 || *x.Difficulty > 5) {
		return fmt.Errorf("difficulty must be 1-5")
	}
	if utf8.RuneCountInString(x.Notes) > 200 {
		return fmt.Errorf("心得最多 200 字")
	}
	if x.Mood < 0 || x.Mood > 4 {
		return fmt.Errorf("心情无效")
	}
	if x.Meal == "" {
		x.Meal = "晚餐"
	}
	if x.Meal != "" && x.Meal != "早餐" && x.Meal != "午餐" && x.Meal != "晚餐" && x.Meal != "下午茶" {
		return fmt.Errorf("餐次无效")
	}
	if len(x.Tags) > 12 {
		return fmt.Errorf("标签最多 12 个")
	}
	return nil
}
func (a *App) create(w http.ResponseWriter, r *http.Request) { a.saveEntry(w, r, false) }
func (a *App) update(w http.ResponseWriter, r *http.Request) { a.saveEntry(w, r, true) }
func (a *App) saveEntry(w http.ResponseWriter, r *http.Request, editing bool) {
	var x Entry
	if decode(r, &x) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	if e := valid(x); e != nil {
		errJSON(w, 400, "VALIDATION_ERROR", e.Error())
		return
	}
	x.Title = strings.TrimSpace(x.Title)
	if x.Meal == "" {
		x.Meal = "晚餐"
	}
	if x.Category == "" {
		x.Category = "家常菜"
	}
	if x.Ingredients == nil {
		x.Ingredients = []map[string]any{}
	}
	if len(x.Dishes) == 0 {
		x.Dishes = []Dish{{Title: x.Title}}
	}
	if len(x.Dishes) > 20 {
		errJSON(w, 400, "VALIDATION_ERROR", "一篇日记最多添加 20 道菜")
		return
	}
	for i := range x.Dishes {
		x.Dishes[i].Title = strings.TrimSpace(x.Dishes[i].Title)
		if x.Dishes[i].Title == "" || utf8.RuneCountInString(x.Dishes[i].Title) > 80 {
			errJSON(w, 400, "VALIDATION_ERROR", "菜名需为 1 到 80 个字")
			return
		}
	}
	x.Title = x.Dishes[0].Title
	if x.Steps == nil {
		x.Steps = []string{}
	}
	ij, _ := json.Marshal(x.Ingredients)
	sj, _ := json.Marshal(x.Steps)
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer tx.Rollback()
	x.UpdatedAt = now()
	if editing {
		x.ID = chi.URLParam(r, "id")
		var ver int
		if e = tx.QueryRow("SELECT version,created_at FROM diary_entries WHERE id=? AND deleted_at IS NULL", x.ID).Scan(&ver, &x.CreatedAt); e != nil {
			errJSON(w, 404, "NOT_FOUND", "entry not found")
			return
		}
		if x.Version != ver {
			errJSON(w, 409, "CONFLICT", "这份日记已被更新，请重新打开后编辑")
			return
		}
		x.Version = ver + 1
		var result sql.Result
		result, e = tx.Exec("UPDATE diary_entries SET cooked_on=?,title=?,category=?,duration_minutes=?,difficulty=?,rating=?,ingredients_json=?,steps_json=?,notes=?,updated_at=?,version=?,meal=?,mood=?,favorite=? WHERE id=? AND version=? AND deleted_at IS NULL", x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.UpdatedAt, x.Version, x.Meal, x.Mood, x.Favorite, x.ID, ver)
		if e == nil {
			if n, _ := result.RowsAffected(); n == 0 {
				errJSON(w, 409, "CONFLICT", "这份日记已被更新")
				return
			}
		}
		if e == nil {
			_, e = tx.Exec("DELETE FROM entry_tags WHERE entry_id=?", x.ID)
		}
	} else {
		x.ID = id()
		x.CreatedAt = x.UpdatedAt
		x.Version = 1
		_, e = tx.Exec("INSERT INTO diary_entries(id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version,meal,mood,favorite) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", x.ID, x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.CreatedAt, x.UpdatedAt, x.Version, x.Meal, x.Mood, x.Favorite)
	}
	if e == nil {
		for i := range x.Dishes {
			d := &x.Dishes[i]
			if d.ID != "" {
				var title string
				if tx.QueryRow("SELECT title FROM recipes WHERE id=?", d.ID).Scan(&title) == nil {
					d.Title = title
				} else {
					d.ID = ""
				}
			}
			if d.ID == "" && tx.QueryRow("SELECT id FROM recipes WHERE title=? COLLATE NOCASE", d.Title).Scan(&d.ID) != nil {
				d.ID = id()
				_, e = tx.Exec("INSERT INTO recipes(id,title,category,description,image,ingredients_json,steps_json,favorite,custom,cover_media_id) VALUES(?,?,?,'','','[]','[]',0,1,'')", d.ID, d.Title, x.Category)
			}
			if e != nil {
				break
			}
		}
	}
	dishesJSON, _ := json.Marshal(x.Dishes)
	if e == nil {
		_, e = tx.Exec("UPDATE diary_entries SET dishes_json=? WHERE id=?", dishesJSON, x.ID)
	}
	if e == nil {
		for _, t := range x.Tags {
			if _, e = tx.Exec("INSERT OR IGNORE INTO entry_tags(entry_id,tag) VALUES(?,?)", x.ID, t); e != nil {
				break
			}
		}
	}
	if e == nil {
		_, e = tx.Exec("INSERT INTO sync_changes(entity_type,entity_id,operation,version,changed_at) VALUES('entry',?,'upsert',?,?)", x.ID, x.Version, x.UpdatedAt)
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	x.Media = a.media(x.ID)
	x.Dishes = a.entryDishes(x.ID, x.Title)
	status := 201
	if editing {
		status = 200
	}
	writeJSON(w, status, x)
}
func (a *App) delete(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer tx.Rollback()
	rows, e := tx.Query("SELECT id FROM media_assets WHERE entry_id=?", id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	var media []string
	for rows.Next() {
		var mid string
		if rows.Scan(&mid) == nil {
			media = append(media, mid)
		}
	}
	rows.Close()
	res, e := tx.Exec("DELETE FROM diary_entries WHERE id=?", id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	for _, mid := range media {
		if _, e = tx.Exec("DELETE FROM media_assets WHERE id=?", mid); e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
	}
	if e = tx.Commit(); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	for _, mid := range media {
		_ = os.Remove(filepath.Join(a.data, "media", mid))
	}
	writeJSON(w, 200, map[string]any{"id": id})
}
func (a *App) copy(w http.ResponseWriter, r *http.Request) {
	id0 := chi.URLParam(r, "id")
	var x Entry
	var ij, sj string
	if e := a.db.QueryRow("SELECT cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes FROM diary_entries WHERE id=? AND deleted_at IS NULL", id0).Scan(&x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes); e != nil {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	json.Unmarshal([]byte(ij), &x.Ingredients)
	json.Unmarshal([]byte(sj), &x.Steps)
	x.Tags = a.tags(id0)
	x.CookedOn = time.Now().Format("2006-01-02")
	if x.Meal == "" {
		x.Meal = "晚餐"
	}
	x.ID = id()
	x.CreatedAt = now()
	x.UpdatedAt = x.CreatedAt
	x.Version = 1
	tx, _ := a.db.Begin()
	_, e := tx.Exec("INSERT INTO diary_entries(id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version,meal,mood,favorite) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", x.ID, x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.CreatedAt, x.UpdatedAt, x.Version, x.Meal, x.Mood, x.Favorite)
	if e != nil {
		tx.Rollback()
		errJSON(w, 500, "DB", e.Error())
		return
	}
	for _, t := range x.Tags {
		tx.Exec("INSERT OR IGNORE INTO entry_tags(entry_id,tag) VALUES(?,?)", x.ID, t)
	}
	tx.Exec("INSERT INTO sync_changes(entity_type,entity_id,operation,version,changed_at) VALUES('entry',?,'upsert',?,?)", x.ID, x.Version, x.UpdatedAt)
	tx.Commit()
	writeJSON(w, 201, x)
}
func (a *App) stats(w http.ResponseWriter, r *http.Request) {
	from, to := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	if from == "" {
		from = time.Now().Format("2006-01-01")[:8] + "01"
	}
	if to == "" {
		to = time.Now().Format("2006-01-02")
	}
	var days, count, avg float64
	a.db.QueryRow("SELECT COUNT(DISTINCT cooked_on),COUNT(*),COALESCE(AVG(rating),0) FROM diary_entries WHERE deleted_at IS NULL AND cooked_on BETWEEN ? AND ?", from, to).Scan(&days, &count, &avg)
	var cat string
	a.db.QueryRow("SELECT category FROM diary_entries WHERE deleted_at IS NULL AND cooked_on BETWEEN ? AND ? GROUP BY category ORDER BY COUNT(*) DESC LIMIT 1", from, to).Scan(&cat)
	writeJSON(w, 200, map[string]any{"cooking_days": int(days), "dish_count": int(count), "average_rating": avg, "top_category": cat, "streak": int(days)})
}
func (a *App) upload(w http.ResponseWriter, r *http.Request) {
	entry := chi.URLParam(r, "id")
	recipe := strings.TrimSpace(r.URL.Query().Get("recipe_id"))
	directRecipe := chi.URLParam(r, "recipeID")
	if directRecipe != "" {
		entry, recipe = "", directRecipe
	}
	r.Body = http.MaxBytesReader(w, r.Body, 21<<20)
	if e := r.ParseMultipartForm(2 << 20); e != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "单张照片不能超过 20 MB")
		return
	}
	defer r.MultipartForm.RemoveAll()
	parseCrop := func(name string, fallback float64) float64 {
		v, e := strconv.ParseFloat(r.FormValue(name), 64)
		if e != nil {
			return fallback
		}
		return v
	}
	cropX, cropY := parseCrop("crop_x", 0), parseCrop("crop_y", 0)
	cropW, cropH := parseCrop("crop_width", 1), parseCrop("crop_height", 1)
	if cropX < 0 {
		cropX = 0
	}
	if cropY < 0 {
		cropY = 0
	}
	if cropW <= 0 {
		cropW = 1
	}
	if cropH <= 0 {
		cropH = 1
	}
	if cropX+cropW > 1 {
		cropX = 1 - cropW
	}
	if cropY+cropH > 1 {
		cropY = 1 - cropH
	}
	f, h, e := r.FormFile("file")
	if e != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "请选择照片")
		return
	}
	defer f.Close()
	raw, e := io.ReadAll(io.LimitReader(f, (20<<20)+1))
	if e != nil || len(raw) > 20<<20 {
		errJSON(w, 400, "VALIDATION_ERROR", "单张照片不能超过 20 MB")
		return
	}
	mime := http.DetectContentType(raw)
	if mime != "image/jpeg" && mime != "image/png" && mime != "image/webp" && mime != "image/gif" {
		errJSON(w, 400, "VALIDATION_ERROR", "照片仅支持 JPEG、PNG、WebP、GIF")
		return
	}
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer tx.Rollback()
	var count int
	if entry != "" {
		if e = tx.QueryRow("SELECT count(*) FROM diary_entries WHERE id=? AND deleted_at IS NULL", entry).Scan(&count); e != nil || count == 0 {
			errJSON(w, 404, "NOT_FOUND", "entry not found")
			return
		}
	}
	if directRecipe != "" {
		if e = tx.QueryRow("SELECT count(*) FROM recipes WHERE id=?", recipe).Scan(&count); e != nil || count == 0 {
			errJSON(w, 404, "NOT_FOUND", "未找到菜谱")
			return
		}
	}
	if recipe != "" && entry != "" {
		var raw string
		if e = tx.QueryRow("SELECT dishes_json FROM diary_entries WHERE id=?", entry).Scan(&raw); e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
		var dishes []Dish
		json.Unmarshal([]byte(raw), &dishes)
		found := false
		for _, d := range dishes {
			if d.ID == recipe {
				found = true
				break
			}
		}
		if !found {
			errJSON(w, 400, "VALIDATION_ERROR", "该菜谱不属于这篇日记")
			return
		}
	}
	ownerClause, ownerID := "entry_id=?", entry
	if directRecipe != "" {
		ownerClause, ownerID = "recipe_id=? AND entry_id IS NULL", recipe
	}
	if e = tx.QueryRow("SELECT count(*) FROM media_assets WHERE "+ownerClause, ownerID).Scan(&count); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	sum := sha256.Sum256(raw)
	var existing string
	if e = tx.QueryRow("SELECT id FROM media_assets WHERE "+ownerClause+" AND sha256=? LIMIT 1", ownerID, hex.EncodeToString(sum[:])).Scan(&existing); e == nil {
		if recipe != "" {
			_, e = tx.Exec("UPDATE media_assets SET recipe_id=? WHERE id=?", recipe, existing)
			if e == nil {
				_, e = tx.Exec("UPDATE recipes SET cover_media_id=? WHERE id=?", existing, recipe)
			}
		}
		if e == nil {
			e = tx.Commit()
		}
		if e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
		writeJSON(w, 200, Media{ID: existing, EntryID: entry, RecipeID: recipe, URL: "/media/assets/" + existing + "/original", CropX: cropX, CropY: cropY, CropWidth: cropW, CropHeight: cropH})
		return
	}
	if count >= 9 {
		errJSON(w, 400, "VALIDATION_ERROR", "最多可以保存 9 张照片")
		return
	}
	if e = os.MkdirAll(filepath.Join(a.data, "media"), 0755); e != nil {
		errJSON(w, 500, "MEDIA", e.Error())
		return
	}
	mid := id()
	dst := filepath.Join(a.data, "media", mid)
	if e = os.WriteFile(dst, raw, 0600); e != nil {
		errJSON(w, 500, "MEDIA", e.Error())
		return
	}
	_, e = tx.Exec("INSERT INTO media_assets(id,entry_id,recipe_id,original_name,mime,size_bytes,sha256,created_at,crop_x,crop_y,crop_width,crop_height) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", mid, nullableString(entry), nullableString(recipe), h.Filename, mime, len(raw), hex.EncodeToString(sum[:]), now(), cropX, cropY, cropW, cropH)
	if e == nil && recipe != "" {
		_, e = tx.Exec("UPDATE recipes SET cover_media_id=? WHERE id=?", mid, recipe)
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		os.Remove(dst)
		errJSON(w, 500, "DB", e.Error())
		return
	}
	writeJSON(w, 201, Media{ID: mid, EntryID: entry, RecipeID: recipe, Mime: mime, Size: int64(len(raw)), URL: "/media/assets/" + mid + "/original", CropX: cropX, CropY: cropY, CropWidth: cropW, CropHeight: cropH})
}
func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// 已开放给游客的记录，其照片允许未登录访问；其余仍要求有效会话。
func (a *App) mediaFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !a.mediaShared(id) && !a.authed(r) {
		errJSON(w, 401, "UNAUTHORIZED", "authentication required")
		return
	}
	var mime string
	if e := a.db.QueryRow("SELECT m.mime FROM media_assets m LEFT JOIN diary_entries e ON e.id=m.entry_id WHERE m.id=? AND ((m.entry_id IS NOT NULL AND e.deleted_at IS NULL) OR (m.entry_id IS NULL AND m.recipe_id IS NOT NULL))", id).Scan(&mime); e != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	http.ServeFile(w, r, filepath.Join(a.data, "media", id))
}

func (a *App) mediaShared(mediaID string) bool {
	var shared int
	if a.db.QueryRow("SELECT e.shared_with_guests FROM media_assets m JOIN diary_entries e ON e.id=m.entry_id WHERE m.id=? AND e.deleted_at IS NULL", mediaID).Scan(&shared) != nil {
		return false
	}
	return shared == 1
}
func (a *App) export(w http.ResponseWriter, r *http.Request) {
	format := r.URL.Query().Get("format")
	rows, _ := a.db.Query("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version FROM diary_entries WHERE deleted_at IS NULL ORDER BY cooked_on")
	defer rows.Close()
	all := []Entry{}
	for rows.Next() {
		var x Entry
		var ij, sj string
		rows.Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version)
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		x.Tags = a.tags(x.ID)
		all = append(all, x)
	}
	data, _ := json.MarshalIndent(map[string]any{"version": 1, "exported_at": now(), "entries": all}, "", "  ")
	if format != "zip" {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Disposition", "attachment; filename=fooddiary.json")
		w.Write(data)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", "attachment; filename=fooddiary.zip")
	z := zip.NewWriter(w)
	f, _ := z.Create("fooddiary.json")
	f.Write(data)
	z.Close()
}

// 按文件名顺序执行未应用过的迁移；已应用的记录在 schema_migrations 中，避免重放
// （如 ALTER TABLE 这类非幂等语句）。
func loadMigrations(db *sql.DB, dir string) error {
	if _, e := db.Exec("CREATE TABLE IF NOT EXISTS schema_migrations(version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"); e != nil {
		return e
	}
	files, e := filepath.Glob(filepath.Join(dir, "*.up.sql"))
	if e != nil || len(files) == 0 {
		return fmt.Errorf("no migration files found in %s", dir)
	}
	sort.Strings(files)
	for _, f := range files {
		version := filepath.Base(f)
		var applied int
		if e := db.QueryRow("SELECT COUNT(*) FROM schema_migrations WHERE version=?", version).Scan(&applied); e != nil {
			return e
		}
		if applied > 0 {
			continue
		}
		sqlBytes, e := os.ReadFile(f)
		if e != nil {
			return e
		}
		if _, e := db.Exec(string(sqlBytes)); e != nil {
			return fmt.Errorf("%s: %w", f, e)
		}
		if _, e := db.Exec("INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)", version, now()); e != nil {
			return fmt.Errorf("%s: %w", f, e)
		}
	}
	return nil
}

func routes(a *App) http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.Logger, middleware.Recoverer, a.protectBrowserWrites)
	if len(a.corsOrigins) > 0 {
		r.Use(a.cors)
	}
	r.Get("/health/live", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	r.Get("/health/ready", func(w http.ResponseWriter, r *http.Request) {
		if a.db.Ping() != nil {
			errJSON(w, 503, "DB", "unavailable")
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/auth/status", a.authStatus)
		r.Post("/auth/setup", a.authSetup)
		r.Post("/auth/login", a.authLogin)
		r.Post("/auth/refresh", a.authRefresh)
		r.Post("/auth/logout", a.authLogout)
		// 游客浏览：公开只读接口，仅暴露标记为开放的记录
		r.Get("/guest/entries", a.guestEntries)
		r.Get("/guest/entries/{id}", a.guestGet)
		r.Group(func(r chi.Router) {
			r.Use(a.requireAuth)
			r.Get("/entries", a.entries)
			r.Post("/entries", a.create)
			r.Get("/entries/{id}", a.get)
			r.Patch("/entries/{id}", a.update)
			r.Delete("/entries/{id}", a.delete)
			r.Post("/entries/{id}/copy", a.copy)
			r.Post("/entries/{id}/media", a.upload)
			r.Post("/entries/{id}/guest-share", a.guestShare)
			r.Get("/stats", a.stats)
			a.kitchenRoutes(r)
			r.Get("/export", a.export)
			r.Get("/tags", func(w http.ResponseWriter, r *http.Request) {
				rows, _ := a.db.Query("SELECT DISTINCT tag FROM entry_tags ORDER BY tag")
				defer rows.Close()
				o := []string{}
				for rows.Next() {
					var t string
					rows.Scan(&t)
					o = append(o, t)
				}
				writeJSON(w, 200, o)
			})
		})
	})
	r.Get("/media/assets/{id}/{variant}", a.mediaFile)
	frontend := os.Getenv("FOODDIARY_FRONTEND_DIR")
	if frontend == "" {
		frontend = "frontend/build/web"
	}
	r.Handle("/*", http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if strings.HasPrefix(req.URL.Path, "/api/") || strings.HasPrefix(req.URL.Path, "/media/") {
			http.NotFound(w, req)
			return
		}
		if req.URL.Path == "/sw.js" || req.URL.Path == "/index.html" || req.URL.Path == "/flutter_bootstrap.js" {
			w.Header().Set("Cache-Control", "no-cache")
		}
		p := filepath.Join(frontend, filepath.Clean("/"+req.URL.Path))
		if req.URL.Path == "/" || filepath.Ext(p) == "" {
			p = filepath.Join(frontend, "index.html")
		}
		if _, e := os.Stat(p); e != nil {
			http.NotFound(w, req)
			return
		}
		http.ServeFile(w, req, p)
	}))
	return r
}

func main() {
	addr := os.Getenv("FOODDIARY_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	data := os.Getenv("FOODDIARY_DATA_DIR")
	if data == "" {
		data = "./data"
	}
	os.MkdirAll(data, 0755)
	db, e := sql.Open("sqlite3", filepath.Join(data, "app.db")+"?_foreign_keys=on&_busy_timeout=5000&_journal_mode=WAL&_txlock=immediate")
	if e != nil {
		log.Fatal(e)
	}
	db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000")
	if e := loadMigrations(db, "backend/migrations"); e != nil {
		log.Fatal(e)
	}
	key, e := loadJWTKey(data)
	if e != nil {
		log.Fatal(e)
	}
	a := &App{db: db, data: data, jwtKey: key, limiter: newIPLimiter()}
	if v := os.Getenv("FOODDIARY_CORS_ORIGINS"); v != "" {
		for _, o := range strings.Split(v, ",") {
			if o = strings.TrimSpace(o); o != "" {
				a.corsOrigins = append(a.corsOrigins, o)
			}
		}
	}
	if pw := os.Getenv("FOODDIARY_PASSWORD"); pw != "" {
		if len(pw) < 6 || len(pw) > 128 {
			log.Fatal("FOODDIARY_PASSWORD must be 6-128 chars")
		}
		changed, e := a.configurePassword(pw)
		if e != nil {
			log.Fatal(e)
		}
		if changed {
			log.Println("FOODDIARY_PASSWORD initialized or changed; all sessions revoked")
		} else {
			log.Println("FOODDIARY_PASSWORD unchanged; existing device sessions preserved")
		}
	}
	db.Exec("DELETE FROM sessions WHERE expires_at < ?", now())
	log.Printf("FoodDiary listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, routes(a)))
}
