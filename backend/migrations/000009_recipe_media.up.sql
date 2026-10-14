-- Recipe photos can be stored without creating a diary entry.
BEGIN;
CREATE TABLE media_assets_new (
 id TEXT PRIMARY KEY,
 entry_id TEXT REFERENCES diary_entries(id) ON DELETE CASCADE,
 original_name TEXT, mime TEXT, size_bytes INTEGER, width INTEGER, height INTEGER,
 sha256 TEXT, status TEXT NOT NULL DEFAULT 'ready', created_at TEXT NOT NULL,
 recipe_id TEXT REFERENCES recipes(id) ON DELETE SET NULL
);
INSERT INTO media_assets_new SELECT id,entry_id,original_name,mime,size_bytes,width,height,sha256,status,created_at,recipe_id FROM media_assets;
DROP TABLE media_assets;
ALTER TABLE media_assets_new RENAME TO media_assets;
CREATE INDEX idx_media_recipe ON media_assets(recipe_id,created_at);
COMMIT;
