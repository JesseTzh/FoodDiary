PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS diary_entries (id TEXT PRIMARY KEY, cooked_on TEXT NOT NULL, title TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'other', duration_minutes INTEGER, difficulty INTEGER, rating INTEGER, ingredients_json TEXT NOT NULL DEFAULT '[]', steps_json TEXT NOT NULL DEFAULT '[]', notes TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, version INTEGER NOT NULL DEFAULT 1);
CREATE INDEX IF NOT EXISTS idx_entries_cooked_on ON diary_entries(cooked_on); CREATE INDEX IF NOT EXISTS idx_entries_title ON diary_entries(title); CREATE INDEX IF NOT EXISTS idx_entries_updated ON diary_entries(updated_at);
CREATE TABLE IF NOT EXISTS entry_tags (entry_id TEXT NOT NULL REFERENCES diary_entries(id) ON DELETE CASCADE, tag TEXT NOT NULL, PRIMARY KEY(entry_id,tag)); CREATE INDEX IF NOT EXISTS idx_tags_tag ON entry_tags(tag);
CREATE TABLE IF NOT EXISTS media_assets (id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES diary_entries(id) ON DELETE CASCADE, original_name TEXT, mime TEXT, size_bytes INTEGER, width INTEGER, height INTEGER, sha256 TEXT, status TEXT NOT NULL DEFAULT 'ready', created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL, version INTEGER NOT NULL, changed_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
