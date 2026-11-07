package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/go-chi/chi/v5"
)

func TestDiaryRecipesInheritAndMergeTags(t *testing.T) {
	_, db := newTestServer(t)
	a := &App{db: db}
	router := chi.NewRouter()
	router.Post("/entries", a.create)
	a.kitchenRoutes(router)
	save := func(path string, body any, method string) map[string]any {
		t.Helper()
		raw, _ := json.Marshal(body)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(method, path, bytes.NewReader(raw)))
		if response.Code != 200 && response.Code != 201 {
			t.Fatalf("%s: %d %s", path, response.Code, response.Body.String())
		}
		var result struct {
			Data map[string]any `json:"data"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result.Data
	}
	entry := map[string]any{"title": "晚餐", "cooked_on": "2026-11-06", "tags": []string{"快手菜", "少油"}, "dishes": []Dish{{Title: "炒蛋"}, {Title: "青菜"}}}
	first := save("/entries", entry, http.MethodPost)
	dishes := first["dishes"].([]any)
	for _, d := range dishes {
		recipeID := d.(map[string]any)["id"].(string)
		var raw string
		if err := db.QueryRow("SELECT tags_json FROM recipes WHERE id=?", recipeID).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var tags []string
		json.Unmarshal([]byte(raw), &tags)
		if !reflect.DeepEqual(tags, []string{"快手菜", "少油"}) {
			t.Fatalf("inherited tags: %v", tags)
		}
	}
	entry["tags"] = []string{"少油", "聚餐"}
	save("/entries", entry, http.MethodPost)
	recipeID := dishes[0].(map[string]any)["id"].(string)
	edited := save("/recipes/"+recipeID, map[string]any{"title": "炒蛋"}, http.MethodPatch)
	if !reflect.DeepEqual(edited["tags"], []any{"快手菜", "少油", "聚餐"}) {
		t.Fatalf("edit lost inherited tags: %v", edited)
	}
	if len(edited["ingredients"].([]any)) != 0 || len(edited["steps"].([]any)) != 0 {
		t.Fatal("optional fields were not empty")
	}
	edited = save("/recipes/"+recipeID, map[string]any{"title": "炒蛋", "tags": []string{}}, http.MethodPatch)
	if len(edited["tags"].([]any)) != 0 {
		t.Fatal("explicitly cleared tags were restored")
	}
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/recipes", nil))
	var result struct {
		Data []Recipe `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Data) != 2 {
		t.Fatalf("recipes: %+v", result.Data)
	}
}

func TestRecipeTagsMigrationBackfillsExistingDiaries(t *testing.T) {
	_, db := newTestServer(t)
	_, err := db.Exec(`
        ALTER TABLE recipes DROP COLUMN tags_json;
        DELETE FROM schema_migrations WHERE version='000011_recipe_tags.up.sql';
        INSERT INTO recipes(id,title,category,description,image,ingredients_json,steps_json) VALUES('recipe','炒蛋','','','','[]','[]'),('legacy','青菜','','','','[]','[]');
        INSERT INTO diary_entries(id,cooked_on,title,created_at,updated_at,dishes_json)
        VALUES('a','2026-11-06','晚餐','now','now','[{"id":"recipe","title":"炒蛋"}]'),
              ('b','2026-11-06','青菜','now','now','[]');
        INSERT INTO entry_tags(entry_id,tag) VALUES('a','少油'),('a','快手菜'),('b','素菜');
    `)
	if err != nil {
		t.Fatal(err)
	}
	if err = loadMigrations(db, "../../migrations"); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string][]string{"recipe": {"少油", "快手菜"}, "legacy": {"素菜"}} {
		var raw string
		if err := db.QueryRow("SELECT tags_json FROM recipes WHERE id=?", id).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var got []string
		json.Unmarshal([]byte(raw), &got)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("%s tags %v, want %v", id, got, want)
		}
	}
	if err = loadMigrations(db, "../../migrations"); err != nil {
		t.Fatal(err)
	}
}
