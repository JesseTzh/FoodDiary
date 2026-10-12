package main

import (
	"encoding/json"
	"github.com/go-chi/chi/v5"
	"net/http"
	"strings"
	"unicode/utf8"
)

type Recipe struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Category    string   `json:"category"`
	Description string   `json:"description"`
	Image       string   `json:"image"`
	Ingredients []string `json:"ingredients"`
	Steps       []string `json:"steps"`
	Favorite    bool     `json:"favorite"`
	Custom      bool     `json:"custom"`
}

func (a *App) kitchenRoutes(r chi.Router) {
	r.Get("/recipes", a.recipes)
	r.Post("/recipes", a.saveRecipe)
	r.Patch("/recipes/{id}/favorite", a.recipeFavorite)
	r.Patch("/entries/{id}/favorite", a.entryFavorite)
	r.Get("/profile", a.profile)
	r.Patch("/profile", a.saveProfile)
	r.Get("/groceries", a.groceries)
	r.Post("/groceries", a.addGrocery)
	r.Patch("/groceries/{id}", a.checkGrocery)
	r.Delete("/groceries/{id}", a.removeGrocery)
}
func (a *App) recipes(w http.ResponseWriter, r *http.Request) {
	rows, e := a.db.Query("SELECT id,title,category,description,image,ingredients_json,steps_json,favorite,custom FROM recipes ORDER BY custom DESC,rowid")
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer rows.Close()
	out := []Recipe{}
	for rows.Next() {
		var x Recipe
		var ij, sj string
		if e := rows.Scan(&x.ID, &x.Title, &x.Category, &x.Description, &x.Image, &ij, &sj, &x.Favorite, &x.Custom); e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		out = append(out, x)
	}
	writeJSON(w, 200, out)
}
func (a *App) saveRecipe(w http.ResponseWriter, r *http.Request) {
	var x Recipe
	if decode(r, &x) != nil || strings.TrimSpace(x.Title) == "" || utf8.RuneCountInString(x.Title) > 80 || len(x.Ingredients) > 100 || len(x.Steps) > 100 {
		errJSON(w, 400, "VALIDATION_ERROR", "请填写菜谱名称，食材和步骤各最多 100 项")
		return
	}
	x.ID = id()
	x.Custom = true
	x.Image = "tomato"
	ij, _ := json.Marshal(x.Ingredients)
	sj, _ := json.Marshal(x.Steps)
	if _, e := a.db.Exec("INSERT INTO recipes VALUES(?,?,?,?,?,?,?,?,?)", x.ID, x.Title, x.Category, x.Description, x.Image, ij, sj, x.Favorite, x.Custom); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	writeJSON(w, 201, x)
}
func (a *App) setFavorite(w http.ResponseWriter, r *http.Request, table string) {
	var body struct {
		Favorite bool `json:"favorite"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	clause := ""
	if table == "diary_entries" {
		clause = " AND deleted_at IS NULL"
	}
	result, e := a.db.Exec("UPDATE "+table+" SET favorite=? WHERE id=?"+clause, body.Favorite, chi.URLParam(r, "id"))
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	if n, _ := result.RowsAffected(); n == 0 {
		errJSON(w, 404, "NOT_FOUND", "未找到记录")
		return
	}
	writeJSON(w, 200, body)
}
func (a *App) recipeFavorite(w http.ResponseWriter, r *http.Request) { a.setFavorite(w, r, "recipes") }
func (a *App) entryFavorite(w http.ResponseWriter, r *http.Request) {
	a.setFavorite(w, r, "diary_entries")
}
func (a *App) profile(w http.ResponseWriter, r *http.Request) {
	var name, bio string
	var count, custom, favorites int
	a.db.QueryRow("SELECT value FROM app_settings WHERE key='profile_name'").Scan(&name)
	a.db.QueryRow("SELECT value FROM app_settings WHERE key='profile_bio'").Scan(&bio)
	a.db.QueryRow("SELECT count(*) FROM diary_entries WHERE deleted_at IS NULL").Scan(&count)
	a.db.QueryRow("SELECT count(*) FROM recipes WHERE custom=1").Scan(&custom)
	a.db.QueryRow("SELECT count(*) FROM recipes WHERE favorite=1").Scan(&favorites)
	writeJSON(w, 200, map[string]any{"name": name, "bio": bio, "entry_count": count, "recipe_count": custom, "favorite_count": favorites})
}
func (a *App) saveProfile(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
		Bio  string `json:"bio"`
	}
	if decode(r, &body) != nil || strings.TrimSpace(body.Name) == "" || utf8.RuneCountInString(body.Name) > 30 || utf8.RuneCountInString(body.Bio) > 100 {
		errJSON(w, 400, "VALIDATION_ERROR", "昵称最多 30 字，简介最多 100 字")
		return
	}
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer tx.Rollback()
	for k, v := range map[string]string{"profile_name": body.Name, "profile_bio": body.Bio} {
		if _, e = tx.Exec("INSERT INTO app_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", k, v); e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
	}
	if e = tx.Commit(); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	a.profile(w, r)
}
func (a *App) groceries(w http.ResponseWriter, r *http.Request) {
	rows, e := a.db.Query("SELECT id,name,checked FROM groceries ORDER BY rowid DESC")
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name string
		var checked bool
		rows.Scan(&id, &name, &checked)
		out = append(out, map[string]any{"id": id, "name": name, "checked": checked})
	}
	writeJSON(w, 200, out)
}
func (a *App) addGrocery(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
	}
	if decode(r, &body) != nil || strings.TrimSpace(body.Name) == "" || utf8.RuneCountInString(body.Name) > 80 {
		errJSON(w, 400, "VALIDATION_ERROR", "食材名称需为 1–80 字")
		return
	}
	key := id()
	if _, e := a.db.Exec("INSERT INTO groceries(id,name) VALUES(?,?)", key, body.Name); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	writeJSON(w, 201, map[string]any{"id": key, "name": body.Name, "checked": false})
}
func (a *App) checkGrocery(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Checked bool `json:"checked"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "invalid JSON")
		return
	}
	result, e := a.db.Exec("UPDATE groceries SET checked=? WHERE id=?", body.Checked, chi.URLParam(r, "id"))
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	if n, _ := result.RowsAffected(); n == 0 {
		errJSON(w, 404, "NOT_FOUND", "未找到食材")
		return
	}
	writeJSON(w, 200, body)
}
func (a *App) removeGrocery(w http.ResponseWriter, r *http.Request) {
	result, e := a.db.Exec("DELETE FROM groceries WHERE id=?", chi.URLParam(r, "id"))
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	if n, _ := result.RowsAffected(); n == 0 {
		errJSON(w, 404, "NOT_FOUND", "未找到食材")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
