package main

import (
	"archive/zip"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	_ "github.com/mattn/go-sqlite3"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Entry struct {
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
}
type Media struct {
	ID      string `json:"id"`
	EntryID string `json:"entry_id"`
	Mime    string `json:"mime"`
	Size    int64  `json:"size_bytes"`
	URL     string `json:"url"`
}
type App struct {
	db   *sql.DB
	data string
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }
func id() string  { return fmt.Sprintf("%d", time.Now().UnixNano()) }
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
	if x := q.Get("rating"); x != "" {
		where = append(where, "rating = ?")
		args = append(args, x)
	}
	rows, e := a.db.Query("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version FROM diary_entries WHERE "+strings.Join(where, " AND ")+" ORDER BY cooked_on DESC,created_at DESC", args...)
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
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		x.Tags = a.tags(x.ID)
		x.Media = a.media(x.ID)
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
	rows, _ := a.db.Query("SELECT id,entry_id,mime,size_bytes FROM media_assets WHERE entry_id=? ORDER BY created_at", entry)
	defer func() {
		if rows != nil {
			rows.Close()
		}
	}()
	o := []Media{}
	if rows != nil {
		for rows.Next() {
			var m Media
			rows.Scan(&m.ID, &m.EntryID, &m.Mime, &m.Size)
			m.URL = "/media/assets/" + m.ID + "/original"
			o = append(o, m)
		}
	}
	return o
}
func (a *App) get(w http.ResponseWriter, r *http.Request) {
	var x Entry
	id := chi.URLParam(r, "id")
	var ij, sj string
	if e := a.db.QueryRow("SELECT id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version FROM diary_entries WHERE id=? AND deleted_at IS NULL", id).Scan(&x.ID, &x.CookedOn, &x.Title, &x.Category, &x.Duration, &x.Difficulty, &x.Rating, &ij, &sj, &x.Notes, &x.CreatedAt, &x.UpdatedAt, &x.Version); e != nil {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	json.Unmarshal([]byte(ij), &x.Ingredients)
	json.Unmarshal([]byte(sj), &x.Steps)
	x.Tags = a.tags(id)
	x.Media = a.media(id)
	writeJSON(w, 200, x)
}
func valid(x Entry) error {
	if len(strings.TrimSpace(x.Title)) < 1 || len(x.Title) > 80 {
		return fmt.Errorf("title must be 1-80 chars")
	}
	if len(x.CookedOn) != 10 {
		return fmt.Errorf("cooked_on must be YYYY-MM-DD")
	}
	if x.Rating != nil && (*x.Rating < 1 || *x.Rating > 5) {
		return fmt.Errorf("rating must be 1-5")
	}
	if x.Difficulty != nil && (*x.Difficulty < 1 || *x.Difficulty > 5) {
		return fmt.Errorf("difficulty must be 1-5")
	}
	return nil
}
func (a *App) create(w http.ResponseWriter, r *http.Request) {
	var x Entry
	if decode(r, &x) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	if e := valid(x); e != nil {
		errJSON(w, 400, "VALIDATION_ERROR", e.Error())
		return
	}
	x.ID = id()
	x.CreatedAt = now()
	x.UpdatedAt = x.CreatedAt
	x.Version = 1
	if x.Ingredients == nil {
		x.Ingredients = []map[string]any{}
	}
	if x.Steps == nil {
		x.Steps = []string{}
	}
	ij, _ := json.Marshal(x.Ingredients)
	sj, _ := json.Marshal(x.Steps)
	tx, _ := a.db.Begin()
	_, e := tx.Exec("INSERT INTO diary_entries(id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", x.ID, x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.CreatedAt, x.UpdatedAt, x.Version)
	if e == nil {
		for _, t := range x.Tags {
			tx.Exec("INSERT OR IGNORE INTO entry_tags(entry_id,tag) VALUES(?,?)", x.ID, t)
		}
		tx.Exec("INSERT INTO sync_changes(entity_type,entity_id,operation,version,changed_at) VALUES('entry',?,'upsert',?,?)", x.ID, x.Version, x.UpdatedAt)
	}
	if e != nil {
		tx.Rollback()
		errJSON(w, 500, "DB", e.Error())
		return
	}
	tx.Commit()
	writeJSON(w, 201, x)
}
func (a *App) update(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var x Entry
	if decode(r, &x) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	if e := valid(x); e != nil {
		errJSON(w, 400, "VALIDATION_ERROR", e.Error())
		return
	}
	var ver int
	if e := a.db.QueryRow("SELECT version FROM diary_entries WHERE id=? AND deleted_at IS NULL", id).Scan(&ver); e != nil {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	if x.Version > 0 && x.Version != ver {
		errJSON(w, 409, "CONFLICT", "version conflict")
		return
	}
	x.ID = id
	x.Version = ver + 1
	x.UpdatedAt = now()
	ij, _ := json.Marshal(x.Ingredients)
	sj, _ := json.Marshal(x.Steps)
	_, e := a.db.Exec("UPDATE diary_entries SET cooked_on=?,title=?,category=?,duration_minutes=?,difficulty=?,rating=?,ingredients_json=?,steps_json=?,notes=?,updated_at=?,version=? WHERE id=?", x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.UpdatedAt, x.Version, id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	a.db.Exec("DELETE FROM entry_tags WHERE entry_id=?", id)
	for _, t := range x.Tags {
		a.db.Exec("INSERT OR IGNORE INTO entry_tags(entry_id,tag) VALUES(?,?)", id, t)
	}
	a.db.Exec("INSERT INTO sync_changes(entity_type,entity_id,operation,version,changed_at) VALUES('entry',?,'upsert',?,?)", id, x.Version, x.UpdatedAt)
	x.CreatedAt = ""
	writeJSON(w, 200, x)
}
func (a *App) delete(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	t := now()
	res, e := a.db.Exec("UPDATE diary_entries SET deleted_at=?,updated_at=?,version=version+1 WHERE id=? AND deleted_at IS NULL", t, t, id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		errJSON(w, 404, "NOT_FOUND", "entry not found")
		return
	}
	a.db.Exec("INSERT INTO sync_changes(entity_type,entity_id,operation,version,changed_at) SELECT 'entry',id,'delete',version,updated_at FROM diary_entries WHERE id=?", id)
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
	x.ID = id()
	x.CreatedAt = now()
	x.UpdatedAt = x.CreatedAt
	x.Version = 1
	tx, _ := a.db.Begin()
	_, e := tx.Exec("INSERT INTO diary_entries(id,cooked_on,title,category,duration_minutes,difficulty,rating,ingredients_json,steps_json,notes,created_at,updated_at,version) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", x.ID, x.CookedOn, x.Title, x.Category, x.Duration, x.Difficulty, x.Rating, ij, sj, x.Notes, x.CreatedAt, x.UpdatedAt, x.Version)
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
	if _, err := os.Stat(filepath.Join(a.data, "media")); err != nil {
		os.MkdirAll(filepath.Join(a.data, "media"), 0755)
	}
	if err := r.ParseMultipartForm(25 << 20); err != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid multipart")
		return
	}
	f, h, err := r.FormFile("file")
	if err != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "file is required")
		return
	}
	defer f.Close()
	mid := id()
	dst := filepath.Join(a.data, "media", mid)
	out, err := os.Create(dst)
	if err != nil {
		errJSON(w, 500, "MEDIA", err.Error())
		return
	}
	n, err := io.Copy(out, io.LimitReader(f, 20<<20))
	out.Close()
	if err != nil {
		errJSON(w, 500, "MEDIA", err.Error())
		return
	}
	mime := h.Header.Get("Content-Type")
	if mime == "" {
		mime = "application/octet-stream"
	}
	_, err = a.db.Exec("INSERT INTO media_assets(id,entry_id,original_name,mime,size_bytes,sha256,created_at) VALUES(?,?,?,?,?,?,?)", mid, entry, h.Filename, mime, n, "", now())
	if err != nil {
		errJSON(w, 500, "DB", err.Error())
		return
	}
	writeJSON(w, 201, Media{ID: mid, EntryID: entry, Mime: mime, Size: n, URL: "/media/assets/" + mid + "/original"})
}
func (a *App) mediaFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	http.ServeFile(w, r, filepath.Join(a.data, "media", id))
}
func (a *App) syncPush(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Operations []struct {
			ID      string `json:"id"`
			Payload Entry  `json:"payload"`
		} `json:"operations"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	results := []any{}
	for _, op := range body.Operations {
		if op.ID == "" {
			continue
		}
		results = append(results, map[string]any{"id": op.ID, "status": "accepted"})
	}
	writeJSON(w, 200, map[string]any{"results": results})
}
func (a *App) syncPull(w http.ResponseWriter, r *http.Request) {
	cur, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	rows, _ := a.db.Query("SELECT seq,entity_type,entity_id,operation,version,changed_at FROM sync_changes WHERE seq>? ORDER BY seq LIMIT 500", cur)
	defer rows.Close()
	out := []map[string]any{}
	next := cur
	for rows.Next() {
		var seq, ver int64
		var typ, eid, op, t string
		rows.Scan(&seq, &typ, &eid, &op, &ver, &t)
		out = append(out, map[string]any{"seq": seq, "entity_type": typ, "entity_id": eid, "operation": op, "version": ver, "changed_at": t})
		next = seq
	}
	writeJSON(w, 200, map[string]any{"changes": out, "cursor": next})
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
	db, e := sql.Open("sqlite3", filepath.Join(data, "app.db"))
	if e != nil {
		log.Fatal(e)
	}
	db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000")
	mig, _ := os.ReadFile("backend/migrations/000001_foundation.up.sql")
	if _, e = db.Exec(string(mig)); e != nil {
		log.Fatal(e)
	}
	a := &App{db: db, data: data}
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.Logger, middleware.Recoverer)
	r.Get("/health/live", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	r.Get("/health/ready", func(w http.ResponseWriter, r *http.Request) {
		if db.Ping() != nil {
			errJSON(w, 503, "DB", "unavailable")
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/entries", a.entries)
		r.Post("/entries", a.create)
		r.Get("/entries/{id}", a.get)
		r.Patch("/entries/{id}", a.update)
		r.Delete("/entries/{id}", a.delete)
		r.Post("/entries/{id}/copy", a.copy)
		r.Post("/entries/{id}/media", a.upload)
		r.Get("/stats", a.stats)
		r.Get("/sync", a.syncPull)
		r.Post("/sync/push", a.syncPush)
		r.Get("/export", a.export)
		r.Get("/tags", func(w http.ResponseWriter, r *http.Request) {
			rows, _ := db.Query("SELECT DISTINCT tag FROM entry_tags ORDER BY tag")
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
	r.Get("/media/assets/{id}/{variant}", a.mediaFile)
	frontend := os.Getenv("FOODDIARY_FRONTEND_DIR")
	if frontend == "" {
		frontend = "frontend/dist"
	}
	r.Handle("/*", http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		p := filepath.Join(frontend, filepath.Clean(req.URL.Path))
		if req.URL.Path == "/" || filepath.Ext(p) == "" {
			p = filepath.Join(frontend, "index.html")
		}
		if _, e := os.Stat(p); e != nil {
			http.NotFound(w, req)
			return
		}
		http.ServeFile(w, req, p)
	}))
	log.Printf("FoodDiary listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, r))
}

var _ = sha256.Sum256
var _ = hex.EncodeToString
var _ = strconv.Itoa
