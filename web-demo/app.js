/* =========================================================
   鹦鹉播放器 ParrotPlayer · Web 高仿演示 - 应用逻辑
   职责：单页应用（媒体库 / 播放器 / 学习 / 设置），零依赖。
   结构：工具函数 → 内置数据 → 全局状态 → 持久化 →
        Toast / Modal / Sheet → 媒体库 → 播放器 →
        字幕 / SRT / 词卡 → 学习页 → 设置页 → 初始化
   ========================================================= */
'use strict';

/* ================= 一、工具函数 ================= */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

/** HTML 转义，防止注入 */
function escapeHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/** 秒 → m:ss 格式 */
function fmtTime(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return m + ':' + String(s).padStart(2, '0');
}

/** 限幅 */
const clamp = (v, min, max) => Math.min(max, Math.max(min, v));

/** 简易 uid */
let _uid = 0;
const uid = (p = 'id') => p + '_' + Date.now().toString(36) + '_' + (_uid++);

/* ================= 二、内置数据 ================= */

/** 默认演示视频 URL（MDN CC0 示例，flower.mp4） */
const DEMO_URL = 'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4';

/** 内置示例视频（海报用 CSS 渐变占位） */
const SAMPLE_VIDEOS = [
  {
    id: 'v_flower', title: '花园蜜蜂（flower）', url: DEMO_URL,
    format: 'MP4', duration: '00:30',
    poster: 'linear-gradient(135deg,#1b4332 0%,#2d6a4f 45%,#95d5b2 100%)',
    sub: '花园里的蜜蜂 · 演示双语字幕（0-30s 循环）'
  },
  {
    id: 'v_bunny', title: 'Big Buck Bunny', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    format: 'MP4', duration: '09:56',
    poster: 'linear-gradient(135deg,#3a1c71 0%,#d76d77 60%,#ffaf7b 100%)',
    sub: '开源动画短片'
  },
  {
    id: 'v_blazes', title: 'For Bigger Blazes', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
    format: 'MP4', duration: '00:15',
    poster: 'linear-gradient(135deg,#0f0c29 0%,#302b63 50%,#ff4e50 100%)',
    sub: 'Chromecast 演示片段'
  },
  {
    id: 'v_escape', title: 'For Bigger Escapes', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
    format: 'MP4', duration: '00:15',
    poster: 'linear-gradient(135deg,#134e5e 0%,#71b280 100%)',
    sub: 'Chromecast 演示片段'
  },
  {
    id: 'v_sintel', title: 'Sintel', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
    format: 'MP4', duration: '14:48',
    poster: 'linear-gradient(135deg,#232526 0%,#414345 60%,#8e9eab 100%)',
    sub: 'Blender 开源电影'
  },
  {
    id: 'v_elephant', title: 'Elephants Dream', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    format: 'MP4', duration: '10:53',
    poster: 'linear-gradient(135deg,#41295a 0%,#2f0743 100%)',
    sub: 'Blender 开源电影'
  },
  {
    id: 'v_joy', title: 'For Bigger Joyrides', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
    format: 'MP4', duration: '00:15',
    poster: 'linear-gradient(135deg,#f7971e 0%,#ffd200 100%)',
    sub: 'Chromecast 演示片段'
  },
  {
    id: 'v_mkv', title: ' Tears of Steel（MKV 占位）', url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
    format: 'MKV', duration: '12:14',
    poster: 'linear-gradient(135deg,#141e30 0%,#243b55 100%)',
    sub: '演示角标：MKV · 可拖入本地 MKV 体验'
  }
];

/** 内置双语字幕（与 flower.mp4 大致对齐，约 20 条 cue，覆盖 0-30s） */
const BUILTIN_SUBTITLES = [
  { start: 0.0,  end: 1.5,  primary: "A gentle morning in the garden.", secondary: "花园里温柔的清晨。" },
  { start: 1.5,  end: 3.0,  primary: "The sun rises over the green leaves.", secondary: "太阳升起，照亮翠绿的叶子。" },
  { start: 3.0,  end: 4.5,  primary: "A bee wakes up for its daily work.", secondary: "一只蜜蜂醒来，开始一天的工作。" },
  { start: 4.5,  end: 6.0,  primary: "It flies slowly across the flowers.", secondary: "它缓缓飞过一朵朵花。" },
  { start: 6.0,  end: 7.5,  primary: "The garden is quiet and peaceful.", secondary: "花园安静而祥和。" },
  { start: 7.5,  end: 9.0,  primary: "Colors of pink and yellow fill the air.", secondary: "粉色与黄色弥漫在空气中。" },
  { start: 9.0,  end: 10.5, primary: "The bee lands on a soft petal.", secondary: "蜜蜂落在一片柔软的花瓣上。" },
  { start: 10.5, end: 12.0, primary: "It searches for sweet nectar.", secondary: "它寻找甘甜的花蜜。" },
  { start: 12.0, end: 13.5, primary: "Every flower offers a small meal.", secondary: "每一朵花都提供一顿小餐。" },
  { start: 13.5, end: 15.0, primary: "Nature works in silent harmony.", secondary: "大自然无声地和谐运转。" },
  { start: 15.0, end: 16.5, primary: "The wind moves the leaves again.", secondary: "风再次吹动树叶。" },
  { start: 16.5, end: 18.0, primary: "Small drops of water shine brightly.", secondary: "小小的水滴闪闪发亮。" },
  { start: 18.0, end: 19.5, primary: "The bee carries pollen from flower to flower.", secondary: "蜜蜂把花粉从一朵花带到另一朵花。" },
  { start: 19.5, end: 21.0, primary: "This is how new flowers are born.", secondary: "新的花就是这样孕育的。" },
  { start: 21.0, end: 22.5, primary: "The camera stays close and calm.", secondary: "镜头保持近距离，平静而稳定。" },
  { start: 22.5, end: 24.0, primary: "Wings move fast, almost invisible.", secondary: "翅膀快速扇动，几乎看不见。" },
  { start: 24.0, end: 25.5, primary: "Patience is the secret of nature.", secondary: "耐心是大自然的秘密。" },
  { start: 25.5, end: 27.0, primary: "In the end, the bee flies away.", secondary: "最后，蜜蜂飞走了。" },
  { start: 27.0, end: 28.5, primary: "The garden returns to silence.", secondary: "花园恢复了寂静。" },
  { start: 28.5, end: 30.0, primary: "And the day continues, slowly.", secondary: "日子继续，慢慢地流逝。" }
];

