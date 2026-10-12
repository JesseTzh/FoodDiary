ALTER TABLE diary_entries ADD COLUMN meal TEXT NOT NULL DEFAULT '晚餐';
ALTER TABLE diary_entries ADD COLUMN mood INTEGER NOT NULL DEFAULT 0;
ALTER TABLE diary_entries ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
CREATE TABLE recipes (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL,
 description TEXT NOT NULL, image TEXT NOT NULL, ingredients_json TEXT NOT NULL,
 steps_json TEXT NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, custom INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE groceries (id TEXT PRIMARY KEY, name TEXT NOT NULL, checked INTEGER NOT NULL DEFAULT 0);
INSERT INTO app_settings(key,value) VALUES('profile_name','小虎和小鼠'),('profile_bio','一起做饭，一起变好 ♥');
INSERT INTO recipes VALUES
('tomato','番茄炒蛋','家常菜','酸甜开胃，简单又好吃！','tomato','["番茄 2 个","鸡蛋 3 个","盐、糖适量"]','["番茄切块，鸡蛋打散。","热锅炒熟鸡蛋，盛出备用。","炒软番茄，加入鸡蛋、盐和糖，翻炒均匀。"]',0,0),
('chicken','宫保鸡丁','肉类','鲜香微辣，超下饭的一道菜。','chicken','["鸡胸肉 250g","黄瓜 半根","花生 50g","干辣椒适量"]','["鸡肉切丁，加淀粉和生抽腌制。","炒香干辣椒，加入鸡丁炒熟。","加入黄瓜、花生和酱汁翻炒。"]',0,0),
('greens','清炒时蔬','素菜','把新鲜和清爽端上餐桌。','greens','["青菜 300g","蒜 2 瓣","盐适量"]','["青菜洗净沥干，蒜切末。","热油爆香蒜末。","加入青菜，大火翻炒后加盐。"]',0,0),
('noodles','酸辣土豆丝','家常菜','脆爽酸辣，是熟悉的家常味。','noodles','["土豆 2 个","辣椒 1 个","醋、盐适量"]','["土豆切丝，清水洗去淀粉。","炒香辣椒，加入土豆丝。","加醋和盐，快速翻炒出锅。"]',0,0);
