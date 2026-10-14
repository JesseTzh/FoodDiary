// Shared by capture and gallery generation so every captured interface is documented.
export const layouts = {
  mobile: { width: 390, height: 844 },
  desktop: { width: 1440, height: 1080 },
};

export const pages = [
  { id: 'home', title: '首页', group: '日常记录', entry: '登录后首页 · 底部「首页」', description: '小厨房的日常入口，汇集记录做饭、推荐菜谱和最近的美味回忆。', features: ['点击记录入口开始写日记', '从推荐菜谱进入详情', '查看最近做饭记录'], review: '检查插画、快捷入口和卡片层级，以及桌面留白。' },
  { id: 'record', title: '记录做饭', group: '日常记录', entry: '首页 → 记录做饭', description: '为一次下厨记录多道菜、照片和当时的心情。', features: ['添加菜品，可关联已有菜谱', '选择或拍摄照片，最多 9 张，并指定照片归属菜品', '设置日期、餐次、心得、标签和心情，保存日记'], review: '检查照片区域、多道菜输入与表单排版；长表单可在应用内滚动。' },
  { id: 'diary', title: '日记列表', group: '日常记录', entry: '底部「日记」', description: '按时间回顾做过的菜，快速找到某次下厨记录。', features: ['按年月筛选日记', '搜索菜名、心得或标签', '点击记录进入详情'], review: '检查筛选、搜索与日记卡片的信息密度。' },
  { id: 'diary-detail', title: '日记详情', group: '日常记录', entry: '日记 → 点击一条记录', description: '展示一次做饭的菜品、日期、照片和心得。', features: ['回顾菜品、餐次、标签与心情', '收藏这份美味回忆', '进入编辑或删除确认'], review: '检查详情内容层级、照片区域及操作入口。' },
  { id: 'diary-edit', title: '编辑日记', group: '日常记录', entry: '日记详情 → 编辑', description: '在原有记录上修改菜品、照片和做饭信息。', features: ['回填已有记录', '修改菜品、日期、餐次、心得、标签和心情', '保存后更新原日记'], review: '检查回填内容和编辑标题是否清晰。' },
  { id: 'diary-delete', title: '删除确认', group: '日常记录', entry: '日记详情 → 删除日记', description: '删除前二次确认，帮助避免误删美味回忆。', features: ['提示删除后的结果', '「再想想」取消操作', '确认删除当前日记'], review: '检查弹窗、背景遮罩与危险操作按钮是否明确。' },
  { id: 'cookbook', title: '菜谱列表', group: '菜谱', entry: '底部「菜谱」', description: '浏览小厨房的菜谱，寻找下一顿想做的菜。', features: ['按分类筛选并搜索菜谱', '点击卡片查看食材和做法', '从创建入口添加自己的菜谱'], review: '检查分类标签、搜索框与菜谱卡片在双端的布局。' },
  { id: 'recipe-detail', title: '菜谱详情', group: '菜谱', entry: '菜谱 → 点击一道菜', description: '把介绍、准备食材和做法步骤放在一起，方便下厨参考。', features: ['查看菜谱介绍、食材、步骤和做过的照片', '收藏菜谱', '点击「今天就做这道菜」开始记录'], review: '检查食材与步骤的可读性，以及记录入口的位置。' },
  { id: 'recipe-record', title: '从菜谱记录做饭', group: '菜谱', entry: '菜谱详情 → 今天就做这道菜', description: '从菜谱直接进入记录表单，带入当前菜品，减少重复输入。', features: ['预填当前菜谱关联的菜品', '补充照片与本次做饭心得', '保存为新的日记'], review: '检查预填菜品与普通记录表单的一致性。' },
  { id: 'recipe-new', title: '新建菜谱', group: '菜谱', entry: '菜谱 → 创建菜谱', description: '把自己的拿手菜整理成可重复使用的菜谱。', features: ['填写名称、介绍和分类', '按行输入准备食材和做法步骤', '保存后在「我的菜谱」查看'], review: '检查分类选择、长文本输入与保存入口。' },
  { id: 'mine', title: '我的', group: '个人与账号', entry: '底部「我的」', description: '展示小厨房的个人资料和累计记录，并集中提供个人功能入口。', features: ['查看记录天数、创建菜谱数和收藏数', '进入我的收藏与我的菜谱', '进入设置修改资料'], review: '检查资料、统计数字与菜单的层级。' },
  { id: 'favorites', title: '我的收藏', group: '个人与账号', entry: '我的 → 我的收藏', description: '集中回顾收藏的菜谱和日记。', features: ['浏览收藏的菜谱和日记', '点击收藏项查看详情'], review: '检查收藏列表的类型区分与条目可读性。' },
  { id: 'my-recipes', title: '我的菜谱', group: '个人与账号', entry: '我的 → 我的菜谱', description: '集中展示自己创建的菜谱，方便再次下厨时查找。', features: ['查看自建菜谱列表', '点击菜谱进入详情'], review: '检查菜谱名称、分类与列表间距。' },
  { id: 'settings', title: '设置', group: '个人与账号', entry: '我的 → 设置', description: '维护小厨房的展示资料，并管理当前登录状态。', features: ['修改我们的名字与一句话介绍', '保存资料', '退出小厨房，回到登录页'], review: '检查资料输入、保存与退出入口。' },
  { id: 'login', title: '登录', group: '个人与账号', entry: '未登录时 · 设置 → 退出小厨房', description: '已有厨房密码时，使用密码进入小厨房。', features: ['输入已有厨房密码', '登录后进入首页'], review: '检查密码输入提示与登录按钮；截图使用模拟登录状态。' },
  { id: 'setup', title: '首次设置密码', group: '个人与账号', entry: '尚未设置厨房密码时首次进入', description: '首次使用时设置厨房密码，建立小厨房的访问入口。', features: ['引导首次设置厨房密码', '完成设置后开始使用'], review: '检查首次使用文案与登录页的区别。' },
];