/** 内置小词典（约 90 词，含分级） */
const DICTIONARY = [
  // ---- 四级 ----
  { word: 'garden', level: 'cet4', phonetic: '/ˈɡɑːdn/', def: 'n. 花园，菜园', ex: 'The garden is full of flowers.', exZh: '花园里开满了花。' },
  { word: 'morning', level: 'cet4', phonetic: '/ˈmɔːrnɪŋ/', def: 'n. 早晨，上午', ex: 'I walk in the morning.', exZh: '我在早晨散步。' },
  { word: 'sun', level: 'cet4', phonetic: '/sʌn/', def: 'n. 太阳，阳光', ex: 'The sun is bright today.', exZh: '今天阳光明媚。' },
  { word: 'rise', level: 'cet4', phonetic: '/raɪz/', def: 'v. 升起，上升', ex: 'The sun rises in the east.', exZh: '太阳从东方升起。' },
  { word: 'green', level: 'cet4', phonetic: '/ɡriːn/', def: 'adj. 绿色的；n. 绿色', ex: 'The leaves are green.', exZh: '叶子是绿色的。' },
  { word: 'leaf', level: 'cet4', phonetic: '/liːf/', def: 'n. 树叶（复数 leaves）', ex: 'A leaf falls from the tree.', exZh: '一片叶子从树上落下。' },
  { word: 'bee', level: 'cet4', phonetic: '/biː/', def: 'n. 蜜蜂', ex: 'A bee flies to the flower.', exZh: '一只蜜蜂飞向花朵。' },
  { word: 'wake', level: 'cet4', phonetic: '/weɪk/', def: 'v. 醒来，唤醒', ex: 'I wake up at seven.', exZh: '我七点醒来。' },
  { word: 'work', level: 'cet4', phonetic: '/wɜːrk/', def: 'n./v. 工作', ex: 'Bees work every day.', exZh: '蜜蜂每天工作。' },
  { word: 'fly', level: 'cet4', phonetic: '/flaɪ/', def: 'v. 飞，飞行', ex: 'Birds fly in the sky.', exZh: '鸟儿在天上飞。' },
  { word: 'slowly', level: 'cet4', phonetic: '/ˈsloʊli/', def: 'adv. 缓慢地', ex: 'The bee moves slowly.', exZh: '蜜蜂移动得很慢。' },
  { word: 'across', level: 'cet4', phonetic: '/əˈkrɔːs/', def: 'prep. 穿过，横过', ex: 'We walk across the field.', exZh: '我们穿过田野。' },
  { word: 'flower', level: 'cet4', phonetic: '/ˈflaʊər/', def: 'n. 花，花朵', ex: 'The flower smells sweet.', exZh: '这花闻起来很香。' },
  { word: 'quiet', level: 'cet4', phonetic: '/ˈkwaɪət/', def: 'adj. 安静的', ex: 'The room is quiet.', exZh: '房间很安静。' },
  { word: 'color', level: 'cet4', phonetic: '/ˈkʌlər/', def: 'n. 颜色，色彩', ex: 'What color is the sky?', exZh: '天空是什么颜色？' },
  { word: 'pink', level: 'cet4', phonetic: '/pɪŋk/', def: 'adj. 粉色的；n. 粉色', ex: 'She wears a pink dress.', exZh: '她穿着粉色的裙子。' },
  { word: 'yellow', level: 'cet4', phonetic: '/ˈjeloʊ/', def: 'adj. 黄色的；n. 黄色', ex: 'The sun is yellow.', exZh: '太阳是黄色的。' },
  { word: 'fill', level: 'cet4', phonetic: '/fɪl/', def: 'v. 填满，充满', ex: 'Music fills the air.', exZh: '音乐弥漫在空气中。' },
  { word: 'air', level: 'cet4', phonetic: '/er/', def: 'n. 空气，天空', ex: 'The air is fresh.', exZh: '空气很清新。' },
  { word: 'land', level: 'cet4', phonetic: '/lænd/', def: 'v. 着陆，登陆；n. 陆地', ex: 'The bee lands on a petal.', exZh: '蜜蜂落在花瓣上。' },
  { word: 'soft', level: 'cet4', phonetic: '/sɔːft/', def: 'adj. 柔软的，柔和的', ex: 'The pillow is soft.', exZh: '枕头很柔软。' },
  { word: 'search', level: 'cet4', phonetic: '/sɜːrtʃ/', def: 'v. 搜寻，搜索', ex: 'They search for food.', exZh: '它们寻找食物。' },
  { word: 'sweet', level: 'cet4', phonetic: '/swiːt/', def: 'adj. 甜的，甜蜜的', ex: 'The nectar is sweet.', exZh: '花蜜是甜的。' },
  { word: 'meal', level: 'cet4', phonetic: '/miːl/', def: 'n. 一餐，一顿饭', ex: 'Enjoy your meal.', exZh: '请享用你的餐点。' },
  { word: 'nature', level: 'cet4', phonetic: '/ˈneɪtʃər/', def: 'n. 大自然，本性', ex: 'Nature is beautiful.', exZh: '大自然是美丽的。' },
  { word: 'wind', level: 'cet4', phonetic: '/wɪnd/', def: 'n. 风；v. 缠绕', ex: 'The wind blows gently.', exZh: '风轻轻地吹。' },
  { word: 'move', level: 'cet4', phonetic: '/muːv/', def: 'v. 移动，搬动', ex: 'Leaves move in the wind.', exZh: '叶子在风中摇动。' },
  { word: 'again', level: 'cet4', phonetic: '/əˈɡen/', def: 'adv. 再一次，又', ex: 'Try again, please.', exZh: '请再试一次。' },
  { word: 'drop', level: 'cet4', phonetic: '/drɑːp/', def: 'n. 滴；v. 落下', ex: 'A drop of water falls.', exZh: '一滴水落了下来。' },
  { word: 'water', level: 'cet4', phonetic: '/ˈwɔːtər/', def: 'n. 水；v. 浇水', ex: 'Drink more water.', exZh: '多喝水。' },
  { word: 'carry', level: 'cet4', phonetic: '/ˈkæri/', def: 'v. 携带，搬运', ex: 'Bees carry pollen.', exZh: '蜜蜂携带花粉。' },
  { word: 'camera', level: 'cet4', phonetic: '/ˈkæmərə/', def: 'n. 照相机，摄像机', ex: 'The camera is new.', exZh: '这台相机是新的。' },
  { word: 'stay', level: 'cet4', phonetic: '/steɪ/', def: 'v. 停留，保持', ex: 'Stay here, please.', exZh: '请留在这里。' },
  { word: 'close', level: 'cet4', phonetic: '/kloʊz/', def: 'v. 关闭；adj. 近的', ex: 'Close the door.', exZh: '把门关上。' },
  { word: 'calm', level: 'cet4', phonetic: '/kɑːm/', def: 'adj. 冷静的，平静的', ex: 'Keep calm and breathe.', exZh: '保持冷静，深呼吸。' },
  { word: 'wing', level: 'cet4', phonetic: '/wɪŋ/', def: 'n. 翅膀，翼', ex: "The bird's wing is hurt.", exZh: '鸟的翅膀受伤了。' },
  { word: 'fast', level: 'cet4', phonetic: '/fæst/', def: 'adv. 快地；adj. 快的', ex: 'He runs fast.', exZh: '他跑得很快。' },
  { word: 'almost', level: 'cet4', phonetic: '/ˈɔːlmoʊt/', def: 'adv. 几乎，差不多', ex: 'It is almost noon.', exZh: '快到中午了。' },
  { word: 'secret', level: 'cet4', phonetic: '/ˈsiːkrət/', def: 'n. 秘密；adj. 秘密的', ex: 'Can you keep a secret?', exZh: '你能保守秘密吗？' },
  { word: 'away', level: 'cet4', phonetic: '/əˈweɪ/', def: 'adv. 离开，远离', ex: 'The bee flies away.', exZh: '蜜蜂飞走了。' },
  { word: 'return', level: 'cet4', phonetic: '/rɪˈtɜːrn/', def: 'v. 返回，归还', ex: 'She returns home.', exZh: '她回家了。' },
  { word: 'continue', level: 'cet4', phonetic: '/kənˈtɪnjuː/', def: 'v. 继续，延续', ex: 'The story continues.', exZh: '故事继续着。' },
  { word: 'day', level: 'cet4', phonetic: '/deɪ/', def: 'n. 一天，白天', ex: 'Have a nice day.', exZh: '祝你今天愉快。' },
  { word: 'gentle', level: 'cet4', phonetic: '/ˈdʒentl/', def: 'adj. 温柔的，轻柔的', ex: 'A gentle wind blows.', exZh: '一阵温柔的风吹过。' },
  { word: 'bright', level: 'cet4', phonetic: '/braɪt/', def: 'adj. 明亮的，聪明的', ex: 'The room is bright.', exZh: '房间很明亮。' },
  { word: 'peace', level: 'cet4', phonetic: '/piːs/', def: 'n. 和平，宁静', ex: 'I love the peace here.', exZh: '我喜欢这里的宁静。' },
  { word: 'plant', level: 'cet4', phonetic: '/plænt/', def: 'n. 植物；v. 种植', ex: 'Water the plant.', exZh: '给植物浇水。' },
  { word: 'grow', level: 'cet4', phonetic: '/ɡroʊ/', def: 'v. 生长，增长', ex: 'Plants grow in spring.', exZh: '植物在春天生长。' },
  { word: 'seed', level: 'cet4', phonetic: '/siːd/', def: 'n. 种子', ex: 'Birds eat seeds.', exZh: '鸟吃种子。' },
  { word: 'soil', level: 'cet4', phonetic: '/sɔɪl/', def: 'n. 土壤', ex: 'The soil is rich.', exZh: '土壤很肥沃。' },
  { word: 'root', level: 'cet4', phonetic: '/ruːt/', def: 'n. 根，根部', ex: 'The root goes deep.', exZh: '根扎得很深。' },
  { word: 'tree', level: 'cet4', phonetic: '/triː/', def: 'n. 树', ex: 'The tree is tall.', exZh: '这棵树很高。' },
  { word: 'sky', level: 'cet4', phonetic: '/skaɪ/', def: 'n. 天空', ex: 'The sky is blue.', exZh: '天空是蓝色的。' },
  { word: 'cloud', level: 'cet4', phonetic: '/klaʊd/', def: 'n. 云', ex: 'A cloud passes by.', exZh: '一朵云飘过。' },
  { word: 'rain', level: 'cet4', phonetic: '/reɪn/', def: 'n./v. 雨，下雨', ex: 'It will rain today.', exZh: '今天会下雨。' },
  { word: 'spring', level: 'cet4', phonetic: '/sprɪŋ/', def: 'n. 春天，春季', ex: 'Spring is my favorite.', exZh: '春天是我的最爱。' },
  { word: 'summer', level: 'cet4', phonetic: '/ˈsʌmər/', def: 'n. 夏天，夏季', ex: 'Summer is hot.', exZh: '夏天很热。' },
  { word: 'winter', level: 'cet4', phonetic: '/ˈwɪntər/', def: 'n. 冬天，冬季', ex: 'Winter is cold.', exZh: '冬天很冷。' },
  { word: 'beautiful', level: 'cet4', phonetic: '/ˈbjuːtɪfl/', def: 'adj. 美丽的，美好的', ex: 'What a beautiful day!', exZh: '多美的一天！' },
  { word: 'future', level: 'cet4', phonetic: '/ˈfjuːtʃər/', def: 'n. 未来，将来', ex: 'The future is unknown.', exZh: '未来是未知的。' },
  { word: 'moment', level: 'cet4', phonetic: '/ˈmoʊmənt/', def: 'n. 时刻，瞬间', ex: 'This is a special moment.', exZh: '这是一个特别的时刻。' },
  { word: 'shine', level: 'cet4', phonetic: '/ʃaɪn/', def: 'v. 闪耀，照耀', ex: 'Stars shine at night.', exZh: '星星在夜晚闪耀。' },
  // ---- 六级 ----
  { word: 'peaceful', level: 'cet6', phonetic: '/ˈpiːsfl/', def: 'adj. 宁静的，和平的', ex: 'The lake is peaceful.', exZh: '湖面很宁静。' },
  { word: 'petal', level: 'cet6', phonetic: '/ˈpetl/', def: 'n. 花瓣', ex: 'A petal falls down.', exZh: '一片花瓣飘落。' },
  { word: 'offer', level: 'cet6', phonetic: '/ˈɔːfər/', def: 'v. 提供，提议', ex: 'They offer help.', exZh: '他们提供帮助。' },
  { word: 'silent', level: 'cet6', phonetic: '/ˈsaɪlənt/', def: 'adj. 无声的，沉默的', ex: 'The hall was silent.', exZh: '大厅里一片寂静。' },
  { word: 'harmony', level: 'cet6', phonetic: '/ˈhɑːrməni/', def: 'n. 和谐，和睦', ex: 'They live in harmony.', exZh: '他们和谐相处。' },
  { word: 'brightly', level: 'cet6', phonetic: '/ˈbraɪtli/', def: 'adv. 明亮地，鲜明地', ex: 'The sun shines brightly.', exZh: '阳光明亮地照耀。' },
  { word: 'pollen', level: 'cet6', phonetic: '/ˈpɑːlən/', def: 'n. 花粉', ex: 'Pollen travels by wind.', exZh: '花粉随风传播。' },
  { word: 'invisible', level: 'cet6', phonetic: '/ɪnˈvɪzəbl/', def: 'adj. 看不见的，无形的', ex: 'The wings are almost invisible.', exZh: '翅膀几乎看不见。' },
  { word: 'patience', level: 'cet6', phonetic: '/ˈpeɪʃns/', def: 'n. 耐心，忍耐', ex: 'Patience is a virtue.', exZh: '耐心是一种美德。' },
  { word: 'silence', level: 'cet6', phonetic: '/ˈsaɪləns/', def: 'n. 寂静，沉默', ex: 'Silence filled the room.', exZh: '寂静充满了房间。' },
  { word: 'branch', level: 'cet6', phonetic: '/bræntʃ/', def: 'n. 树枝，分支', ex: 'A bird sits on the branch.', exZh: '一只鸟停在树枝上。' },
  { word: 'season', level: 'cet6', phonetic: '/ˈsiːzn/', def: 'n. 季节，时节', ex: 'Autumn is a cool season.', exZh: '秋天是个凉爽的季节。' },
  { word: 'wonderful', level: 'cet6', phonetic: '/ˈwʌndərfl/', def: 'adj. 美妙的，精彩的', ex: 'What a wonderful show!', exZh: '多美妙的演出！' },
  { word: 'fresh', level: 'cet6', phonetic: '/freʃ/', def: 'adj. 新鲜的，清新的', ex: 'The air is fresh here.', exZh: '这里空气很新鲜。' },
  { word: 'clear', level: 'cet6', phonetic: '/klɪr/', def: 'adj. 清澈的，清楚的', ex: 'The water is clear.', exZh: '水很清澈。' },
  { word: 'warm', level: 'cet6', phonetic: '/wɔːrm/', def: 'adj. 温暖的，暖和的', ex: 'A warm wind blows.', exZh: '一阵温暖的风吹着。' },
  { word: 'shadow', level: 'cet6', phonetic: '/ˈʃædoʊ/', def: 'n. 影子，阴影', ex: "The tree's shadow is long.", exZh: '树的影子很长。' },
  { word: 'dream', level: 'cet6', phonetic: '/driːm/', def: 'n. 梦，梦想；v. 做梦', ex: 'I had a strange dream.', exZh: '我做了一个奇怪的梦。' },
  { word: 'journey', level: 'cet6', phonetic: '/ˈdʒɜːrni/', def: 'n. 旅程，行程', ex: 'Life is a long journey.', exZh: '人生是一段漫长的旅程。' },
  { word: 'memory', level: 'cet6', phonetic: '/ˈmeməri/', def: 'n. 记忆，回忆', ex: 'I have a happy memory.', exZh: '我有一个快乐的回忆。' },
  { word: 'present', level: 'cet6', phonetic: '/ˈpreznt/', def: 'n. 现在；adj. 出席的', ex: 'Live in the present.', exZh: '活在当下。' },
  { word: 'forever', level: 'cet6', phonetic: '/fərˈevər/', def: 'adv. 永远，永久', ex: 'I will remember forever.', exZh: '我会永远记得。' },
  { word: 'blossom', level: 'cet6', phonetic: '/ˈblɑːsəm/', def: 'n./v. 花；开花', ex: 'The tree blossoms in spring.', exZh: '树在春天开花。' },
  // ---- 考研 ----
  { word: 'ecosystem', level: 'kaoyan', phonetic: '/ˈiːkoʊsɪstəm/', def: 'n. 生态系统', ex: 'A garden is a small ecosystem.', exZh: '花园是一个小生态系统。' },
  { word: 'resilience', level: 'kaoyan', phonetic: '/rɪˈzɪliəns/', def: 'n. 韧性，恢复力', ex: 'Nature shows great resilience.', exZh: '大自然展现出强大的韧性。' },
  { word: 'delicate', level: 'kaoyan', phonetic: '/ˈdelɪkət/', def: 'adj. 精致的，脆弱的', ex: 'The petal is delicate.', exZh: '花瓣很精致。' },
  // ---- 托福 / 雅思 ----
  { word: 'nectar', level: 'toefl', phonetic: '/ˈnektər/', def: 'n. 花蜜', ex: 'Bees collect nectar from flowers.', exZh: '蜜蜂从花中采集花蜜。' },
  { word: 'pollinate', level: 'toefl', phonetic: '/ˈpɑːlɪneɪt/', def: 'v. 给…授粉', ex: 'Bees pollinate many plants.', exZh: '蜜蜂为许多植物授粉。' },
  { word: 'flourish', level: 'toefl', phonetic: '/ˈflɜːrɪʃ/', def: 'v. 繁荣，茁壮成长', ex: 'Plants flourish in spring.', exZh: '植物在春天茁壮成长。' },
  { word: 'vibrant', level: 'toefl', phonetic: '/ˈvaɪbrənt/', def: 'adj. 生机勃勃的，鲜艳的', ex: 'The garden is vibrant with color.', exZh: '花园色彩鲜艳，生机勃勃。' },
  { word: 'pollinator', level: 'toefl', phonetic: '/ˈpɑːlɪneɪtər/', def: 'n. 传粉者', ex: 'The bee is a pollinator.', exZh: '蜜蜂是传粉者。' },
  // ---- GRE ----
  { word: 'photosynthesis', level: 'gre', phonetic: '/ˌfoʊtoʊˈsɪnθəsɪs/', def: 'n. 光合作用', ex: 'Photosynthesis needs sunlight.', exZh: '光合作用需要阳光。' },
  { word: 'biodiversity', level: 'gre', phonetic: '/ˌbaɪoʊdaɪˈvɜːrsəti/', def: 'n. 生物多样性', ex: 'Gardens help biodiversity.', exZh: '花园有助于生物多样性。' },
  { word: 'tranquil', level: 'gre', phonetic: '/ˈtræŋkwɪl/', def: 'adj. 宁静的，平静的', ex: 'A tranquil morning in the garden.', exZh: '花园里宁静的清晨。' },
  { word: 'serene', level: 'gre', phonetic: '/səˈriːn/', def: 'adj. 安详的，晴朗的', ex: 'The lake looks serene.', exZh: '湖面显得十分安详。' }
];

const LEVEL_NAMES = { cet4: '四级', cet6: '六级', kaoyan: '考研', toefl: '托福雅思', gre: 'GRE', other: '其他' };
const LEVEL_COLORS = { cet4: '#FFC107', cet6: '#26C6DA', kaoyan: '#ffa726', toefl: '#ce93d8', gre: '#ef5350', other: '#6b6b76' };

/** 预置「继续观看」进度（首次打开时填充） */
const PRESET_HISTORY = [
  { videoId: 'v_bunny', position: 297, duration: 596 },
  { videoId: 'v_sintel', position: 178, duration: 888 },
  { videoId: 'v_blazes', position: 11, duration: 15 }
];

/* ================= 三、全局状态 ================= */

const LS_KEY = 'parrot-player-web-demo-v1';

const state = {
  playlist: [],            // 视频项 [{id,title,url,format,duration,poster,sub}]
  currentIndex: -1,        // 当前播放索引
  subtitleTracks: [],      // 字幕轨 [{id,name,cues}]
  activeTrackId: 'builtin',// 当前字幕轨 id
  displayMode: 'bilingual',// bilingual | en | zh | off
  subOffset: 0,            // 字幕时间轴偏移（秒）
  wordbook: [],            // 生词本 [{word, phonetic, def, level, addedAt}]
  favorites: [],           // 收藏句子 [{id, en, zh, videoTitle, time, createdAt}]
  notes: [],               // 笔记 [{id, title, content, updatedAt}]
  shadowing: { count: 0, history: [] }, // 跟读 {次数, 历史[{text, score, time}]}
  history: [],             // 播放记录 [{videoId, position, duration, updatedAt}]
  settings: {
    defaultRate: 1,
    remember: true,
    pauseOnWord: true,
    gestures: true,
    dblStep: 10,
    subSize: 16,
    subColor: '#FFFFFF',
    displayMode: 'bilingual',
    shadowStrict: 'normal' // 跟读评分严格度（演示）
  },
  player: {                // 播放器运行时状态（不持久化）
    zoom: 1,
    locked: false,
    loopA: null, loopB: null, loopCount: 0, loopTarget: 0, loopEnabled: false,
    // 单句循环（与 AB 循环互斥）
    repeatEnabled: false, repeatTarget: 0, repeatCount: 0, repeatStart: null, repeatEnd: null,
    brightness: 0.6,       // 模拟亮度（0-1，仅演示）
    currentCueIndex: -1
  }
};

/* ================= 四、持久化 ================= */

function saveState() {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify({
      playlist: state.playlist.filter(v => !v.local), // 本地 blob URL 不持久化
      wordbook: state.wordbook,
      favorites: state.favorites,
      notes: state.notes,
      shadowing: state.shadowing,
      history: state.history,
      settings: state.settings,
      subtitleTracks: state.subtitleTracks.filter(t => t.imported)
    }));
  } catch (e) { /* 存储失败时静默 */ }
}

function loadState() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(LS_KEY) || '{}'); } catch (e) { saved = {}; }

  state.playlist = SAMPLE_VIDEOS.map(v => ({ ...v }));
  // 恢复用户通过 URL 添加的视频
  if (Array.isArray(saved.playlist)) {
    saved.playlist.forEach(v => { if (!state.playlist.some(x => x.url === v.url)) state.playlist.push(v); });
  }
  state.wordbook = Array.isArray(saved.wordbook) ? saved.wordbook : [];
  state.favorites = Array.isArray(saved.favorites) ? saved.favorites : [];
  state.notes = Array.isArray(saved.notes) ? saved.notes : [];
  state.shadowing = saved.shadowing && typeof saved.shadowing === 'object'
    ? { count: saved.shadowing.count || 0, history: saved.shadowing.history || [] }
    : { count: 0, history: [] };
  state.history = Array.isArray(saved.history) && saved.history.length ? saved.history : PRESET_HISTORY.map(h => ({ ...h, updatedAt: Date.now() }));
  Object.assign(state.settings, saved.settings || {});
  state.subtitleTracks = [
    { id: 'builtin', name: '内置双语（0-30s 循环）', cues: BUILTIN_SUBTITLES }
  ];
  if (Array.isArray(saved.subtitleTracks)) {
    saved.subtitleTracks.forEach(t => { if (t && Array.isArray(t.cues)) state.subtitleTracks.push(t); });
  }
}

/* ================= 五、Toast ================= */

/** 全局 Toast（自动在播放器内/页面顶部定位） */
function toast(msg, duration = 2200) {
  const host = $('#toast-host');
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  host.appendChild(el);
  setTimeout(() => {
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 220);
  }, duration);
}

/* ================= 六、Modal / Sheet / 菜单 ================= */

