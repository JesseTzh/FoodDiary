package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-chi/chi/v5"
)

func TestRecipeEditPreservesMediaAndFavorite(t *testing.T) {
	_, db := newTestServer(t)
	_, err := db.Exec("INSERT INTO recipes(id,title,category,description,image,ingredients_json,steps_json,favorite,custom,cover_media_id) VALUES('dish','番茄炒蛋','家常菜','','','[]','[]',1,1,'cover')")
	if err != nil {
		t.Fatal(err)
	}
	a := &App{db: db}
	router := chi.NewRouter()
	a.kitchenRoutes(router)
	body := []byte(`{"title":"家常番茄炒蛋","category":"素菜","description":"少糖","ingredients":["番茄","鸡蛋"],"steps":["先炒蛋"]}`)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodPatch, "/recipes/dish", bytes.NewReader(body)))
	if rec.Code != 200 {
		t.Fatalf("edit: %d %s", rec.Code, rec.Body.String())
	}
	var result struct {
		Data Recipe `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	x := result.Data
	if x.ID != "dish" || x.Title != "家常番茄炒蛋" || !x.Favorite || !x.Custom || x.CoverMediaID != "cover" || len(x.Ingredients) != 2 || len(x.Steps) != 1 {
		t.Fatalf("unexpected edited recipe: %+v", x)
	}
	var title string
	if err := db.QueryRow("SELECT title FROM recipes WHERE id='dish'").Scan(&title); err != nil || title != x.Title {
		t.Fatalf("edit not persisted: %s %v", title, err)
	}
	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodPatch, "/recipes/missing", bytes.NewReader(body)))
	if rec.Code != 404 {
		t.Fatalf("missing recipe: %d", rec.Code)
	}
}

func TestStandaloneRecipePhotos(t *testing.T) {
	ts, db := newTestServer(t)
	owner := newClient()
	resp := postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})
	resp.Body.Close()
	recipe := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/recipes", map[string]any{
		"title": "测试菜谱", "category": "家常菜", "ingredients": []string{"鸡蛋"}, "steps": []string{"炒熟"},
	}))
	recipeID := recipe["id"].(string)
	upload := func(id string, raw []byte, want int) map[string]any {
		t.Helper()
		var buf bytes.Buffer
		form := multipart.NewWriter(&buf)
		file, _ := form.CreateFormFile("file", "dish.jpg")
		file.Write(raw)
		form.Close()
		req, _ := http.NewRequest("POST", ts.URL+"/api/v1/recipes/"+id+"/media", &buf)
		req.Header.Set("Content-Type", form.FormDataContentType())
		req.Header.Set("Origin", ts.URL)
		res, err := owner.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != want {
			defer res.Body.Close()
			t.Fatalf("upload: got %d, want %d", res.StatusCode, want)
		}
		if want >= 400 {
			res.Body.Close()
			return nil
		}
		return dataOf(t, res)
	}
	raw := testJPEG(t)
	media := upload(recipeID, raw, 201)
	duplicate := upload(recipeID, raw, 200)
	if duplicate["id"] != media["id"] {
		t.Fatal("duplicate photo was stored twice")
	}
	upload("missing", raw, 404)
	upload(recipeID, []byte("not an image"), 400)
	var count int
	if err := db.QueryRow("SELECT count(*) FROM diary_entries").Scan(&count); err != nil || count != 0 {
		t.Fatalf("upload created a diary: %d %v", count, err)
	}
	var entry sql.NullString
	if err := db.QueryRow("SELECT entry_id FROM media_assets WHERE id=?", media["id"]).Scan(&entry); err != nil || entry.Valid {
		t.Fatalf("expected standalone photo: %v %v", entry, err)
	}
	var result struct {
		Data []Recipe `json:"data"`
	}
	res := get(t, owner, ts.URL+"/api/v1/recipes")
	if err := json.NewDecoder(res.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if len(result.Data) != 1 || len(result.Data[0].Photos) != 1 || result.Data[0].CoverMediaID != media["id"] {
		t.Fatalf("photo not listed as cover: %+v", result.Data)
	}
	url := ts.URL + media["url"].(string)
	if got := statusOf(t, get(t, owner, url)); got != 200 {
		t.Fatalf("owner photo access: %d", got)
	}
	if got := statusOf(t, get(t, newClient(), url)); got != 401 {
		t.Fatalf("guest photo access: %d", got)
	}
	for i := 1; i < 9; i++ {
		upload(recipeID, append(append([]byte{}, raw...), byte(i)), 201)
	}
	upload(recipeID, append(append([]byte{}, raw...), byte(10)), 400)
	req, _ := http.NewRequest("DELETE", ts.URL+"/api/v1/recipes/"+recipeID, nil)
	req.Header.Set("Origin", ts.URL)
	res, err := owner.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if got := statusOf(t, res); got != 200 {
		t.Fatalf("delete recipe: %d", got)
	}
	if got := statusOf(t, get(t, owner, url)); got != 404 {
		t.Fatalf("deleted photo access: %d", got)
	}
	if err := db.QueryRow("SELECT count(*) FROM media_assets").Scan(&count); err != nil || count != 0 {
		t.Fatalf("orphan media: %d %v", count, err)
	}
}

func TestRecipeMediaMigrationPreservesDiaryPhotos(t *testing.T) {
	db, err := sql.Open("sqlite3", filepath.Join(t.TempDir(), "upgrade.db")+"?_foreign_keys=on")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	previous := t.TempDir()
	paths, err := filepath.Glob("../../migrations/*.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if filepath.Base(path) >= "000009_recipe_media.up.sql" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(previous, filepath.Base(path)), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err = loadMigrations(db, previous); err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO diary_entries(id,cooked_on,title,created_at,updated_at) VALUES('entry','2026-10-14','日记','now','now');
 INSERT INTO recipes(id,title,category,description,image,ingredients_json,steps_json,cover_media_id) VALUES('recipe','菜谱','家常菜','','','[]','[]','photo');
 INSERT INTO media_assets(id,entry_id,recipe_id,mime,size_bytes,created_at) VALUES('photo','entry','recipe','image/jpeg',12,'now');`)
	if err != nil {
		t.Fatal(err)
	}
	if err = loadMigrations(db, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	var entry, recipe, mime string
	var size int
	if err = db.QueryRow("SELECT entry_id,recipe_id,mime,size_bytes FROM media_assets WHERE id='photo'").Scan(&entry, &recipe, &mime, &size); err != nil || entry != "entry" || recipe != "recipe" || mime != "image/jpeg" || size != 12 {
		t.Fatalf("existing photo changed: %q %q %q %d %v", entry, recipe, mime, size, err)
	}
	if _, err = db.Exec("INSERT INTO media_assets(id,recipe_id,created_at) VALUES('standalone','recipe','now')"); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("DELETE FROM diary_entries WHERE id='entry'"); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = db.QueryRow("SELECT count(*) FROM media_assets").Scan(&count); err != nil || count != 1 {
		t.Fatalf("diary cascade changed: %d %v", count, err)
	}
	if err = loadMigrations(db, "../../migrations"); err != nil {
		t.Fatal(err)
	}
}
