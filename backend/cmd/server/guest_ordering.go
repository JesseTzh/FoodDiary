package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
)

type OrderItem struct {
	RecipeID string `json:"recipe_id"`
	Title    string `json:"title"`
	Quantity int    `json:"quantity"`
}
type GuestOrder struct {
	ID        string      `json:"id"`
	GuestName string      `json:"guest_name"`
	Note      string      `json:"note"`
	Items     []OrderItem `json:"items"`
	CreatedAt string      `json:"created_at"`
}
type OrderLink struct {
	ID        string       `json:"id"`
	Title     string       `json:"title"`
	CreatedAt string       `json:"created_at"`
	ExpiresAt string       `json:"expires_at"`
	Orders    []GuestOrder `json:"orders"`
}

func (a *App) orderLinks(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodPost {
		var body struct {
			Title     string `json:"title"`
			ExpiresAt string `json:"expires_at"`
		}
		if decode(r, &body) != nil {
			errJSON(w, 400, "VALIDATION_ERROR", "请填写有效的分享信息")
			return
		}
		body.Title = strings.TrimSpace(body.Title)
		if body.Title == "" {
			body.Title = "来宾点菜"
		}
		expires := time.Now().UTC().Add(7 * 24 * time.Hour)
		if body.ExpiresAt != "" {
			var e error
			expires, e = time.Parse(time.RFC3339, body.ExpiresAt)
			if e != nil {
				errJSON(w, 400, "VALIDATION_ERROR", "请选择有效的过期时间")
				return
			}
		}
		if utf8.RuneCountInString(body.Title) > 80 || !expires.After(time.Now()) || expires.After(time.Now().Add(90*24*time.Hour)) {
			errJSON(w, 400, "VALIDATION_ERROR", "标题最多 80 字，有效期需在未来 90 天内")
			return
		}
		link := OrderLink{ID: id() + id(), Title: body.Title, CreatedAt: now(), ExpiresAt: expires.UTC().Format(time.RFC3339), Orders: []GuestOrder{}}
		if _, e := a.db.Exec("INSERT INTO guest_order_links(id,title,created_at,expires_at) VALUES(?,?,?,?)", link.ID, link.Title, link.CreatedAt, link.ExpiresAt); e != nil {
			errJSON(w, 500, "DB", "创建分享失败")
			return
		}
		writeJSON(w, 201, link)
		return
	}
	rows, e := a.db.Query("SELECT id,title,created_at,expires_at FROM guest_order_links ORDER BY created_at DESC,rowid DESC")
	if e != nil {
		errJSON(w, 500, "DB", "读取分享失败")
		return
	}
	links := []OrderLink{}
	for rows.Next() {
		var x OrderLink
		if e = rows.Scan(&x.ID, &x.Title, &x.CreatedAt, &x.ExpiresAt); e != nil {
			rows.Close()
			errJSON(w, 500, "DB", "读取分享失败")
			return
		}
		x.Orders = []GuestOrder{}
		links = append(links, x)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		errJSON(w, 500, "DB", "读取分享失败")
		return
	}
	for i := range links {
		orders, e := a.db.Query("SELECT id,guest_name,note,items_json,created_at FROM guest_orders WHERE link_id=? ORDER BY created_at DESC,rowid DESC", links[i].ID)
		if e != nil {
			errJSON(w, 500, "DB", "读取订单失败")
			return
		}
		for orders.Next() {
			var order GuestOrder
			var raw string
			if e = orders.Scan(&order.ID, &order.GuestName, &order.Note, &raw, &order.CreatedAt); e != nil {
				break
			}
			if e = json.Unmarshal([]byte(raw), &order.Items); e != nil {
				break
			}
			links[i].Orders = append(links[i].Orders, order)
		}
		if e == nil {
			e = orders.Err()
		}
		orders.Close()
		if e != nil {
			errJSON(w, 500, "DB", "读取订单失败")
			return
		}
	}
	writeJSON(w, 200, links)
}

func (a *App) activeOrderLink(w http.ResponseWriter, r *http.Request) (*OrderLink, bool) {
	w.Header().Set("Cache-Control", "no-store")
	var link OrderLink
	e := a.db.QueryRow("SELECT id,title,created_at,expires_at FROM guest_order_links WHERE id=?", chi.URLParam(r, "token")).Scan(&link.ID, &link.Title, &link.CreatedAt, &link.ExpiresAt)
	if e != nil {
		if e == sql.ErrNoRows {
			errJSON(w, 404, "NOT_FOUND", "点菜链接不存在")
		} else {
			errJSON(w, 500, "DB", "读取链接失败")
		}
		return nil, false
	}
	expires, e := time.Parse(time.RFC3339, link.ExpiresAt)
	if e != nil || !expires.After(time.Now()) {
		errJSON(w, 410, "EXPIRED", "点菜链接已过期，请联系主人重新分享")
		return nil, false
	}
	return &link, true
}