/** 打开居中 Modal：options {title, text, html, buttons:[{text,cls,onClick}], onClose} */
function openModal(opts) {
  closeModal();
  const root = $('#modal-root');
  const backdrop = document.createElement('div');
  backdrop.className = 'modal-backdrop';
  const card = document.createElement('div');
  card.className = 'modal-card' + (opts.cls ? ' ' + opts.cls : '');
  let html = '';
  if (opts.title) html += '<h3>' + escapeHtml(opts.title) + '</h3>';
  if (opts.text) html += '<div class="modal-text">' + escapeHtml(opts.text).replace(/\n/g, '<br>') + '</div>';
  if (opts.html) html += opts.html;
  if (opts.buttons && opts.buttons.length) {
    html += '<div class="modal-btns">' + opts.buttons.map((b, i) =>
      '<button data-i="' + i + '" class="' + (b.cls || 'btn-ghost') + '">' + escapeHtml(b.text) + '</button>'
    ).join('') + '</div>';
  }
  card.innerHTML = html;
  backdrop.appendChild(card);
  backdrop.addEventListener('pointerdown', e => { if (e.target === backdrop) closeModal(); });
  card.addEventListener('click', e => {
    const btn = e.target.closest('button[data-i]');
    if (!btn) return;
    const b = opts.buttons[+btn.dataset.i];
    if (b && b.onClick) b.onClick();
    if (b && b.close !== false) closeModal();
  });
  root.appendChild(backdrop);
  if (opts.onClose) root._onClose = opts.onClose;
  return card;
}

function closeModal() {
  const root = $('#modal-root');
  if (root._onClose) { const cb = root._onClose; root._onClose = null; cb(); }
  root.innerHTML = '';
}

/** 打开底部 Sheet：options {title, html, onClose} */
function openSheet(opts) {
  closeSheet();
  const root = $('#sheet-root');
  const backdrop = document.createElement('div');
  backdrop.className = 'sheet-backdrop';
  const sheet = document.createElement('div');
  sheet.className = 'sheet';
  let html = '<div class="sheet-grab"></div>';
  if (opts.title) html += '<h3>' + escapeHtml(opts.title) + '</h3>';
  html += opts.html || '';
  sheet.innerHTML = html;
  backdrop.appendChild(sheet);
  backdrop.addEventListener('pointerdown', e => { if (e.target === backdrop) closeSheet(); });
  root.appendChild(backdrop);
  if (opts.onClose) root._onClose = opts.onClose;
  return sheet;
}

function closeSheet() {
  const root = $('#sheet-root');
  if (root._onClose) { const cb = root._onClose; root._onClose = null; cb(); }
  root.innerHTML = '';
}

/** 弹出上下文菜单（长按/右键）：items [{text, cls, onClick}]，坐标 x/y */
function openContextMenu(x, y, items) {
  closeContextMenu();
  const root = $('#context-menu-root');
  const backdrop = document.createElement('div');
  backdrop.className = 'ctx-backdrop';
  const menu = document.createElement('div');
  menu.className = 'ctx-menu';
  menu.innerHTML = items.map((it, i) =>
    '<button data-i="' + i + '" class="' + (it.cls || '') + '">' + escapeHtml(it.text) + '</button>'
  ).join('');
  backdrop.appendChild(menu);
  backdrop.addEventListener('pointerdown', e => { if (e.target === backdrop) closeContextMenu(); });
  menu.addEventListener('click', e => {
    const btn = e.target.closest('button[data-i]');
    if (!btn) return;
    const it = items[+btn.dataset.i];
    closeContextMenu();
    if (it && it.onClick) it.onClick();
  });
  root.appendChild(backdrop);
  // 定位（防止溢出）
  const phoneRect = $('#phone').getBoundingClientRect();
  const mw = 160, mh = items.length * 40 + 10;
  let left = x - phoneRect.left - mw / 2;
  let top = y - phoneRect.top - mh - 8;
  left = clamp(left, 8, phoneRect.width - mw - 8);
  top = clamp(top, 8, phoneRect.height - mh - 8);
  menu.style.left = left + 'px';
  menu.style.top = top + 'px';
}

function closeContextMenu() { $('#context-menu-root').innerHTML = ''; }

/* ================= 七、Tab 路由 ================= */

