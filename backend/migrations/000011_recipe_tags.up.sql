ALTER TABLE recipes ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]';

-- Recover tags from existing diaries, including recipes without photos.
UPDATE recipes SET tags_json = COALESCE((
    SELECT json_group_array(tag) FROM (
        SELECT DISTINCT t.tag FROM diary_entries e
        JOIN entry_tags t ON t.entry_id=e.id
        WHERE e.deleted_at IS NULL AND (
            EXISTS (SELECT 1 FROM json_each(e.dishes_json) d
                    WHERE json_extract(d.value, '$.id')=recipes.id)
            OR EXISTS (SELECT 1 FROM media_assets m
                       WHERE m.entry_id=e.id AND m.recipe_id=recipes.id)
            OR e.title=recipes.title COLLATE NOCASE
        )
        ORDER BY t.tag
    )
), '[]');