func (a *App) guestMenu(w http.ResponseWriter, r *http.Request) {
	link, ok := a.activeOrderLink(w, r)
	if !ok {
		return
	}
	rows, e := a.db.Query("SELECT id,title,category,description,image,cover_media_id,tags_json FROM recipes ORDER BY custom DESC,rowid")
	if e != nil {
		errJSON(w, 500, "DB", "读取菜单失败")
		return
	}
	menu := []map[string]any{}
	for rows.Next() {
		var rid, title, category, description, image, cover, tagsRaw string
		if e = rows.Scan(&rid, &title, &category, &description, &image, &cover, &tagsRaw); e != nil {
			break
		}
		tags := []string{}
		json.Unmarshal([]byte(tagsRaw), &tags)
		menu = append(menu, map[string]any{"id": rid, "title": title, "category": category, "description": description, "image": image, "tags": tags, "cover_media_id": cover})
	}
	if e == nil {
		e = rows.Err()
	}
	rows.Close()
	if e != nil {
		errJSON(w, 500, "DB", "读取菜单失败")
		return
	}
	for _, dish := range menu {
		photos := a.recipeMedia(dish["id"].(string))
		for i := range photos {
			photos[i].URL += "?order_token=" + link.ID
			photos[i].EntryID = ""
		}
		dish["photos"] = photos
	}
	writeJSON(w, 200, map[string]any{"title": link.Title, "expires_at": link.ExpiresAt, "recipes": menu})
}

func (a *App) placeGuestOrder(w http.ResponseWriter, r *http.Request) {
	link, ok := a.activeOrderLink(w, r)
	if !ok {
		return
	}
	var body struct {
		RequestID string      `json:"request_id"`
		GuestName string      `json:"guest_name"`
		Note      string      `json:"note"`
		Items     []OrderItem `json:"items"`
	}
	if decode(r, &body) != nil {
		errJSON(w, 400, "VALIDATION_ERROR", "订单格式有误")
		return
	}
	body.GuestName = strings.TrimSpace(body.GuestName)
	body.Note = strings.TrimSpace(body.Note)
	if body.GuestName == "" {
		body.GuestName = "来宾"
	}
	if len(body.RequestID) < 16 || len(body.RequestID) > 80 || utf8.RuneCountInString(body.GuestName) > 30 || utf8.RuneCountInString(body.Note) > 200 || len(body.Items) == 0 || len(body.Items) > 100 {
		errJSON(w, 400, "VALIDATION_ERROR", "请选择菜品，称呼最多 30 字，备注最多 200 字")
		return
	}
	tx, e := a.db.Begin()
	if e != nil {
		errJSON(w, 500, "DB", "下单失败，请重试")
		return
	}
	defer tx.Rollback()
	var existing GuestOrder
	var existingRaw string
	e = tx.QueryRow("SELECT id,guest_name,note,items_json,created_at FROM guest_orders WHERE link_id=? AND request_id=?", link.ID, body.RequestID).Scan(&existing.ID, &existing.GuestName, &existing.Note, &existingRaw, &existing.CreatedAt)
	if e == nil {
		json.Unmarshal([]byte(existingRaw), &existing.Items)
		writeJSON(w, 200, existing)
		return
	}
	if e != sql.ErrNoRows {
		errJSON(w, 500, "DB", "下单失败，请重试")
		return
	}
	seen := map[string]bool{}
	for i := range body.Items {
		item := &body.Items[i]
		if item.Quantity < 1 || item.Quantity > 99 || seen[item.RecipeID] {
			errJSON(w, 400, "VALIDATION_ERROR", "每道菜数量为 1–99 份，请勿重复添加")
			return
		}
		seen[item.RecipeID] = true
		if e = tx.QueryRow("SELECT title FROM recipes WHERE id=?", item.RecipeID).Scan(&item.Title); e != nil {
			if e == sql.ErrNoRows {
				errJSON(w, 409, "MENU_CHANGED", "菜谱已更新，请刷新菜单后重试")
			} else {
				errJSON(w, 500, "DB", "下单失败，请重试")
			}
			return
		}
	}
	order := GuestOrder{ID: id(), GuestName: body.GuestName, Note: body.Note, Items: body.Items, CreatedAt: now()}
	raw, _ := json.Marshal(order.Items)
	// The final write checks expiry again, including time spent waiting for SQLite.
	res, e := tx.Exec("INSERT INTO guest_orders(id,link_id,request_id,guest_name,note,items_json,created_at) SELECT ?,id,?,?,?,?,? FROM guest_order_links WHERE id=? AND expires_at>?", order.ID, body.RequestID, order.GuestName, order.Note, string(raw), order.CreatedAt, link.ID, now())
	if e != nil {
		errJSON(w, 500, "DB", "下单失败，请重试")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		errJSON(w, 410, "EXPIRED", "点菜链接已过期")
		return
	}
	if e = tx.Commit(); e != nil {
		errJSON(w, 500, "DB", "下单失败，请重试")
		return
	}
	writeJSON(w, 201, order)
}

func (a *App) orderMediaAllowed(r *http.Request, mediaID string) bool {
	token := r.URL.Query().Get("order_token")
	if token == "" {
		return false
	}
	var n int
	e := a.db.QueryRow("SELECT count(*) FROM media_assets m JOIN recipes p ON p.id=m.recipe_id JOIN guest_order_links l ON l.id=? WHERE m.id=? AND l.expires_at>?", token, mediaID, now()).Scan(&n)
	return e == nil && n > 0
}
