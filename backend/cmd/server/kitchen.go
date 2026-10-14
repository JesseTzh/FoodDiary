package main

import (
	"encoding/json"
	"github.com/go-chi/chi/v5"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

type Recipe struct {
	ID           string   `json:"id"`
	Title        string   `json:"title"`
	Category     string   `json:"category"`
	Description  string   `json:"description"`
	Image        string   `json:"image"`
	Ingredients  []string `json:"ingredients"`
	Steps        []string `json:"steps"`
	Favorite     bool     `json:"favorite"`
	Custom       bool     `json:"custom"`
	CoverMediaID string   `json:"cover_media_id,omitempty"`
	Photos       []Media  `json:"photos,omitempty"`
}

func (a *App) kitchenRoutes(r chi.Router) {
	r.Get("/recipes", a.recipes)
	r.Post("/recipes", a.saveRecipe)
	r.Post("/recipes/{recipeID}/media", a.upload)
	r.Patch("/recipes/{id}", a.saveRecipe)
	r.Delete("/recipes/{id}", a.deleteRecipe)
	r.Patch("/recipes/{id}/favorite", a.recipeFavorite)
	r.Patch("/recipes/{id}/cover", a.recipeCover)
	r.Patch("/entries/{id}/favorite", a.entryFavorite)
	r.Get("/profile", a.profile)
	r.Patch("/profile", a.saveProfile)
}

func (a *App) deleteRecipe(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer tx.Rollback()
	rows, e := tx.Query("SELECT id,COALESCE(entry_id,'') FROM media_assets WHERE recipe_id=?", id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	var assets []struct{ id, entry string }
	for rows.Next() {
		var x struct{ id, entry string }
		if rows.Scan(&x.id, &x.entry) == nil {
			assets = append(assets, x)
		}
	}
	rows.Close()
	for _, asset := range assets {
		// A diary owns the bytes. Removing a recipe only removes its association;
		// orphan assets are physically removed as well.
		if asset.entry != "" {
			_, e = tx.Exec("UPDATE media_assets SET recipe_id=NULL WHERE id=?", asset.id)
		} else {
			_, e = tx.Exec("DELETE FROM media_assets WHERE id=?", asset.id)
		}
		if e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
	}
	res, e := tx.Exec("DELETE FROM recipes WHERE id=?", id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		errJSON(w, 404, "NOT_FOUND", "未找到菜谱")
		return
	}
	if e = tx.Commit(); e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	for _, asset := range assets {
		if asset.entry == "" {
			os.Remove(filepath.Join(a.data, "media", asset.id))
		}
	}
	writeJSON(w, 200, map[string]any{"id": id})
}
func (a *App) recipes(w http.ResponseWriter, r *http.Request) {
	rows, e := a.db.Query("SELECT id,title,category,description,image,ingredients_json,steps_json,favorite,custom,cover_media_id FROM recipes ORDER BY custom DESC,rowid")
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	defer rows.Close()
	out := []Recipe{}
	for rows.Next() {
		var x Recipe
		var ij, sj string
		if e := rows.Scan(&x.ID, &x.Title, &x.Category, &x.Description, &x.Image, &ij, &sj, &x.Favorite, &x.Custom, &x.CoverMediaID); e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
		json.Unmarshal([]byte(ij), &x.Ingredients)
		json.Unmarshal([]byte(sj), &x.Steps)
		x.Photos = a.recipeMedia(x.ID)
		out = append(out, x)
	}
	writeJSON(w, 200, out)
}
func (a *App) recipeMedia(recipe string) []Media {
	rows, _ := a.db.Query("SELECT id,COALESCE(entry_id,''),mime,size_bytes,crop_x,crop_y,crop_width,crop_height FROM media_assets WHERE recipe_id=? ORDER BY created_at", recipe)
	defer func() {
		if rows != nil {
			rows.Close()
		}
	}()
	out := []Media{}
	if rows != nil {
		for rows.Next() {
			var m Media
			rows.Scan(&m.ID, &m.EntryID, &m.Mime, &m.Size, &m.CropX, &m.CropY, &m.CropWidth, &m.CropHeight)
			m.RecipeID = recipe
			m.URL = "/media/assets/" + m.ID + "/original"
			out = append(out, m)
		}
	}
	return out
}
func (a *App) recipeCover(w http.ResponseWriter, r *http.Request) {
	var body struct {
		MediaID string `json:"media_id"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "请选择菜谱照片")
		return
	}
	id := chi.URLParam(r, "id")
	var count int
	if body.MediaID != "" {
		if e := a.db.QueryRow("SELECT count(*) FROM media_assets WHERE id=? AND recipe_id=?", body.MediaID, id).Scan(&count); e != nil || count == 0 {
			errJSON(w, 400, "VALIDATION_ERROR", "照片不属于该菜谱")
			return
		}
	}
	res, e := a.db.Exec("UPDATE recipes SET cover_media_id=? WHERE id=?", body.MediaID, id)
	if e != nil {
		errJSON(w, 500, "DB", e.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		errJSON(w, 404, "NOT_FOUND", "未找到菜谱")
		return
	}
	writeJSON(w, 200, map[string]any{"cover_media_id": body.MediaID})
}
func (a *App) saveRecipe(w http.ResponseWriter, r *http.Request) {
	var x Recipe
	if decode(r, &x) != nil || strings.TrimSpace(x.Title) == "" || utf8.RuneCountInString(x.Title) > 80 || len(x.Ingredients) > 100 || len(x.Steps) > 100 {
		errJSON(w, 400, "VALIDATION_ERROR", "请填写菜谱名称，食材和步骤各最多 100 项")
		return
	}
	x.ID = id()
	x.Custom = true
	x.Image = ""
	ij, _ := json.Marshal(x.Ingredients)
	sj, _ := json.Marshal(x.Steps)
	if r.Method == http.MethodPatch {
		x.ID = chi.URLParam(r, "id")
		res, e := a.db.Exec("UPDATE recipes SET title=?,category=?,description=?,ingredients_json=?,steps_json=? WHERE id=?", strings.TrimSpace(x.Title), x.Category, x.Description, ij, sj, x.ID)
		if e != nil {
			errJSON(w, 500, "DB", e.Error())
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			errJSON(w, 404, "NOT_FOUND", "未找到菜谱")
			return
		}
		a.db.QueryRow("SELECT favorite,custom,image,cover_media_id FROM recipes WHERE id=?", x.ID).Scan(&x.Favorite, &x.Custom, &x.Image, &x.CoverMediaID)
		x.Title = strings.TrimSpace(x.Title)
		x.Photos = a.recipeMedia(x.ID)
		writeJSON(w, 200, x)
		return
	}
	if _, e := a.db.Exec("INSERT INTO recipes(id,title,category,description,image,ingredients_json,steps_json,favorite,custom,cover_media_id) VALUES(?,?,?,?,?,?,?,?,?,'')", x.ID, x.Title, x.Category, x.Description, x.Image, ij, sj, x.Favorite, x.Custom); e != nil {
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
