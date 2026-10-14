package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