function switchTab(name) {
  $$('.page').forEach(p => p.classList.toggle('active', p.id === 'page-' + name));
  $$('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
}

/* ================= 八、媒体库 ================= */

function renderLibrary() {
  renderContinueWatching();
  renderPosterGrid($('#search-input').value.trim());
}

/** 继续观看（横向卡片 + 进度条） */
function renderContinueWatching() {
  const row = $('#continue-row');
  const list = state.history
    .map(h => ({ h, v: state.playlist.find(v => v.id === h.videoId) }))
    .filter(x => x.v && x.h.duration > 0 && x.h.position > 1 && x.h.position < x.h.duration - 1)
    .slice(0, 5);
  if (!list.length) {
    row.innerHTML = '<div class="empty-tip" style="padding:14px 4px;width:100%">还没有观看记录，去点开一个视频吧</div>';
    return;
  }
  row.innerHTML = list.map(({ h, v }) => {
    const pct = clamp((h.position / h.duration) * 100, 0, 100);
    const remain = Math.max(0, h.duration - h.position);
    return '<div class="continue-card" data-id="' + v.id + '">' +
      '<div class="continue-poster" style="--poster:' + v.poster + '">' +
        '<span class="fmt">' + escapeHtml(v.format) + '</span>' +
        '<div class="continue-bar"><div style="width:' + pct.toFixed(1) + '%"></div></div>' +
      '</div>' +
      '<div class="continue-title">' + escapeHtml(v.title.trim()) + '</div>' +
      '<div class="continue-sub">剩余 ' + fmtTime(remain) + ' · ' + pct.toFixed(0) + '%</div>' +
    '</div>';
  }).join('');
}

/** 海报墙（支持搜索过滤） */
function renderPosterGrid(keyword = '') {
  const grid = $('#poster-grid');
  const kw = keyword.toLowerCase();
  const list = state.playlist.filter(v => !kw || v.title.toLowerCase().includes(kw));
  $('#video-count').textContent = list.length;
  if (!list.length) {
    grid.innerHTML = '<div class="empty-tip" style="grid-column:1/-1">没有匹配「' + escapeHtml(keyword) + '」的视频</div>';
    return;
  }
  grid.innerHTML = list.map(v => {
    const hist = state.history.find(h => h.videoId === v.id);
    const pct = hist && hist.duration > 0 ? clamp((hist.position / hist.duration) * 100, 0, 100) : 0;
    return '<div class="poster-card" data-id="' + v.id + '">' +
      '<div class="poster" style="--poster:' + v.poster + '">' +
        '<span class="badge badge-format">' + escapeHtml(v.format) + '</span>' +
        '<span class="badge badge-duration">' + escapeHtml(v.duration) + '</span>' +
        (pct > 0 ? '<div class="continue-bar"><div style="width:' + pct.toFixed(1) + '%"></div></div>' : '') +
        '<div class="poster-play"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z" fill="currentColor"/></svg></div>' +
      '</div>' +
      '<div class="poster-title">' + escapeHtml(v.title.trim()) + '</div>' +
      '<div class="poster-sub">' + escapeHtml(v.sub || '') + '</div>' +
    '</div>';
  }).join('');
}

/** 长按/右键海报菜单：收藏、删除 */
function bindPosterCardEvents() {
  const grid = $('#poster-grid');
  let pressTimer = null;

  const startPress = (card, e) => {
    const id = card.dataset.id;
    const item = state.playlist.find(v => v.id === id);
    if (!item) return;
    const rect = card.getBoundingClientRect();
    const x = e.clientX != null ? e.clientX : rect.left + rect.width / 2;
    const y = e.clientY != null ? e.clientY : rect.top + rect.height / 2;
    const open = () => openContextMenu(x, y, [
      { text: '⭐ 收藏视频', onClick: () => toast('已收藏「' + item.title.trim() + '」（演示）') },
      { text: '▶ 播放', onClick: () => openPlayer(state.playlist.indexOf(item)) },
      { text: '🗑 删除', cls: 'danger', onClick: () => deleteVideo(item.id) }
    ]);
    if (e.type === 'contextmenu') { e.preventDefault(); open(); return; }
    pressTimer = setTimeout(open, 500);
  };

  grid.addEventListener('pointerdown', e => {
    const card = e.target.closest('.poster-card');
    if (!card) return;
    startPress(card, e);
  });
  grid.addEventListener('pointerup', () => clearTimeout(pressTimer));
  grid.addEventListener('pointercancel', () => clearTimeout(pressTimer));
  grid.addEventListener('pointerleave', () => clearTimeout(pressTimer));
  grid.addEventListener('contextmenu', e => {
    const card = e.target.closest('.poster-card');
    if (!card) return;
    e.preventDefault();
    startPress(card, e);
  });

  // 点击卡片 → 播放（长按则不触发 click）
  grid.addEventListener('click', e => {
    const card = e.target.closest('.poster-card');
    if (!card) return;
    const idx = state.playlist.findIndex(v => v.id === card.dataset.id);
    if (idx >= 0) openPlayer(idx);
  });
}

/** 删除视频 */
function deleteVideo(id) {
  const idx = state.playlist.findIndex(v => v.id === id);
  if (idx < 0) return;
  const item = state.playlist[idx];
  state.playlist.splice(idx, 1);
  state.history = state.history.filter(h => h.videoId !== id);
  saveState();
  renderLibrary();
  toast('已删除「' + item.title.trim() + '」');
}

/** 通过 URL 添加视频并播放 */
function addVideoByURL(url, autoplay = true) {
  url = (url || '').trim();
  if (!/^https?:\/\//i.test(url)) { toast('请输入以 http(s):// 开头的视频地址'); return; }
  let name = '网络视频';
  try {
    const u = new URL(url);
    name = decodeURIComponent(u.pathname.split('/').pop() || '网络视频') || '网络视频';
  } catch (e) { /* 忽略 */ }
  const ext = (name.split('.').pop() || 'MP4').toUpperCase();
  const existing = state.playlist.findIndex(v => v.url === url);
  if (existing >= 0) {
    if (autoplay) openPlayer(existing);
    else toast('该视频已在媒体库中');
    return;
  }
  const item = {
    id: uid('v'), title: name, url,
    format: /^(MP4|MKV|WEBM|MOV|M4V)$/.test(ext) ? ext : 'MP4',
    duration: '--:--',
    poster: 'linear-gradient(135deg,#1f2933 0%,#3e4c59 100%)',
    sub: '导入的视频'
  };
  state.playlist.unshift(item);
  saveState();
  renderLibrary();
  toast('已添加「' + name + '」');
  if (autoplay) openPlayer(0);
}

/** 添加本地文件（拖入或选择） */
function addVideoFile(file, autoplay = true) {
  if (!file) return;
  const url = URL.createObjectURL(file);
  const ext = (file.name.split('.').pop() || 'MP4').toUpperCase();
  const item = {
    id: uid('v'),
    title: file.name.replace(/\.[^.]+$/, ''),
    url, local: true,
    format: /^(MP4|MKV|WEBM|MOV|M4V)$/.test(ext) ? ext : 'MP4',
    duration: '--:--',
    poster: 'linear-gradient(135deg,#0f3443 0%,#34e89e 130%)',
    sub: '本地文件 · ' + (file.size / 1048576).toFixed(1) + ' MB'
  };
  state.playlist.unshift(item);
  renderLibrary();
  toast('已从本地添加「' + item.title + '」');
  if (autoplay) openPlayer(0);
}

/** 导入 URL 弹窗 */
function openImportURLDialog() {
  const card = openModal({
    title: '导入视频 URL',
    html:
      '<div class="field-label">视频地址（可修改）</div>' +
      '<input class="field" id="import-url-input" type="text" value="' + DEMO_URL + '" spellcheck="false" />' +
      '<div class="field-label">支持 http(s) 直链；MKV 等格式取决于浏览器解码能力。</div>',
    buttons: [
      { text: '取消', cls: 'btn-ghost' },
      { text: '添加并播放', cls: 'btn-primary', onClick: () => addVideoByURL($('#import-url-input').value) }
    ],
    onClose: () => { if (card) card.remove(); }
  });
  setTimeout(() => { const i = $('#import-url-input'); if (i) { i.focus(); i.select(); } }, 60);
}

/** 添加视频弹窗（URL + 本地拖入说明） */
function openAddVideoDialog() {
  const card = openModal({
    title: '添加视频',
    html:
      '<div class="field-label">方式一 · 粘贴视频 URL</div>' +
      '<input class="field" id="add-url-input" type="text" value="' + DEMO_URL + '" spellcheck="false" />' +
      '<div class="field-label">方式二 · 拖入本地文件</div>' +
      '<div class="modal-text" style="margin:0">把本地视频文件（MP4 / MKV / WebM…）直接拖到页面任意位置，即可通过 File API 播放；也可以点击下方按钮选择文件。</div>' +
      '<input type="file" id="add-file-input" accept="video/*" style="display:none" />',
    buttons: [
      { text: '选择本地文件', cls: 'btn-ghost', onClick: () => $('#add-file-input').click() },
      { text: '播放 URL', cls: 'btn-primary', onClick: () => addVideoByURL($('#add-url-input').value) }
    ],
    onClose: () => { if (card) card.remove(); }
  });
  $('#add-file-input').addEventListener('change', e => {
    const f = e.target.files && e.target.files[0];
    if (f) { closeModal(); addVideoFile(f); }
  });
}

/** 全页面拖入支持 */
function bindDragAndDrop() {
  let dragDepth = 0;
  document.addEventListener('dragenter', e => {
    e.preventDefault();
    dragDepth++;
    if (dragDepth === 1) toast('松开即可播放拖入的视频文件');
  });
  document.addEventListener('dragleave', e => {
    e.preventDefault();
    dragDepth = Math.max(0, dragDepth - 1);
  });
  document.addEventListener('dragover', e => e.preventDefault());
  document.addEventListener('drop', e => {
    e.preventDefault();
    dragDepth = 0;
    const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
    if (file && /^video\//.test(file.type)) {
      addVideoFile(file);
    } else if (file) {
      toast('暂只支持拖入视频文件（' + (file.name || '未知') + '）');
    }
  });
}

/* ================= 九、播放器 ================= */

const video = $('#video');
const playerEl = $('#player');
let controlsTimer = null;
let lastHistorySave = 0;

/** 打开播放器 */
function openPlayer(index, startAt = null) {
  if (index < 0 || index >= state.playlist.length) return;
  state.currentIndex = index;
  const item = state.playlist[index];
  if (startAt == null && state.settings.remember) {
    const h = state.history.find(x => x.videoId === item.id);
    if (h && h.position > 1) startAt = h.position;
  }
  playerEl.classList.remove('hidden');
  $('#player-title').textContent = item.title.trim();
  resetPlayerVisualState();
  video.src = item.url;
  video.playbackRate = state.settings.defaultRate;
  updateRateLabel();
  if (startAt != null) {
    video.addEventListener('loadedmetadata', function once() {
      video.removeEventListener('loadedmetadata', once);
      try { video.currentTime = clamp(startAt, 0, video.duration || startAt); } catch (e) { /* 忽略 */ }
    });
  }
  video.play().catch(() => { /* 自动播放被拦截或网络不可用：显示中央按钮 */ updatePlayUI(); });
  showControls();
  toast('正在加载「' + item.title.trim() + '」');
}

/** 关闭播放器 */
function closePlayer() {
  video.pause();
  video.removeAttribute('src');
  video.load();
  playerEl.classList.add('hidden');
  playerEl.classList.remove('controls-hidden');
  state.currentIndex = -1;
  saveHistory(true);
  saveState();
}

/** 重置播放器视觉状态（缩放/循环/锁定） */
function resetPlayerVisualState() {
  state.player.zoom = 1;
  video.style.transform = '';
  state.player.loopA = null;
  state.player.loopB = null;
  state.player.loopEnabled = false;
  state.player.locked = false;
  state.player.currentCueIndex = -1;
  state.player.brightness = 0.6;
  state.player.fallbackTried = false;
  updateABProgress();
  updateLockUI();
}

/* ---------- 控件显隐（5s 自动隐藏 / 单击显隐） ---------- */

function showControls() {
  playerEl.classList.remove('controls-hidden');
  clearTimeout(controlsTimer);
  controlsTimer = setTimeout(hideControls, 5000);
}
function hideControls() {
  clearTimeout(controlsTimer);
  if (!state.player.locked) playerEl.classList.add('controls-hidden');
}

/* ---------- 播放 / 暂停 ---------- */

function togglePlay() {
  if (video.paused) {
    video.play().catch(() => toast('播放失败：网络或浏览器不支持该格式'));
    showControls();
  } else {
    video.pause();
    clearTimeout(controlsTimer);
  }
}

function updatePlayUI() {
  const playing = !video.paused && !video.ended;
  $('#icon-play').classList.toggle('hidden', playing);
  $('#icon-pause').classList.toggle('hidden', !playing);
  $('#center-play').classList.toggle('hidden', playing);
}

/* ---------- 进度条 ---------- */

function updateProgress() {
  const d = video.duration || 0;
  const t = video.currentTime || 0;
  const pct = d ? (t / d) * 100 : 0;
  $('#progress-played').style.width = pct + '%';
  $('#time-current').textContent = fmtTime(t);
  $('#time-total').textContent = fmtTime(d);
  updateBufferBar();
  updateABProgress();
}

function updateBufferBar() {
  const d = video.duration || 0;
  const bar = $('#buffer-bar');
  const fill = $('#buffer-bar-fill');
  let end = 0;
  try {
    if (video.buffered.length) end = video.buffered.end(video.buffered.length - 1);
  } catch (e) { /* 忽略 */ }
  const pct = d ? (end / d) * 100 : 0;
  fill.style.width = pct + '%';
  bar.classList.toggle('active', !!d && end < d - 0.5);
}

/** AB 区间在主进度条上的可视化 */
function updateABProgress() {
  const el = $('#progress-ab');
  const { loopA, loopB } = state.player;
  const d = video.duration || 0;
  if (loopA == null || loopB == null || !d) { el.style.display = 'none'; return; }
  el.style.display = 'block';
  el.style.left = (loopA / d) * 100 + '%';
  el.style.width = ((loopB - loopA) / d) * 100 + '%';
}

/** 进度条拖拽 seek */
function bindProgressDrag() {
  const prog = $('#progress');
  let dragging = false;

  const ratioFromEvent = e => {
    const rect = prog.getBoundingClientRect();
    return clamp((e.clientX - rect.left) / rect.width, 0, 1);
  };
  const applySeek = e => {
    const d = video.duration || 0;
    if (!d) return;
    const target = ratioFromEvent(e) * d;
    video.currentTime = target;
    $('#time-current').textContent = fmtTime(target);
    $('#progress-played').style.width = (target / d) * 100 + '%';
  };

  prog.addEventListener('pointerdown', e => {
    dragging = true;
    prog.classList.add('dragging');
    try { prog.setPointerCapture(e.pointerId); } catch (err) { /* 忽略 */ }
    applySeek(e);
    clearTimeout(controlsTimer);
  });
  prog.addEventListener('pointermove', e => { if (dragging) applySeek(e); });
  const end = e => {
    if (!dragging) return;
    dragging = false;
    prog.classList.remove('dragging');
    try { prog.releasePointerCapture(e.pointerId); } catch (err) { /* 忽略 */ }
    showControls();
  };
  prog.addEventListener('pointerup', end);
  prog.addEventListener('pointercancel', end);
}

/* ---------- 字幕渲染 ---------- */

/** 当前生效的字幕 cues */
function activeCues() {
  const track = state.subtitleTracks.find(t => t.id === state.activeTrackId) || state.subtitleTracks[0];
  return track ? track.cues : [];
}

/** 按时间查找 cue 索引（视频短于字幕跨度时按 0-30s 循环匹配，保证 timeupdate 始终有内容） */
function findCueIndex(t) {
  const cues = activeCues();
  if (!cues.length) return -1;
  let time = t;
  const d = video.duration || 0;
  const span = cues[cues.length - 1].end;
  if (d > 0 && span > d + 0.5) time = t % span; // 循环匹配
  for (let i = 0; i < cues.length; i++) {
    if (time >= cues[i].start && time < cues[i].end) return i;
  }
  return -1;
}

/** 渲染字幕（主字幕可点词） */
function renderSubtitle() {
  const cues = activeCues();
  const idx = state.player.currentCueIndex;
  const enEl = $('#sub-en');
  const zhEl = $('#sub-zh');
  const layer = $('#subtitle-layer');

  if (idx < 0 || state.displayMode === 'off') {
    enEl.innerHTML = ''; zhEl.innerHTML = '';
    layer.classList.remove('interactive');
    return;
  }
  const cue = cues[idx];
  layer.classList.add('interactive');

  if (state.displayMode === 'zh') {
    enEl.innerHTML = '';
    zhEl.innerHTML = escapeHtml(cue.secondary || '');
  } else if (state.displayMode === 'en') {
    enEl.innerHTML = renderWords(cue.primary || '');
    zhEl.innerHTML = '';
  } else {
    enEl.innerHTML = renderWords(cue.primary || '');
    zhEl.innerHTML = escapeHtml(cue.secondary || '');
  }
}

/** 主字幕分词渲染：每个英文单词包成可点击 span */
function renderWords(text) {
  return text.split(/(\s+)/).map(tok => {
    if (tok === '' || /^\s+$/.test(tok)) return escapeHtml(tok);
    const clean = tok.replace(/[^A-Za-z'-]/g, '');
    if (!clean) return escapeHtml(tok);
    return '<span class="word" data-word="' + escapeHtml(clean.toLowerCase()) + '">' + escapeHtml(tok) + '</span>';
  }).join('');
}

/** 字幕层事件：点词卡 / 点句子跳转 / 长按收藏 */
function bindSubtitleEvents() {
  const layer = $('#subtitle-layer');
  let pressTimer = null;
  let pressed = false;

  layer.addEventListener('click', e => {
    if (pressed) { pressed = false; return; }
    const wordEl = e.target.closest('.word');
    if (wordEl) {
      openWordCard(wordEl.dataset.word);
      if (state.settings.pauseOnWord && !video.paused) video.pause();
      return;
    }
    // 点击句子空白处：跳到该句开头
    const idx = state.player.currentCueIndex;
    const cues = activeCues();
    if (idx >= 0 && cues[idx]) {
      video.currentTime = cues[idx].start + 0.01;
      toast('已跳到本句开头');
    }
  });

  const startPress = e => {
    const line = e.target.closest('.sub-line');
    if (!line || !line.textContent.trim()) return;
    pressed = false;
    const x = e.clientX, y = e.clientY;
    pressTimer = setTimeout(() => {
      pressed = true;
      openContextMenu(x, y, [
        { text: '⭐ 收藏本句', onClick: favoriteCurrentSentence },
        { text: '🔊 朗读英文', onClick: () => speakText(($('#sub-en').textContent || '').trim()) },
        { text: '↺ 重听本句', onClick: () => { const c = activeCues()[state.player.currentCueIndex]; if (c) video.currentTime = c.start + 0.01; } }
      ]);
    }, 500);
  };
  layer.addEventListener('pointerdown', startPress);
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(ev =>
    layer.addEventListener(ev, () => clearTimeout(pressTimer)));
  layer.addEventListener('contextmenu', e => {
    e.preventDefault();
    favoriteCurrentSentence();
  });
}

/** 收藏当前字幕句 */
function favoriteCurrentSentence() {
  const cues = activeCues();
  const idx = state.player.currentCueIndex;
  if (idx < 0 || !cues[idx]) { toast('当前没有可收藏的字幕'); return; }
  const cue = cues[idx];
  const item = state.playlist[state.currentIndex];
  state.favorites.unshift({
    id: uid('fav'),
    en: (cue.primary || '').trim(),
    zh: (cue.secondary || '').trim(),
    videoTitle: item ? item.title.trim() : '',
    time: video.currentTime || cue.start,
    createdAt: Date.now()
  });
  saveState();
  renderStudyStats();
  toast('已收藏句子，可在「学习」页查看');
}

/* ---------- 词卡 ---------- */

/** 查词典 */
function lookupWord(word) {
  return DICTIONARY.find(d => d.word === word) || null;
}

/** 打开词卡 Modal */
function openWordCard(word) {
  const entry = lookupWord(word);
  const inBook = state.wordbook.some(w => w.word === word);
  const html =
    '<div class="wc-word">' + escapeHtml(word) +
      (entry ? '<span class="wc-lv lv-' + entry.level + '">' + LEVEL_NAMES[entry.level] + '</span>' : '') +
    '</div>' +
    (entry ? '<div class="wc-phon">' + escapeHtml(entry.phonetic) + '</div>' : '<div class="wc-phon">词典未收录该词</div>') +
    '<div class="wc-def">' + (entry ? escapeHtml(entry.def) : '暂无释义，仍可加入生词本或朗读。') + '</div>' +
    (entry
      ? '<div class="wc-ex">' + escapeHtml(entry.ex) + '<div class="zh">' + escapeHtml(entry.exZh) + '</div></div>'
      : '');
  const card = openModal({
    title: '词卡',
    cls: 'word-card',
    html,
    buttons: [
      { text: '🔊 朗读', cls: 'btn-ghost', onClick: () => speakText(word), close: false },
      inBook
        ? { text: '✓ 已在生词本', cls: 'btn-ghost', close: false }
        : { text: '＋ 加入生词本', cls: 'btn-primary', onClick: () => addToWordbook(word) }
    ],
    onClose: () => card.remove()
  });
}

/** 加入生词本 */
function addToWordbook(word) {
  if (state.wordbook.some(w => w.word === word)) { toast('「' + word + '」已在生词本中'); return; }
  const entry = lookupWord(word);
  state.wordbook.unshift({
    word,
    phonetic: entry ? entry.phonetic : '',
    def: entry ? entry.def : '暂无释义',
    level: entry ? entry.level : 'other',
    addedAt: Date.now()
  });
  saveState();
  renderStudyStats();
  toast('已加入生词本：' + word);
}

/** 语音朗读（SpeechSynthesis） */
function speakText(text) {
  if (!text) return;
  if (!('speechSynthesis' in window)) { toast('当前浏览器不支持语音朗读'); return; }
  try {
    window.speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.lang = /[a-zA-Z]/.test(text) && !/[\u4e00-\u9fff]/.test(text) ? 'en-US' : 'zh-CN';
    u.rate = 0.95;
    window.speechSynthesis.speak(u);
  } catch (e) { toast('朗读失败：' + e.message); }
}

/* ---------- 上一句 / 下一句 ---------- */

function jumpCue(delta) {
  const cues = activeCues();
  if (!cues.length) { toast('当前没有字幕轨'); return; }
  const t = video.currentTime + state.subOffset;
  let idx = findCueIndex(t);
  if (delta > 0) {
    idx = idx < 0 ? 0 : idx + 1;
  } else {
    // 当前句播放超过 1 秒则回到本句开头，否则上一句
    if (idx >= 0 && t - cues[idx].start < 1) idx -= 1;
    if (idx < 0) idx = 0;
  }
  idx = clamp(idx, 0, cues.length - 1);
  video.currentTime = Math.max(0, cues[idx].start + 0.01);
  state.player.currentCueIndex = idx;
  renderSubtitle();
  showControls();
  toast(delta > 0 ? '下一句（' + (idx + 1) + '/' + cues.length + '）' : '上一句（' + (idx + 1) + '/' + cues.length + '）');
}

/* ---------- 更多面板：单句循环 / 截图 / 导出音频 / 播放信息 ---------- */

/** 触发浏览器下载（Blob 或 dataURL 通用） */
function triggerDownload(href, filename, revoke) {
  const a = document.createElement('a');
  a.href = href;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  if (revoke) setTimeout(() => URL.revokeObjectURL(href), 3000);
}

/** 安全文件名：去掉路径非法字符 */
function safeFileName(name) {
  return (name || 'parrot').replace(/[\\/:*?"<>|]+/g, '_').slice(0, 60);
}

/** 单句循环：把当前字幕句重复若干次（0 = 无限，与 AB 循环互斥） */
function setSentenceRepeat(times) {
  const cues = activeCues();
  const idx = state.player.currentCueIndex;
  if (!cues.length || idx < 0) { toast('当前没有可循环的字幕句'); return; }
  const P = state.player;
  // 单句循环与 AB 循环互斥，开启前者时关闭后者
  P.loopEnabled = false;
  P.loopA = P.loopB = null;
  P.repeatEnabled = true;
  P.repeatTarget = Math.max(0, times | 0);
  P.repeatCount = 0;
  P.repeatStart = cues[idx].start;
  P.repeatEnd = cues[idx].end;
  video.currentTime = Math.max(0, P.repeatStart + 0.01);
  video.play().catch(() => {});
  toast(P.repeatTarget > 0 ? ('单句循环 ' + P.repeatTarget + ' 次') : '单句循环：无限重复');
  showControls();
}

/** 停止单句循环 */
function clearSentenceRepeat(notify) {
  const P = state.player;
  P.repeatEnabled = false;
  P.repeatCount = 0;
  P.repeatStart = P.repeatEnd = null;
  if (notify !== false) toast('已停止单句循环');
}

/** 截图：canvas 抓取当前视频帧并下载（含字幕叠加） */
function captureFrame() {
  if (!video.videoWidth || !video.videoHeight) { toast('视频尚未就绪，无法截图'); return; }
  const canvas = document.createElement('canvas');
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  const ctx = canvas.getContext('2d');
  if (!ctx) { toast('当前环境不支持截图'); return; }
  ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

  // 把当前字幕烧进截图，保留学习上下文
  const en = $('#sub-en') ? $('#sub-en').textContent.trim() : '';
  const zh = $('#sub-zh') ? $('#sub-zh').textContent.trim() : '';
  const fs = Math.max(16, Math.round(canvas.width / 34));
  ctx.textAlign = 'center';
  if (zh && state.displayMode !== 'en') {
    ctx.font = '600 ' + fs + 'px system-ui, sans-serif';
    ctx.fillStyle = '#FFC107';
    ctx.shadowColor = 'rgba(0,0,0,.85)';
    ctx.shadowBlur = 8;
    ctx.fillText(zh, canvas.width / 2, canvas.height - fs * 0.9);
  }
  if (en && state.displayMode !== 'zh' && state.displayMode !== 'off') {
    ctx.font = '600 ' + Math.round(fs * 1.15) + 'px system-ui, sans-serif';
    ctx.fillStyle = '#FFFFFF';
    ctx.shadowColor = 'rgba(0,0,0,.85)';
    ctx.shadowBlur = 8;
    ctx.fillText(en, canvas.width / 2, canvas.height - fs * 2.4);
  }

  let dataURL;
  try {
    dataURL = canvas.toDataURL('image/png');
  } catch (e) {
    // 跨域视频会污染 canvas，此时无法读取像素
    toast('跨域视频无法截图，可拖入本地视频后再试');
    return;
  }
  const item = state.playlist[state.currentIndex];
  const name = safeFileName((item && item.title ? item.title : '截图') + '_' + fmtTime(video.currentTime).replace(':', 'm')) + 's.png';
  triggerDownload(dataURL, name, false);
  toast('已保存截图（含当前字幕）');
}

/** 将 AudioBuffer 编码为 16bit PCM WAV */
function encodeWAV(audioBuffer) {
  const numCh = Math.min(2, audioBuffer.numberOfChannels);
  const len = audioBuffer.length;
  const rate = audioBuffer.sampleRate;
  const blockAlign = numCh * 2;
  const dataSize = len * blockAlign;
  const view = new DataView(new ArrayBuffer(44 + dataSize));
  const str = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
  str(0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  str(8, 'WAVE');
  str(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);            // PCM
  view.setUint16(22, numCh, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);
  str(36, 'data');
  view.setUint32(40, dataSize, true);

  const chans = [];
  for (let c = 0; c < numCh; c++) chans.push(audioBuffer.getChannelData(c));
  let off = 44;
  for (let i = 0; i < len; i++) {
    for (let c = 0; c < numCh; c++) {
      const s = Math.max(-1, Math.min(1, chans[c][i]));
      view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
      off += 2;
    }
  }
  return new Blob([view.buffer], { type: 'audio/wav' });
}

/** 导出当前视频音轨为 WAV（浏览器端实现，跨域源会被拦截） */
function exportAudioWAV() {
  const src = video.currentSrc || video.src;
  if (!src) { toast('没有可导出的音频源'); return; }
  toast('正在导出音频，请稍候…', 3000);
  fetch(src)
    .then((r) => r.arrayBuffer())
    .then((buf) => {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) throw new Error('no AudioContext');
      const ac = new AC();
      return new Promise((res, rej) => {
        // Safari 用回调式 decodeAudioData
        const p = ac.decodeAudioData(buf, res, rej);
        if (p && p.then) p.then(res, rej);
      });
    })
    .then((audioBuffer) => {
      const wav = encodeWAV(audioBuffer);
      const item = state.playlist[state.currentIndex];
      triggerDownload(URL.createObjectURL(wav), safeFileName((item && item.title) || '音频') + '.wav', true);
      toast('音频已导出（WAV ' + Math.round(wav.size / 1048576 * 10) / 10 + ' MB）');
    })
    .catch(() => toast('跨域限制无法导出该音频，可拖入本地视频文件后重试'));
}

/** 更多面板：单句循环 / 截图 / 导出音频 / 播放信息 */
function openMorePanel() {
  const P = state.player;
  const item = state.playlist[state.currentIndex];
  const cues = activeCues();
  const idx = P.currentCueIndex;
  const cur = idx >= 0 ? cues[idx] : null;

  const sheet = openSheet({
    title: '更多',
    html:
      '<div class="sheet-section">' +
        '<div class="sheet-label">单句循环（当前句重复朗读）</div>' +
        '<div class="ab-visual" style="margin-top:8px">' +
          '<div class="range" style="left:0%;width:100%;display:' + (cur ? 'block' : 'none') + ';opacity:.5"></div>' +
        '</div>' +
        '<div class="sheet-hint" style="margin:6px 0 10px">' +
          (cur ? '当前句：' + escapeHtml((cur.primary || '').slice(0, 60)) : '当前没有选中字幕句') +
        '</div>' +
        '<div class="ab-actions">' +
          '<button id="more-rep-3">×3 次</button>' +
          '<button id="more-rep-5">×5 次</button>' +
          '<button id="more-rep-inf">无限</button>' +
          '<button id="more-rep-stop" class="' + (P.repeatEnabled ? 'on' : '') + '">停止</button>' +
        '</div>' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">导出</div>' +
        '<div class="ab-actions">' +
          '<button id="more-shot">📷 截图（含字幕）</button>' +
          '<button id="more-audio">🎵 导出音频 WAV</button>' +
        '</div>' +
        '<div class="sheet-hint" style="margin-top:8px">截图与音频导出受浏览器跨域策略限制，本地拖入的视频可正常使用</div>' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">播放信息</div>' +
        '<div class="sheet-hint" style="line-height:1.7">' +
          '标题：' + escapeHtml((item && item.title) || '—') + '<br>' +
          '分辨率：' + (video.videoWidth || 0) + ' × ' + (video.videoHeight || 0) + '<br>' +
          '时长：' + fmtTime(video.duration || 0) + '<br>' +
          '字幕：' + cues.length + ' 条' + (state.subOffset ? ('（偏移 ' + state.subOffset.toFixed(1) + 's）') : '') + '<br>' +
          '倍速：×' + (video.playbackRate || 1).toFixed(2) + '　音量：' + Math.round((video.volume || 0) * 100) + '%<br>' +
          '循环：' + (P.repeatEnabled ? '单句循环 ' + (P.repeatTarget || '无限') : (P.loopEnabled ? 'AB 循环' : '未开启')) +
        '</div>' +
      '</div>',
    onClose: () => sheet.remove()
  });

  sheet.addEventListener('click', (e) => {
    const btn = e.target.closest('button');
    if (!btn) return;
    const id = btn.id;
    if (id === 'more-rep-3') setSentenceRepeat(3);
    else if (id === 'more-rep-5') setSentenceRepeat(5);
    else if (id === 'more-rep-inf') setSentenceRepeat(0);
    else if (id === 'more-rep-stop') clearSentenceRepeat();
    else if (id === 'more-shot') captureFrame();
    else if (id === 'more-audio') exportAudioWAV();
    else return;
    closeSheet();
  });
}

/* ---------- 倍速面板 ---------- */

function updateRateLabel() {
  const r = video.playbackRate || 1;
  $('#btn-rate').textContent = '倍速 ×' + r.toFixed(2).replace(/0$/, '');
  $('#time-rate-label').textContent = '×' + r.toFixed(2).replace(/0$/, '');
}

function openRatePanel() {
  const cur = video.playbackRate || 1;
  const sheet = openSheet({
    title: '播放倍速',
    html:
      '<div class="rate-display" id="rate-display">×' + cur.toFixed(2) + '</div>' +
      '<input type="range" id="rate-slider" min="0.2" max="2.5" step="0.05" value="' + cur + '" style="width:100%" />' +
      '<div style="display:flex;justify-content:space-between;font-size:11px;color:var(--text-3);margin-top:4px"><span>0.2×</span><span>1.0×</span><span>2.5×</span></div>' +
      '<div class="rate-presets">' +
        [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5].map(v =>
          '<button data-v="' + v + '" class="' + (Math.abs(v - cur) < 0.001 ? 'on' : '') + '">' + v.toFixed(2).replace(/0$/, '') + '×</button>'
        ).join('') +
      '</div>',
    onClose: () => sheet.remove()
  });
  const apply = v => {
    v = clamp(+v, 0.2, 2.5);
    video.playbackRate = v;
    $('#rate-display').textContent = '×' + v.toFixed(2);
    $('#rate-slider').value = v;
    updateRateLabel();
    $$('.rate-presets button', sheet).forEach(b =>
      b.classList.toggle('on', Math.abs(+b.dataset.v - v) < 0.001));
  };
  $('#rate-slider', sheet).addEventListener('input', e => apply(e.target.value));
  sheet.addEventListener('click', e => {
    const btn = e.target.closest('.rate-presets button');
    if (btn) apply(btn.dataset.v);
  });
}

/* ---------- AB 循环面板 ---------- */

function openABPanel() {
  const { loopA, loopB, loopTarget } = state.player;
  const d = video.duration || 0;
  const sheet = openSheet({
    title: 'AB 循环',
    html:
      '<div class="ab-times">' +
        '<div class="ab-time-box"><div class="t" id="ab-a">' + (loopA != null ? fmtTime(loopA) : '--:--') + '</div><div class="l">A 点（起点）</div></div>' +
        '<div class="ab-time-box"><div class="t" id="ab-b">' + (loopB != null ? fmtTime(loopB) : '--:--') + '</div><div class="l">B 点（终点）</div></div>' +
      '</div>' +
      '<div class="ab-visual" id="ab-visual">' +
        '<div class="range" id="ab-range"></div>' +
        '<div class="cursor" id="ab-cursor" style="left:0%"></div>' +
        '<span class="lbl" style="left:8px">0:00</span><span class="lbl" style="right:8px">' + fmtTime(d) + '</span>' +
      '</div>' +
      '<div class="ab-actions">' +
        '<button id="ab-set-a">📍 设 A（当前时间）</button>' +
        '<button id="ab-set-b">🏁 设 B（当前时间）</button>' +
        '<button id="ab-clear" class="' + (loopA != null ? 'on' : '') + '">✕ 清除</button>' +
      '</div>' +
      '<div class="sheet-section" style="margin-top:18px">' +
        '<div class="sheet-label">循环次数（0 = 无限循环）</div>' +
        '<div class="stepper">' +
          '<button id="ab-minus">−</button>' +
          '<div class="v" id="ab-count">' + loopTarget + '</div>' +
          '<button id="ab-plus">＋</button>' +
          '<span class="hint">到 B 点自动回跳 A 点</span>' +
        '</div>' +
      '</div>' +
      '<div class="ab-actions">' +
        '<button id="ab-enable" class="' + (state.player.loopEnabled && loopA != null && loopB != null ? 'on' : '') + '">' +
          (state.player.loopEnabled && loopA != null && loopB != null ? '⏺ AB 循环已开启（点击关闭）' : '▶ 开启 AB 循环') +
        '</button>' +
      '</div>',
    onClose: () => sheet.remove()
  });

  const refresh = () => {
    const a = state.player.loopA, b = state.player.loopB;
    $('#ab-a').textContent = a != null ? fmtTime(a) : '--:--';
    $('#ab-b').textContent = b != null ? fmtTime(b) : '--:--';
    $('#ab-count').textContent = state.player.loopTarget;
    const range = $('#ab-range');
    if (a != null && b != null && d) {
      range.style.display = 'block';
      range.style.left = (a / d) * 100 + '%';
      range.style.width = ((b - a) / d) * 100 + '%';
    } else range.style.display = 'none';
    const on = state.player.loopEnabled && a != null && b != null;
    const enableBtn = $('#ab-enable');
    enableBtn.classList.toggle('on', on);
    enableBtn.textContent = on ? '⏺ AB 循环已开启（点击关闭）' : '▶ 开启 AB 循环';
    updateABProgress();
  };

  sheet.addEventListener('click', e => {
    const id = e.target.id;
    if (id === 'ab-set-a') {
      state.player.loopA = video.currentTime;
      if (state.player.loopB != null && state.player.loopB <= state.player.loopA) state.player.loopB = null;
      state.player.loopEnabled = state.player.loopA != null && state.player.loopB != null;
      toast('已设 A 点：' + fmtTime(state.player.loopA));
      refresh();
    } else if (id === 'ab-set-b') {
      state.player.loopB = video.currentTime;
      if (state.player.loopA != null && state.player.loopA >= state.player.loopB) { toast('B 点需晚于 A 点'); state.player.loopB = null; }
      state.player.loopEnabled = state.player.loopA != null && state.player.loopB != null;
      toast(state.player.loopB != null ? '已设 B 点：' + fmtTime(state.player.loopB) : '');
      refresh();
    } else if (id === 'ab-clear') {
      state.player.loopA = state.player.loopB = null;
      state.player.loopEnabled = false;
      state.player.loopCount = 0;
      toast('已清除 AB 循环');
      refresh();
    } else if (id === 'ab-minus') {
      state.player.loopTarget = Math.max(0, state.player.loopTarget - 1);
      refresh();
    } else if (id === 'ab-plus') {
      state.player.loopTarget = Math.min(99, state.player.loopTarget + 1);
      refresh();
    } else if (id === 'ab-enable') {
      const { loopA, loopB } = state.player;
      if (state.player.loopEnabled) {
        state.player.loopEnabled = false;
        toast('AB 循环已关闭');
      } else if (loopA == null || loopB == null) {
        toast('请先设置 A 点和 B 点');
      } else {
        state.player.loopEnabled = true;
        state.player.loopCount = 0;
        toast('AB 循环开启：' + fmtTime(loopA) + ' → ' + fmtTime(loopB));
      }
      refresh();
    }
  });
  // 面板打开期间更新光标
  const timer = setInterval(() => {
    if (!document.body.contains(sheet)) { clearInterval(timer); return; }
    const cur = $('#ab-cursor');
    if (cur && d) cur.style.left = ((video.currentTime / d) * 100).toFixed(2) + '%';
  }, 200);
}

/* ---------- 字幕设置面板 ---------- */

function openSubtitlePanel() {
  const s = state.settings;
  const sheet = openSheet({
    title: '字幕设置',
    html:
      '<div class="sheet-section">' +
        '<div class="sheet-label">显示模式</div>' +
        '<div class="segmented" id="sub-mode" style="width:100%">' +
          ['bilingual', 'en', 'zh', 'off'].map(m =>
            '<button data-v="' + m + '" class="' + (state.displayMode === m ? 'on' : '') + '">' +
            ({ bilingual: '双语', en: '仅英文', zh: '仅中文', off: '隐藏' })[m] + '</button>'
          ).join('') +
        '</div>' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">字号 <span id="sub-size-val" style="color:var(--cyan)">' + s.subSize + 'px</span></div>' +
        '<input type="range" id="sub-size" min="13" max="22" step="1" value="' + s.subSize + '" style="width:100%" />' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">主字幕颜色</div>' +
        '<div class="color-dots" id="sub-color">' +
          ['#FFFFFF', '#FFC107', '#26C6DA'].map(c =>
            '<button class="color-dot ' + (s.subColor === c ? 'on' : '') + '" data-v="' + c + '" style="background:' + c + '"></button>'
          ).join('') +
        '</div>' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">时间轴微调</div>' +
        '<div class="offset-row">' +
          '<button class="mini-btn" id="sub-off-minus">− 0.5s</button>' +
          '<div class="v" id="sub-off-val">' + (state.subOffset >= 0 ? '+' : '') + state.subOffset.toFixed(1) + 's</div>' +
          '<button class="mini-btn" id="sub-off-plus">＋ 0.5s</button>' +
        '</div>' +
      '</div>' +
      '<div class="sheet-section">' +
        '<div class="sheet-label">字幕轨</div>' +
        '<div class="sub-track-row">' +
          '<select id="sub-track-select">' +
            state.subtitleTracks.map(t =>
              '<option value="' + t.id + '" ' + (t.id === state.activeTrackId ? 'selected' : '') + '>' +
              escapeHtml(t.name) + '（' + t.cues.length + ' 条）</option>'
            ).join('') +
          '</select>' +
          '<button class="mini-btn" id="sub-import">导入 .srt</button>' +
        '</div>' +
        '<input type="file" id="sub-file-input" accept=".srt" style="display:none" />' +
      '</div>',
    onClose: () => sheet.remove()
  });

  const applyMode = m => {
    state.displayMode = m;
    $$('#sub-mode button', sheet).forEach(b => b.classList.toggle('on', b.dataset.v === m));
    renderSubtitle();
  };
  const applySize = v => {
    state.settings.subSize = +v;
    $('#sub-size-val').textContent = v + 'px';
    applySubtitleStyle();
  };
  const applyColor = c => {
    state.settings.subColor = c;
    $$('#sub-color .color-dot', sheet).forEach(b => b.classList.toggle('on', b.dataset.v === c));
    applySubtitleStyle();
  };

  sheet.addEventListener('click', e => {
    const btn = e.target.closest('button');
    if (!btn) return;
    if (btn.dataset.v && btn.parentElement.id === 'sub-mode') applyMode(btn.dataset.v);
    else if (btn.dataset.v && btn.parentElement.id === 'sub-color') applyColor(btn.dataset.v);
    else if (btn.id === 'sub-off-minus') { state.subOffset = clamp(state.subOffset - 0.5, -30, 30); $('#sub-off-val').textContent = (state.subOffset >= 0 ? '+' : '') + state.subOffset.toFixed(1) + 's'; }
    else if (btn.id === 'sub-off-plus') { state.subOffset = clamp(state.subOffset + 0.5, -30, 30); $('#sub-off-val').textContent = (state.subOffset >= 0 ? '+' : '') + state.subOffset.toFixed(1) + 's'; }
    else if (btn.id === 'sub-import') $('#sub-file-input').click();
  });
  $('#sub-size', sheet).addEventListener('input', e => applySize(e.target.value));
  $('#sub-track-select', sheet).addEventListener('change', e => {
    state.activeTrackId = e.target.value;
    state.player.currentCueIndex = -1;
    renderSubtitle();
    toast('已切换字幕轨');
  });
  $('#sub-file-input', sheet).addEventListener('change', e => {
    const f = e.target.files && e.target.files[0];
    if (f) importSRTFile(f);
  });
}

/** 应用字幕样式（字号 / 颜色）到 CSS 变量 */
function applySubtitleStyle() {
  document.documentElement.style.setProperty('--sub-size', state.settings.subSize + 'px');
  document.documentElement.style.setProperty('--sub-color', state.settings.subColor);
}

/* ---------- SRT 解析与导入 ---------- */

/** 解析时间码 HH:mm:ss,SSS → 秒 */
function parseTimecode(s) {
  const m = String(s).trim().match(/(\d+):(\d+):(\d+)[,.](\d+)/);
  if (!m) return NaN;
  return +m[1] * 3600 + +m[2] * 60 + +m[3] + +m[4] / 1000;
}

/** 解析 SRT 文本 → cues；CJK 行自动作为译文（与 iOS 版逻辑一致） */
function parseSRT(text) {
  const normalized = String(text).replace(/\r/g, '');
  const blocks = normalized.split(/\n\s*\n/);
  const cues = [];
  blocks.forEach(block => {
    const lines = block.split('\n').map(l => l.trim()).filter(l => l !== '');
    if (lines.length < 2) return;
    const timeIdx = lines.findIndex(l => l.includes('-->'));
    if (timeIdx === -1) return;
    const parts = lines[timeIdx].split('-->');
    if (parts.length < 2) return;
    const start = parseTimecode(parts[0]);
    const end = parseTimecode(parts[1]);
    if (!isFinite(start) || !isFinite(end) || end <= start) return;
    const textLines = lines.slice(timeIdx + 1);
    if (!textLines.length) return;
    let primary = '', secondary = '';
    textLines.forEach(line => {
      if (/[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]/.test(line)) {
        secondary += (secondary ? '\n' : '') + line;   // 含 CJK → 译文行
      } else {
        primary += (primary ? '\n' : '') + line;       // 其余 → 主字幕
      }
    });
    cues.push({ start, end, primary, secondary });
  });
  return cues;
}

/** 导入 SRT 文件 */
function importSRTFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    const cues = parseSRT(reader.result);
    if (!cues.length) { toast('SRT 解析失败：未找到有效字幕条目'); return; }
    const track = { id: uid('track'), name: file.name.replace(/\.srt$/i, ''), cues, imported: true };
    state.subtitleTracks.push(track);
    state.activeTrackId = track.id;
    state.player.currentCueIndex = -1;
    saveState();
    closeSheet();
    renderSubtitle();
    toast('已导入字幕「' + file.name + '」（' + cues.length + ' 条）');
  };
  reader.onerror = () => toast('文件读取失败');
  reader.readAsText(file, 'UTF-8');
}

/* ---------- 播放列表抽屉 ---------- */

function openPlaylistDrawer() {
  const sheet = openSheet({
    title: '播放列表',
    html:
      state.playlist.map((v, i) =>
        '<div class="playlist-item ' + (i === state.currentIndex ? 'playing' : '') + '" data-i="' + i + '">' +
          '<div class="pl-poster" style="--poster:' + v.poster + '">' + escapeHtml(v.format) + '</div>' +
          '<div class="pl-body"><b>' + escapeHtml(v.title.trim()) + '</b><span>' + escapeHtml(v.duration) + ' · ' + escapeHtml(v.sub || '') + '</span></div>' +
          (i === state.currentIndex ? '<span class="playing-tag">播放中</span>' : '') +
        '</div>'
      ).join('') +
      '<div class="volume-tip" id="volume-tip">🔊 系统音量：iOS 版此处挂载 MPVolumeView 调节系统音量；Web 演示中请在视频区右侧上下滑动调节软件音量。</div>',
    onClose: () => sheet.remove()
  });
  sheet.addEventListener('click', e => {
    if (e.target.closest('#volume-tip')) { toast('Web 演示暂不支持调节系统音量'); return; }
    const item = e.target.closest('.playlist-item');
    if (!item) return;
    const i = +item.dataset.i;
    if (i === state.currentIndex) { closeSheet(); return; }
    closeSheet();
    openPlayer(i);
  });
}

/* ---------- 顶部按钮：投屏 / 画中画 / 锁定 / 更多 ---------- */

function togglePiP() {
  if (document.pictureInPictureElement) {
    document.exitPictureInPicture().catch(() => {});
    return;
  }
  if (!video.requestPictureInPicture) { toast('当前浏览器不支持画中画（演示）'); return; }
  video.requestPictureInPicture()
    .then(() => toast('已进入画中画'))
    .catch(() => toast('画中画启动失败（演示环境限制）'));
}

function toggleLock() {
  state.player.locked = !state.player.locked;
  updateLockUI();
  toast(state.player.locked ? '已锁定：手势与控制已禁用' : '已解锁');
}

function updateLockUI() {
  const locked = state.player.locked;
  $('#btn-lock').style.color = locked ? 'var(--yellow)' : '';
  $('#unlock-btn').classList.toggle('hidden', !locked);
  if (locked) hideControls();
  else showControls();
}

/* ---------- HUD（手势反馈） ---------- */

let hudTimer = null;
function showHUD(icon, text, sub, sticky = false) {
  const hud = $('#hud');
  $('#hud-icon').textContent = icon || '';
  $('#hud-text').textContent = text || '';
  const oldSub = $('#hud-sub');
  if (oldSub) oldSub.remove();
  if (sub) {
    const s = document.createElement('div');
    s.id = 'hud-sub';
    s.textContent = sub;
    hud.appendChild(s);
  }
  hud.classList.remove('hidden');
  hud.classList.remove('show');
  void hud.offsetWidth; // 重启动画
  hud.classList.add('show');
  clearTimeout(hudTimer);
  if (!sticky) hudTimer = setTimeout(hideHUD, 900);
}
function hideHUD() { $('#hud').classList.add('hidden'); }

/* ---------- 手势：单击 / 双击 / 拖动 / 捏合 ---------- */

function bindGestures() {
  const layer = $('#gesture-layer');
  const P = state.player;

  let pointers = new Map();     // pointerId -> {x, y}
  let gestureMode = null;       // null | 'seek' | 'volume' | 'brightness'
  let startX = 0, startY = 0, startTime = 0;
  let startVolume = 1, startBrightness = 0.6;
  let downAt = 0;
  let lastTapAt = 0;
  let tapTimer = null;
  let pinchStartDist = 0, pinchStartZoom = 1;
  let moved = false;

  const wrapW = () => layer.getBoundingClientRect().width;

  layer.addEventListener('pointerdown', e => {
    if (P.locked || !state.settings.gestures) return;
    try { layer.setPointerCapture(e.pointerId); } catch (err) { /* 合成事件无活动指针，忽略 */ }
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (pointers.size === 2) {
      // 双指 → 捏合缩放
      const pts = Array.from(pointers.values());
      pinchStartDist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      pinchStartZoom = P.zoom;
      gestureMode = 'pinch';
      clearTimeout(tapTimer);
      return;
    }
    if (pointers.size > 1) return;

    moved = false;
    gestureMode = null;
    startX = e.clientX; startY = e.clientY;
    startTime = video.currentTime;
    startVolume = video.volume;
    startBrightness = P.brightness;
    downAt = Date.now();

    // 双击检测（快进 / 快退）
    if (Date.now() - lastTapAt < 300) {
      clearTimeout(tapTimer);
      lastTapAt = 0;
      const step = state.settings.dblStep;
      const rect = layer.getBoundingClientRect();
      const leftHalf = e.clientX - rect.left < rect.width / 2;
      seekBy(leftHalf ? -step : step);
      showHUD(leftHalf ? '⏪' : '⏩', step + ' 秒', leftHalf ? '快退' : '快进');
      return;
    }
    lastTapAt = Date.now();
    // 延迟触发单击（显隐控件），等待可能的双击
    tapTimer = setTimeout(() => {
      if (gestureMode == null && !moved && Date.now() - downAt < 400) {
        if (playerEl.classList.contains('controls-hidden')) showControls();
        else hideControls();
      }
    }, 280);
  });

  layer.addEventListener('pointermove', e => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (P.locked || !state.settings.gestures) return;

    // 捏合缩放
    if (gestureMode === 'pinch' && pointers.size >= 2) {
      const pts = Array.from(pointers.values());
      const dist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      if (pinchStartDist > 0) {
        const zoom = clamp(pinchStartZoom * (dist / pinchStartDist), 1, 3);
        setZoom(zoom);
      }
      return;
    }
    if (pointers.size > 1) return;

    const dx = e.clientX - startX;
    const dy = e.clientY - startY;
    if (gestureMode == null) {
      if (Math.abs(dx) > 12 && Math.abs(dx) > Math.abs(dy)) gestureMode = 'seek';
      else if (Math.abs(dy) > 12) {
        const rect = layer.getBoundingClientRect();
        gestureMode = (startX - rect.left < rect.width / 2) ? 'brightness' : 'volume';
      } else return;
      moved = true;
      clearTimeout(tapTimer);
    }

    if (gestureMode === 'seek') {
      const d = video.duration || 0;
      if (!d) return;
      const delta = (dx / wrapW()) * d;      // 全宽 = 整个视频
      const target = clamp(startTime + delta, 0, d);
      video.currentTime = target;
      const off = Math.round(delta);
      showHUD(off >= 0 ? '⏩' : '⏪',
        fmtTime(target) + ' / ' + fmtTime(d),
        (off >= 0 ? '快进 ' : '快退 ') + Math.abs(off) + ' 秒', true);
    } else if (gestureMode === 'volume') {
      const v = clamp(startVolume - dy / 220, 0, 1);
      video.volume = v;
      video.muted = v === 0;
      showHUD(v === 0 ? '🔇' : '🔊', Math.round(v * 100) + '%', '音量', true);
    } else if (gestureMode === 'brightness') {
      const b = clamp(startBrightness - dy / 220, 0.05, 1);
      P.brightness = b;
      showHUD('☀️', Math.round(b * 100) + '%', '亮度（演示）', true);
    }
  });

  const endPointer = e => {
    pointers.delete(e.pointerId);
    if (pointers.size === 0) {
      if (gestureMode === 'seek') {
        showHUD('⏱', fmtTime(video.currentTime), '已跳转');
        hudTimer = setTimeout(hideHUD, 600);
      } else if (gestureMode) {
        hudTimer = setTimeout(hideHUD, 700);
      }
      gestureMode = null;
      showControls();
    } else if (pointers.size < 2 && gestureMode === 'pinch') {
      gestureMode = null;
      // 捏合结束后重置单指起点，避免跳动
      const p = Array.from(pointers.values())[0];
      if (p) { startX = p.x; startY = p.y; startTime = video.currentTime; }
    }
  };
  layer.addEventListener('pointerup', endPointer);
  layer.addEventListener('pointercancel', endPointer);

  // Ctrl + 滚轮 = 缩放
  layer.addEventListener('wheel', e => {
    if (!e.ctrlKey || !state.settings.gestures || P.locked) return;
    e.preventDefault();
    setZoom(clamp(P.zoom * (1 - e.deltaY * 0.002), 1, 3));
  }, { passive: false });
}

/** 画面缩放 */
function setZoom(z) {
  state.player.zoom = z;
  video.style.transform = 'scale(' + z.toFixed(2) + ')';
  showHUD('🔍', Math.round(z * 100) + '%', '画面缩放（双击重置）');
  if (Math.abs(z - 1) < 0.01) {
    // 接近 1 时下一次双击恢复（简单处理：直接保持）
  }
}

/** 相对跳转（快进/快退） */
function seekBy(sec) {
  const d = video.duration || 0;
  video.currentTime = clamp(video.currentTime + sec, 0, d || video.currentTime + sec);
  updateProgress();
}

/* ---------- 播放历史 ---------- */

function saveHistory(force = false) {
  if (!state.settings.remember) return;
  const idx = state.currentIndex;
  if (idx < 0) return;
  const item = state.playlist[idx];
  const d = video.duration || 0;
  const t = video.currentTime || 0;
  if (!d || t < 1) return;
  const now = Date.now();
  if (!force && now - lastHistorySave < 4000) return;
  lastHistorySave = now;
  const rec = state.history.find(h => h.videoId === item.id);
  if (rec) { rec.position = t; rec.duration = d; rec.updatedAt = now; }
  else state.history.unshift({ videoId: item.id, position: t, duration: d, updatedAt: now });
  renderContinueWatching();
}

/* ---------- 本地演示视频（远程不可达时自动生成） ---------- */

let fallbackVideoURL = null;
let fallbackPromise = null;

/** 绘制一帧「花园蜜蜂」演示画面（canvas，供本地片段使用） */
function drawFallbackFrame(ctx, t) {
  const W = 640, H = 360;
  // 天空渐变（随计时轻微变化，模拟晨光）
  const sky = ctx.createLinearGradient(0, 0, 0, H);
  const glow = 0.5 + 0.5 * Math.sin(t / 6);
  sky.addColorStop(0, '#1b4332');
  sky.addColorStop(0.55, '#2d6a4f');
  sky.addColorStop(1, '#95d5b2');
  ctx.fillStyle = sky;
  ctx.fillRect(0, 0, W, H);
  // 太阳
  ctx.fillStyle = 'rgba(255, 193, 7, ' + (0.55 + 0.2 * glow) + ')';
  ctx.beginPath();
  ctx.arc(W - 110, 80, 34 + 3 * glow, 0, Math.PI * 2);
  ctx.fill();
  // 远山
  ctx.fillStyle = 'rgba(20, 60, 50, 0.85)';
  ctx.beginPath();
  ctx.moveTo(0, H * 0.72);
  ctx.quadraticCurveTo(W * 0.25, H * 0.55, W * 0.55, H * 0.72);
  ctx.quadraticCurveTo(W * 0.8, H * 0.85, W, H * 0.68);
  ctx.lineTo(W, H); ctx.lineTo(0, H);
  ctx.closePath();
  ctx.fill();
  // 花朵（茎 + 花瓣 + 花心）
  const fx = W * 0.5, fy = H * 0.62;
  ctx.strokeStyle = '#1f7a4d';
  ctx.lineWidth = 5;
  ctx.beginPath();
  ctx.moveTo(fx, fy + 90);
  ctx.quadraticCurveTo(fx + 14, fy + 40, fx, fy);
  ctx.stroke();
  // 叶子
  ctx.fillStyle = '#2f9e63';
  ctx.beginPath();
  ctx.ellipse(fx - 26, fy + 52, 20, 9, -0.5, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.ellipse(fx + 28, fy + 66, 18, 8, 0.5, 0, Math.PI * 2);
  ctx.fill();
  // 花瓣
  const petals = 8;
  for (let i = 0; i < petals; i++) {
    const a = (i / petals) * Math.PI * 2 + t * 0.15;
    const px = fx + Math.cos(a) * 26, py = fy + Math.sin(a) * 26;
    ctx.fillStyle = i % 2 ? '#ff8fa3' : '#ffc2d1';
    ctx.beginPath();
    ctx.ellipse(px, py, 15, 10, a, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.fillStyle = '#FFC107';
  ctx.beginPath();
  ctx.arc(fx, fy, 12, 0, Math.PI * 2);
  ctx.fill();
  // 蜜蜂：围绕花朵做利萨茹轨迹飞行，翅膀快速振动
  const bx = fx + Math.sin(t * 1.4) * 95 + Math.sin(t * 0.7) * 25;
  const by = fy - 55 + Math.cos(t * 1.1) * 45;
  const flap = Math.sin(t * 40) * 7;
  ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
  ctx.beginPath();
  ctx.ellipse(bx - 8, by - 8 + flap, 11, 5, -0.6, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.ellipse(bx + 8, by - 8 - flap, 11, 5, 0.6, 0, Math.PI * 2);
  ctx.fill();
  // 身体（黄黑条纹）
  ctx.fillStyle = '#FFC107';
  ctx.beginPath();
  ctx.ellipse(bx, by, 15, 10, Math.sin(t) * 0.2, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#222';
  ctx.fillRect(bx - 6, by - 9, 4, 18);
  ctx.fillRect(bx + 2, by - 9, 4, 18);
  ctx.fillStyle = '#222';
  ctx.beginPath();
  ctx.arc(bx + 13, by - 2, 4.5, 0, Math.PI * 2);
  ctx.fill();
  // 时间角标（便于演示核对字幕）
  ctx.fillStyle = 'rgba(0,0,0,0.45)';
  ctx.fillRect(8, 8, 118, 26);
  ctx.fillStyle = '#fff';
  ctx.font = '14px sans-serif';
  ctx.fillText('演示片段 ' + t.toFixed(1) + 's', 16, 26);
}

/** 生成 30 秒本地演示 WebM（与内置字幕 0-30s 对齐），失败返回 rejected */
function generateFallbackVideo() {
  if (fallbackVideoURL) return Promise.resolve(fallbackVideoURL);
  if (fallbackPromise) return fallbackPromise;
  fallbackPromise = new Promise((resolve, reject) => {
    if (typeof MediaRecorder === 'undefined' || !HTMLCanvasElement.prototype.captureStream) {
      reject(new Error('浏览器不支持本地片段生成'));
      return;
    }
    const canvas = document.createElement('canvas');
    canvas.width = 640;
    canvas.height = 360;
    const ctx = canvas.getContext('2d');
    const stream = canvas.captureStream(30);
    let mime = 'video/webm;codecs=vp8';
    if (!MediaRecorder.isTypeSupported(mime)) mime = 'video/webm';
    const rec = new MediaRecorder(stream, { mimeType: mime });
    const chunks = [];
    rec.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data); };
    rec.onstop = () => {
      fallbackVideoURL = URL.createObjectURL(new Blob(chunks, { type: 'video/webm' }));
      resolve(fallbackVideoURL);
    };
    rec.onerror = () => reject(new Error('录制失败'));
    const DURATION = 30; // 与内置字幕时间范围一致
    const t0 = performance.now();
    const draw = now => {
      const t = (now - t0) / 1000;
      if (t >= DURATION) { try { rec.stop(); } catch (e) { reject(e); } return; }
      drawFallbackFrame(ctx, t);
      requestAnimationFrame(draw);
    };
    rec.start();
    requestAnimationFrame(draw);
  });
  return fallbackPromise;
}

/* ---------- 视频事件绑定 ---------- */

function bindVideoEvents() {
  video.addEventListener('loadedmetadata', () => {
    updateProgress();
    updateBufferBar();
    // 元数据就绪后立即渲染当前时间的字幕（暂停态也能显示）
    const idx = findCueIndex(video.currentTime + state.subOffset);
    state.player.currentCueIndex = idx;
    renderSubtitle();
  });
  video.addEventListener('timeupdate', () => {
    updateProgress();
    // 字幕切换
    const t = video.currentTime + state.subOffset;
    const idx = findCueIndex(t);
    if (idx !== state.player.currentCueIndex) {
      state.player.currentCueIndex = idx;
      renderSubtitle();
    }
    // AB 循环：到 B 回跳 A
    const P = state.player;
    if (P.loopEnabled && P.loopA != null && P.loopB != null &&
        video.currentTime >= P.loopB - 0.05) {
      video.currentTime = P.loopA;
      P.loopCount++;
      if (P.loopTarget > 0 && P.loopCount >= P.loopTarget) {
        P.loopEnabled = false;
        P.loopA = P.loopB = null;
        updateABProgress();
        toast('AB 循环完成（' + P.loopTarget + ' 次）');
      }
    }
    // 单句循环：播到句尾回跳句首，达到设定次数后停止
    if (P.repeatEnabled && P.repeatStart != null && P.repeatEnd != null &&
        video.currentTime >= P.repeatEnd - 0.05) {
      video.currentTime = P.repeatStart;
      P.repeatCount++;
      if (P.repeatTarget > 0 && P.repeatCount >= P.repeatTarget) {
        const done = P.repeatTarget;
        clearSentenceRepeat(false);
        toast('单句循环完成（' + done + ' 次）');
      }
    }
    saveHistory();
  });
  video.addEventListener('progress', updateBufferBar);
  video.addEventListener('play', () => { updatePlayUI(); showControls(); });
  video.addEventListener('pause', () => { updatePlayUI(); clearTimeout(controlsTimer); });
  video.addEventListener('ended', () => {
    updatePlayUI();
    // 自动播放下一个
    if (state.currentIndex + 1 < state.playlist.length) {
      toast('即将播放下一集…');
      setTimeout(() => { if (state.currentIndex >= 0) openPlayer(state.currentIndex + 1); }, 800);
    }
  });
  video.addEventListener('error', () => {
    const item = state.playlist[state.currentIndex];
    if (!item || state.player.fallbackTried) { updatePlayUI(); return; }
    if (item.local) {
      toast('本地视频播放失败：浏览器可能不支持该格式（' + item.format + '）');
      updatePlayUI();
      return;
    }
    // 远程视频不可达 → 生成本地演示片段（与内置字幕对齐）
    state.player.fallbackTried = true;
    toast('远程视频加载失败（需要网络），正在生成本地演示片段…');
    generateFallbackVideo()
      .then(url => {
        video.src = url;
        video.play().catch(() => updatePlayUI());
        toast('已切换为本地演示片段（与内置字幕 0-30s 对齐）');
      })
      .catch(() => {
        toast('视频加载失败，且当前浏览器不支持本地片段生成');
        updatePlayUI();
      });
  });
  video.addEventListener('volumechange', updatePlayUI);
  video.addEventListener('enterpictureinpicture', () => toast('已进入画中画'));
  video.addEventListener('leavepictureinpicture', () => toast('已退出画中画'));
}

/* ================= 十、学习页 ================= */

/** 学习页统计卡 */
function renderStudyStats() {
  $('#stat-words').textContent = state.wordbook.length;
  $('#stat-favs').textContent = state.favorites.length;
  $('#stat-notes').textContent = state.notes.length;
  $('#stat-shadow').textContent = state.shadowing.count;
}

/** 打开学习子视图 */
function openSubview(title, bodyHTML, onMount) {
  const el = $('#subview');
  el.innerHTML =
    '<div class="subview-header">' +
      '<button class="icon-btn" id="subview-back">' +
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>' +
      '</button>' +
      '<h2>' + escapeHtml(title) + '</h2>' +
    '</div>' +
    '<div class="subview-body" id="subview-body">' + bodyHTML + '</div>';
  el.classList.remove('hidden');
  $('#subview-back').addEventListener('click', () => {
    el.classList.add('hidden');
    el.innerHTML = '';
    renderStudyStats();
    saveState();
  });
  if (onMount) onMount($('#subview-body'));
}

/* ---------- 生词本 ---------- */

function openWordbook() {
  const kw = { v: '' };
  openSubview('生词本（' + state.wordbook.length + '）',
    '<div class="search-bar" style="margin:0 0 12px"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><line x1="16.5" y1="16.5" x2="21" y2="21"/></svg>' +
    '<input id="wb-search" type="text" placeholder="搜索单词…" /></div>' +
    '<div id="wb-list"></div>',
    body => {
      const render = () => {
        const list = state.wordbook.filter(w => !kw.v || w.word.includes(kw.v.toLowerCase()));
        $('#wb-list').innerHTML = list.length ? list.map(w =>
          '<div class="word-item" data-word="' + escapeHtml(w.word) + '">' +
            '<div class="w"><b>' + escapeHtml(w.word) + '</b><span>' + escapeHtml(w.def) + '</span></div>' +
            '<span class="lv lv-' + w.level + '">' + (LEVEL_NAMES[w.level] || '其他') + '</span>' +
            '<button class="mini-btn" data-act="del">删除</button>' +
          '</div>'
        ).join('') : '<div class="empty-tip">生词本为空<br>播放时点击字幕中的单词即可加入</div>';
      };
      render();
      $('#wb-search').addEventListener('input', e => { kw.v = e.target.value.trim(); render(); });
      body.addEventListener('click', e => {
        const item = e.target.closest('.word-item');
        if (!item) return;
        const word = item.dataset.word;
        if (e.target.closest('[data-act="del"]')) {
          state.wordbook = state.wordbook.filter(w => w.word !== word);
          saveState();
          renderStudyStats();
          render();
          toast('已从生词本移除：' + word);
        } else {
          openWordCard(word);
        }
      });
    });
}

/* ---------- 收藏句子 ---------- */

function openFavorites() {
  openSubview('收藏句子（' + state.favorites.length + '）',
    '<div id="fav-list"></div>',
    () => {
      const render = () => {
        $('#fav-list').innerHTML = state.favorites.length ? state.favorites.map(f =>
          '<div class="fav-item" data-id="' + f.id + '">' +
            '<div class="en">' + escapeHtml(f.en) + '</div>' +
            (f.zh ? '<div class="zh">' + escapeHtml(f.zh) + '</div>' : '') +
            '<div class="meta"><span>' + escapeHtml(f.videoTitle) + ' · ' + fmtTime(f.time) + '</span>' +
            '<span class="ops">' +
              '<button class="mini-btn" data-act="play">跳转播放</button>' +
              '<button class="mini-btn" data-act="speak">朗读</button>' +
              '<button class="mini-btn danger" data-act="del">删除</button>' +
            '</span></div>' +
          '</div>'
        ).join('') : '<div class="empty-tip">还没有收藏句子<br>播放时长按字幕行即可收藏</div>';
      };
      render();
      $('#fav-list').addEventListener('click', e => {
        const item = e.target.closest('.fav-item');
        if (!item) return;
        const fav = state.favorites.find(f => f.id === item.dataset.id);
        if (!fav) return;
        const act = e.target.closest('[data-act]');
        if (!act) return;
        if (act.dataset.act === 'del') {
          state.favorites = state.favorites.filter(f => f.id !== fav.id);
          saveState();
          renderStudyStats();
          render();
          toast('已删除收藏');
        } else if (act.dataset.act === 'speak') {
          speakText(fav.en);
        } else if (act.dataset.act === 'play') {
          const idx = state.playlist.findIndex(v => v.title.trim() === fav.videoTitle);
          if (idx < 0) { toast('原视频已不在媒体库'); return; }
          $('#subview').classList.add('hidden');
          openPlayer(idx, fav.time);
        }
      });
    });
}

/* ---------- 笔记 ---------- */

function openNotes() {
  openSubview('笔记（' + state.notes.length + '）',
    '<button class="fab" id="note-add" style="position:static;margin:0 0 14px;box-shadow:none">＋ 新建笔记</button>' +
    '<div id="note-list"></div>',
    () => {
      const render = () => {
        $('#note-list').innerHTML = state.notes.length ? state.notes.map(n =>
          '<div class="note-item" data-id="' + n.id + '">' +
            '<b>' + escapeHtml(n.title || '无标题') + '</b>' +
            '<p>' + escapeHtml(n.content || '') + '</p>' +
            '<div class="meta"><span>' + new Date(n.updatedAt).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) + '</span>' +
            '<button class="mini-btn danger" data-act="del">删除</button></div>' +
          '</div>'
        ).join('') : '<div class="empty-tip">还没有笔记<br>点击「新建笔记」记录学习心得</div>';
      };
      const editNote = note => {
        const isNew = !note;
        note = note || { id: uid('note'), title: '', content: '', updatedAt: Date.now() };
        const card = openModal({
          title: isNew ? '新建笔记' : '编辑笔记',
          html:
            '<div class="field-label">标题</div>' +
            '<input class="field" id="note-title" type="text" value="' + escapeHtml(note.title) + '" placeholder="笔记标题" />' +
            '<div class="field-label">内容</div>' +
            '<textarea class="field" id="note-content" placeholder="记录句子、语法、心得…">' + escapeHtml(note.content) + '</textarea>',
          buttons: [
            { text: '取消', cls: 'btn-ghost' },
            { text: '保存', cls: 'btn-primary', onClick: () => {
                note.title = $('#note-title').value.trim();
                note.content = $('#note-content').value.trim();
                if (!note.title && !note.content) { toast('内容为空，未保存'); return; }
                note.updatedAt = Date.now();
                if (isNew) state.notes.unshift(note);
                saveState();
                renderStudyStats();
                render();
                toast('笔记已保存');
              } }
          ],
          onClose: () => card.remove()
        });
      };
      render();
      $('#note-add').addEventListener('click', () => editNote(null));
      $('#note-list').addEventListener('click', e => {
        const item = e.target.closest('.note-item');
        if (!item) return;
        const note = state.notes.find(n => n.id === item.dataset.id);
        if (!note) return;
        if (e.target.closest('[data-act="del"]')) {
          state.notes = state.notes.filter(n => n.id !== note.id);
          saveState();
          renderStudyStats();
          render();
          toast('已删除笔记');
        } else {
          editNote(note);
        }
      });
    });
}

/* ---------- 跟读练习 ---------- */

function openShadowing() {
  // 当前句：优先播放中的字幕，否则取内置字幕第一句
  let cue = null, source = '';
  const cues = activeCues();
  const idx = state.player.currentCueIndex;
  if (idx >= 0 && cues[idx]) { cue = cues[idx]; source = '来自当前播放'; }
  else if (cues.length) { cue = cues[0]; source = '来自内置字幕'; }
  if (!cue) { toast('没有可跟读的字幕'); return; }

  openSubview('跟读练习',
    '<div class="shadow-current">' +
      '<div class="en">' + escapeHtml(cue.primary) + '</div>' +
      '<div class="zh">' + escapeHtml(cue.secondary || '') + '</div>' +
      '<div class="src">' + source + ' · ' + fmtTime(cue.start) + ' - ' + fmtTime(cue.end) + '</div>' +
      '<div class="shadow-actions">' +
        '<button class="record-btn" id="shadow-play"><svg viewBox="0 0 24 24" width="22" height="22"><path d="M8 5v14l11-7z" fill="currentColor"/></svg>播放原声</button>' +
        '<button class="record-btn" id="shadow-record"><span class="dot"></span>录音</button>' +
      '</div>' +
      '<div id="shadow-result" style="margin-top:14px"></div>' +
    '</div>' +
    '<div class="shadow-history"><h3>历史记录</h3><div id="shadow-list"></div></div>',
    body => {
      const renderHistory = () => {
        $('#shadow-list').innerHTML = state.shadowing.history.length
          ? state.shadowing.history.slice(0, 20).map(h =>
              '<div class="shadow-rec"><span class="t">' + new Date(h.time).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) + '</span>' +
              '<span class="txt">' + escapeHtml(h.text) + '</span><span class="s">' + h.score + ' 分</span></div>'
            ).join('')
          : '<div class="empty-tip">还没有跟读记录</div>';
      };
      renderHistory();

      // 播放原声：跳到该句并播放
      $('#shadow-play').addEventListener('click', () => {
        if (state.currentIndex < 0) {
          // 播放器未打开：默认播放第一个视频
          openPlayer(0, cue.start);
          toast('已打开播放器播放原声');
        } else {
          video.currentTime = cue.start + 0.01;
          video.play().catch(() => toast('播放失败：请检查网络'));
        }
      });

      // 模拟录音 + 随机评分
      const recBtn = $('#shadow-record');
      let recording = false;
      recBtn.addEventListener('click', () => {
        if (recording) return;
        recording = true;
        recBtn.classList.add('recording');
        recBtn.innerHTML = '<span class="dot"></span>录音中…';
        $('#shadow-result').innerHTML = '';
        setTimeout(() => {
          recording = false;
          recBtn.classList.remove('recording');
          recBtn.innerHTML = '<span class="dot"></span>录音';
          // 模拟评分：按设置中的严格度给出不同分数区间
          const range = { loose: [80, 98], normal: [70, 95], strict: [58, 90] }[state.settings.shadowStrict] || [70, 95];
          const score = range[0] + Math.floor(Math.random() * (range[1] - range[0] + 1));
          const comment = score >= 90 ? '非常出色！语音语调自然。'
            : score >= 80 ? '表现不错，注意连读和重音。'
            : '基本达标，建议多听原声再跟读。';
          $('#shadow-result').innerHTML =
            '<div class="score-pop"><div class="score-num">' + score + '<small> 分</small></div>' +
            '<div class="score-comment">' + comment + '（模拟评分）</div></div>';
          state.shadowing.count++;
          state.shadowing.history.unshift({ text: cue.primary, score, time: Date.now() });
          saveState();
          renderStudyStats();
          renderHistory();
        }, 2200);
      });
    });
}

/* ---------- 词汇分析报告 ---------- */

function openVocabReport() {
  // 统计口径：生词本 + 内置字幕词汇（去重），按词典分级归类
  const stats = {};
  const wordMap = {};
  const collect = w => {
    const entry = lookupWord(w);
    const level = entry ? entry.level : 'other';
    if (!stats[level]) stats[level] = 0;
    stats[level]++;
    if (!wordMap[level]) wordMap[level] = new Set();
    wordMap[level].add(w);
  };
  state.wordbook.forEach(w => collect(w.word));
  BUILTIN_SUBTITLES.forEach(cue => {
    (cue.primary || '').toLowerCase().replace(/[^a-z'\s-]/g, ' ').split(/\s+/)
      .filter(w => w.length > 2 && lookupWord(w))
      .forEach(collect);
  });

  const order = ['cet4', 'cet6', 'kaoyan', 'toefl', 'gre', 'other'];
  const total = Object.values(stats).reduce((a, b) => a + b, 0);
  const max = Math.max(1, ...Object.values(stats));

  const html =
    '<div class="modal-text">基于「内置字幕 + 生词本」的演示统计，共 ' + total + ' 个词条。点击单词可查看词卡与例句。</div>' +
    order.filter(lv => stats[lv]).map(lv =>
      '<div class="report-level">' +
        '<div class="rl-head"><span>' + LEVEL_NAMES[lv] + '</span><span class="n">' + stats[lv] + ' 词</span></div>' +
        '<div class="report-bar"><div data-w="' + ((stats[lv] / max) * 100).toFixed(1) + '" style="background:' + LEVEL_COLORS[lv] + '"></div></div>' +
        '<div class="report-words">' +
          Array.from(wordMap[lv]).slice(0, 40).map(w =>
            '<button class="report-word" data-word="' + escapeHtml(w) + '">' + escapeHtml(w) +
            (lookupWord(w) ? '<span class="zh">' + escapeHtml(lookupWord(w).def.replace(/^[nvasdpadt]+\.\s*/, '')) + '</span>' : '') +
            '</button>'
          ).join('') +
        '</div>' +
      '</div>'
    ).join('');

  const card = openModal({
    title: '词汇分析报告',
    html,
    buttons: [{ text: '完成', cls: 'btn-primary' }],
    onClose: () => {
      card.remove();
      $$('.report-bar > div', card).forEach(d => d.style.width = '0%');
    }
  });
  // 触发条形图动画
  requestAnimationFrame(() => {
    $$('.report-bar > div', card).forEach(d => d.style.width = d.dataset.w + '%');
  });
  card.addEventListener('click', e => {
    const w = e.target.closest('.report-word');
    if (w) openWordCard(w.dataset.word);
  });
}

/* ================= 十一、设置页 ================= */

function bindSettings() {
  const s = state.settings;

  // 默认倍速
  const rateInput = $('#set-rate');
  const rateSync = () => {
    rateInput.value = s.defaultRate;
    $('#set-rate-val').textContent = (+s.defaultRate).toFixed(2) + '×';
  };
  rateInput.addEventListener('input', e => {
    s.defaultRate = +e.target.value;
    rateSync();
    if (state.currentIndex >= 0) { video.playbackRate = s.defaultRate; updateRateLabel(); }
    saveState();
  });

  // 记忆播放位置
  const rememberBtn = $('#set-remember');
  rememberBtn.classList.toggle('on', s.remember);
  rememberBtn.addEventListener('click', () => {
    s.remember = !s.remember;
    rememberBtn.classList.toggle('on', s.remember);
    saveState();
    toast(s.remember ? '已开启：记忆播放位置' : '已关闭：记忆播放位置');
  });

  // 默认显示模式
  const modeBox = $('#set-mode');
  $$('button', modeBox).forEach(b => b.classList.toggle('on', b.dataset.v === s.displayMode || (!s.displayMode && b.dataset.v === 'bilingual')));
  modeBox.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    s.displayMode = b.dataset.v;
    $$('button', modeBox).forEach(x => x.classList.toggle('on', x === b));
    saveState();
    toast('已设默认字幕模式：' + b.textContent);
  });

  // 字幕字号
  const sizeInput = $('#set-size');
  const sizeSync = () => {
    sizeInput.value = s.subSize;
    $('#set-size-val').textContent = s.subSize + 'px';
    applySubtitleStyle();
  };
  sizeInput.addEventListener('input', e => { s.subSize = +e.target.value; sizeSync(); saveState(); });

  // 主字幕颜色
  const colorBox = $('#set-color');
  colorBox.addEventListener('click', e => {
    const b = e.target.closest('.color-dot');
    if (!b) return;
    s.subColor = b.dataset.v;
    $$('.color-dot', colorBox).forEach(x => x.classList.toggle('on', x === b));
    applySubtitleStyle();
    saveState();
  });

  // 点词暂停
  const pauseBtn = $('#set-pauseword');
  pauseBtn.classList.toggle('on', s.pauseOnWord);
  pauseBtn.addEventListener('click', () => {
    s.pauseOnWord = !s.pauseOnWord;
    pauseBtn.classList.toggle('on', s.pauseOnWord);
    saveState();
    toast(s.pauseOnWord ? '已开启：点按单词时暂停' : '已关闭：点按单词时暂停');
  });

  // 手势开关
  const gestureBtn = $('#set-gestures');
  gestureBtn.classList.toggle('on', s.gestures);
  gestureBtn.addEventListener('click', () => {
    s.gestures = !s.gestures;
    gestureBtn.classList.toggle('on', s.gestures);
    saveState();
    toast(s.gestures ? '已开启播放器手势' : '已关闭播放器手势');
  });

  // 双击步长
  const dblBox = $('#set-dbl');
  $$('button', dblBox).forEach(b => b.classList.toggle('on', +b.dataset.v === s.dblStep));
  dblBox.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    s.dblStep = +b.dataset.v;
    $$('button', dblBox).forEach(x => x.classList.toggle('on', x === b));
    saveState();
  });

  // 跟读评分严格度（演示：影响模拟评分区间）
  const strictBox = $('#set-strict');
  $$('button', strictBox).forEach(b => b.classList.toggle('on', b.dataset.v === s.shadowStrict));
  strictBox.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    s.shadowStrict = b.dataset.v;
    $$('button', strictBox).forEach(x => x.classList.toggle('on', x === b));
    saveState();
    toast('跟读评分严格度：' + b.textContent + '（模拟评分将参考该档位）');
  });

  // 存储占用（演示）
  const updateCache = () => {
    let size = 0;
    try {
      for (const k in localStorage) {
        if (Object.prototype.hasOwnProperty.call(localStorage, k)) {
          size += (localStorage[k] || '').length + k.length;
        }
      }
    } catch (e) { /* 忽略 */ }
    $('#set-cache').textContent = (size / 1024).toFixed(1) + ' KB（localStorage）';
  };
  updateCache();

  // 清空数据
  $('#btn-clear').addEventListener('click', () => {
    const card = openModal({
      title: '清空学习数据',
      text: '将删除生词本、收藏句子、笔记、跟读记录与播放历史，且无法恢复。设置项将恢复默认。',
      buttons: [
        { text: '取消', cls: 'btn-ghost' },
        { text: '确认清空', cls: 'btn-danger', onClick: () => {
            state.wordbook = [];
            state.favorites = [];
            state.notes = [];
            state.shadowing = { count: 0, history: [] };
            state.history = [];
            state.subtitleTracks = [{ id: 'builtin', name: '内置双语（0-30s 循环）', cues: BUILTIN_SUBTITLES }];
            // 注意：保留 settings 对象引用（bindSettings 闭包持有），仅重置字段
            Object.assign(state.settings, {
              defaultRate: 1, remember: true, pauseOnWord: true,
              gestures: true, dblStep: 10, subSize: 16, subColor: '#FFFFFF',
              displayMode: 'bilingual', shadowStrict: 'normal'
            });
            try { localStorage.removeItem(LS_KEY); } catch (e) { /* 忽略 */ }
            applySettingsToUI();
            renderLibrary();
            renderStudyStats();
            updateCache();
            toast('已清空全部学习数据');
          } }
      ],
      onClose: () => card.remove()
    });
  });
}

