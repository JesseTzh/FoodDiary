-- Remove only the shipped presets; personal recipes and diary records remain.
DELETE FROM recipes WHERE custom=0 AND id IN ('tomato','chicken','greens','noodles');
UPDATE recipes SET image='' WHERE image IN ('tomato','chicken','greens','noodles');
