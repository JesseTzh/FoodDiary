package main

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func TestGuestOrderingLifecycle(t *testing.T) {
	ts, db := newTestServer(t)
	owner, guest := newClient(), newClient()
	if got := statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"})); got != 200 {
		t.Fatalf("setup: %d", got)
	}
	recipe := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/recipes", map[string]any{"title": "番茄炒蛋", "category": "家常菜", "tags": []string{"快手菜"}, "description": "少油"}))
	link := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/order-links", map[string]any{"title": "周末聚餐"}))
	expires, e := time.Parse(time.RFC3339, link["expires_at"].(string))
	if e != nil || time.Until(expires) < 7*24*time.Hour-time.Minute || time.Until(expires) > 7*24*time.Hour {
		t.Fatalf("default expiration: %v %v", expires, e)
	}
	path := ts.URL + "/api/v1/guest/order/" + link["id"].(string)
	menu := dataOf(t, get(t, guest, path))
	dishes := menu["recipes"].([]any)
	if len(dishes) != 1 || dishes[0].(map[string]any)["title"] != "番茄炒蛋" || menu["title"] != "周末聚餐" {
		t.Fatalf("menu: %+v", menu)
	}
	body := map[string]any{"request_id": "normal-order-request-001", "guest_name": "小王", "note": "少放盐", "items": []map[string]any{{"recipe_id": recipe["id"], "quantity": 2}}}
	order := dataOf(t, postJSON(t, guest, path+"/orders", body))
	retry := dataOf(t, postJSON(t, guest, path+"/orders", body))
	if order["id"] != retry["id"] {
		t.Fatal("retry created a duplicate order")
	}
	// Historical orders keep their dish names even after the current menu changes.
	if _, e = db.Exec("DELETE FROM recipes WHERE id=?", recipe["id"]); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec("UPDATE guest_order_links SET expires_at=? WHERE id=?", time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), link["id"]); e != nil {
		t.Fatal(e)
	}
	if got := statusOf(t, get(t, guest, path)); got != http.StatusGone {
		t.Fatalf("expired menu: %d", got)
	}
	if got := statusOf(t, postJSON(t, guest, path+"/orders", body)); got != http.StatusGone {
		t.Fatalf("expired ordering: %d", got)
	}
	var result struct {
		Data []OrderLink `json:"data"`
	}
	res := get(t, owner, ts.URL+"/api/v1/order-links")
	defer res.Body.Close()
	if e = json.NewDecoder(res.Body).Decode(&result); e != nil {
		t.Fatal(e)
	}
	if len(result.Data) != 1 || len(result.Data[0].Orders) != 1 {
		t.Fatalf("records: %+v", result.Data)
	}
	saved := result.Data[0].Orders[0]
	if saved.GuestName != "小王" || saved.Note != "少放盐" || saved.Items[0].Title != "番茄炒蛋" || saved.Items[0].Quantity != 2 {
		t.Fatalf("saved order: %+v", saved)
	}
}

func TestGuestOrderingCustomExpirationAndPhotos(t *testing.T) {
	ts, db := newTestServer(t)
	owner, guest := newClient(), newClient()
	statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"}))
	recipe := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/recipes", map[string]any{"title": "清炒时蔬"}))
	expiry := time.Now().UTC().Add(24 * time.Hour).Truncate(time.Second)
	link := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/order-links", map[string]any{"expires_at": expiry.Format(time.RFC3339)}))
	if link["expires_at"] != expiry.Format(time.RFC3339) {
		t.Fatalf("custom expiration: %+v", link)
	}
	// The menu provides token-scoped URLs for existing recipe photos.
	if _, e := db.Exec("INSERT INTO media_assets(id,recipe_id,mime,size_bytes,created_at) VALUES('menu-photo',?,'image/jpeg',12,?)", recipe["id"], now()); e != nil {
		t.Fatal(e)
	}
	menu := dataOf(t, get(t, guest, ts.URL+"/api/v1/guest/order/"+link["id"].(string)))
	photos := menu["recipes"].([]any)[0].(map[string]any)["photos"].([]any)
	url := photos[0].(map[string]any)["url"].(string)
	if url != "/media/assets/menu-photo/original?order_token="+link["id"].(string) {
		t.Fatalf("photo url: %s", url)
	}
}

func TestGuestMenuLastCookedOn(t *testing.T) {
	ts, db := newTestServer(t)
	owner, guest := newClient(), newClient()
	statusOf(t, postJSON(t, owner, ts.URL+"/api/v1/auth/setup", map[string]string{"password": "hunter2"}))
	recipe := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/recipes", map[string]any{"title": "番茄炒蛋"}))
	other := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/recipes", map[string]any{"title": "清炒时蔬"}))
	link := dataOf(t, postJSON(t, owner, ts.URL+"/api/v1/order-links", map[string]any{}))
	path := ts.URL + "/api/v1/guest/order/" + link["id"].(string)
	assertDates := func(want string) {
		t.Helper()
		menu := dataOf(t, get(t, guest, path))
		for _, value := range menu["recipes"].([]any) {
			dish := value.(map[string]any)
			expected := ""
			if dish["id"] == recipe["id"] {
				expected = want
			}
			if dish["last_cooked_on"] != expected {
				t.Fatalf("last cooked date: %+v, want %q", dish, expected)
			}
		}
	}
	assertDates("")
	// Cooking dates belong to the dish association, even after a rename.
	for i, date := range []string{"2026-10-01", "2026-10-20", "2026-10-10"} {
		raw, _ := json.Marshal([]map[string]any{{"id": recipe["id"], "title": "旧菜名"}})
		if _, err := db.Exec(`INSERT INTO diary_entries(id,cooked_on,title,created_at,updated_at,dishes_json)
			VALUES(?,?,'聚餐','now','now',?)`, date, date, string(raw)); err != nil {
			t.Fatal(i, err)
		}
	}
	assertDates("2026-10-20")
	if _, err := db.Exec("UPDATE diary_entries SET deleted_at='now' WHERE cooked_on='2026-10-20'"); err != nil {
		t.Fatal(err)
	}
	assertDates("2026-10-10")
	// A title match must not override an explicit association to another dish.
	raw, _ := json.Marshal([]map[string]any{{"id": other["id"], "title": other["title"]}})
	if _, err := db.Exec(`INSERT INTO diary_entries(id,cooked_on,title,created_at,updated_at,dishes_json)
		VALUES('other','2026-10-25',?,'now','now',?)`, recipe["title"], string(raw)); err != nil {
		t.Fatal(err)
	}
	menu := dataOf(t, get(t, guest, path))
	for _, value := range menu["recipes"].([]any) {
		dish := value.(map[string]any)
		if dish["id"] == recipe["id"] && dish["last_cooked_on"] != "2026-10-10" {
			t.Fatalf("matched unrelated diary title: %+v", dish)
		}
	}
	// Legacy diaries with no dish list still resolve by recipe title.
	if _, err := db.Exec(`INSERT INTO diary_entries(id,cooked_on,title,created_at,updated_at)
		VALUES('legacy','2026-10-30',?,'now','now')`, recipe["title"]); err != nil {
		t.Fatal(err)
	}
	menu = dataOf(t, get(t, guest, path))
	for _, value := range menu["recipes"].([]any) {
		dish := value.(map[string]any)
		if dish["id"] == recipe["id"] && dish["last_cooked_on"] != "2026-10-30" {
			t.Fatalf("legacy date: %+v", dish)
		}
	}
}
