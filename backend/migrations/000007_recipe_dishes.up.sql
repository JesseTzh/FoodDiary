ALTER TABLE diary_entries ADD COLUMN dishes_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE recipes ADD COLUMN cover_media_id TEXT NOT NULL DEFAULT '';
ALTER TABLE media_assets ADD COLUMN recipe_id TEXT REFERENCES recipes(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_media_recipe ON media_assets(recipe_id,created_at);
