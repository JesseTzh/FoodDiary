-- 游客浏览：标记某条记录是否开放给游客（0=不开放，1=开放）
ALTER TABLE diary_entries ADD COLUMN shared_with_guests INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_entries_shared ON diary_entries(shared_with_guests);