/** 把 settings 同步到设置页 UI */
function applySettingsToUI() {
  const s = state.settings;
  state.displayMode = s.displayMode || 'bilingual'; // 默认显示模式真实生效
  $('#set-rate').value = s.defaultRate;
  $('#set-rate-val').textContent = (+s.defaultRate).toFixed(2) + '×';
  $('#set-remember').classList.toggle('on', s.remember);
  $$('#set-mode button').forEach(b => b.classList.toggle('on', b.dataset.v === state.displayMode));
  $('#set-size').value = s.subSize;
  $('#set-size-val').textContent = s.subSize + 'px';
  $$('#set-color .color-dot').forEach(b => b.classList.toggle('on', b.dataset.v === s.subColor));
  $('#set-pauseword').classList.toggle('on', s.pauseOnWord);
  $('#set-gestures').classList.toggle('on', s.gestures);
  $$('#set-dbl button').forEach(b => b.classList.toggle('on', +b.dataset.v === s.dblStep));
  $$('#set-strict button').forEach(b => b.classList.toggle('on', b.dataset.v === s.shadowStrict));
  applySubtitleStyle();
}

/* ================= 十二、初始化 ================= */

function init() {
  loadState();

  // Tab 切换
  $$('.tab').forEach(t => t.addEventListener('click', () => switchTab(t.dataset.tab)));

  // 媒体库
  $('#btn-import-url').addEventListener('click', openImportURLDialog);
  $('#btn-cloud').addEventListener('click', () => toast('阿里云盘接入为演示占位'));
  $('#fab-add').addEventListener('click', openAddVideoDialog);
  $('#search-input').addEventListener('input', e => renderPosterGrid(e.target.value.trim()));
  bindPosterCardEvents();
  bindDragAndDrop();

  // 播放器按钮
  $('#btn-back').addEventListener('click', closePlayer);
  $('#btn-play').addEventListener('click', togglePlay);
  $('#center-play').addEventListener('click', togglePlay);
  $('#btn-prev').addEventListener('click', () => jumpCue(-1));
  $('#btn-next').addEventListener('click', () => jumpCue(1));
  $('#btn-rate').addEventListener('click', openRatePanel);
  $('#btn-ab').addEventListener('click', openABPanel);
  $('#btn-sub').addEventListener('click', openSubtitlePanel);
  $('#btn-list').addEventListener('click', openPlaylistDrawer);
  $('#btn-cast').addEventListener('click', () => toast('投屏功能为演示占位（AirPlay / Chromecast）'));
  $('#btn-pip').addEventListener('click', togglePiP);
  $('#btn-lock').addEventListener('click', toggleLock);
  $('#unlock-btn').addEventListener('click', () => { state.player.locked = false; updateLockUI(); toast('已解锁'); });
  $('#btn-more').addEventListener('click', openMorePanel);

  bindVideoEvents();
  bindGestures();
  bindProgressDrag();
  bindSubtitleEvents();

  // 学习页
  $('#btn-vocab-report').addEventListener('click', openVocabReport);
  $('#menu-wordbook').addEventListener('click', openWordbook);
  $('#menu-favorites').addEventListener('click', openFavorites);
  $('#menu-notes').addEventListener('click', openNotes);
  $('#menu-shadowing').addEventListener('click', openShadowing);

  // 设置页
  bindSettings();
  applySettingsToUI();

  // 首屏渲染
  renderLibrary();
  renderStudyStats();
  updatePlayUI();
}

document.addEventListener('DOMContentLoaded', init);
