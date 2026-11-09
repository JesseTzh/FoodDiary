CREATE TABLE guest_order_links (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE TABLE guest_orders (
    id TEXT PRIMARY KEY,
    link_id TEXT NOT NULL REFERENCES guest_order_links(id),
    request_id TEXT NOT NULL,
    guest_name TEXT NOT NULL,
    note TEXT NOT NULL,
    items_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(link_id, request_id)
);
CREATE INDEX idx_guest_orders_link ON guest_orders(link_id, created_at DESC);
