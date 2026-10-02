/*!
 * @name 全平台聚合音乐音源·去重整合版
 * @description
 *   基于「聚合Hi-Res v1.0」「全豆要聚合 v4.0」「Huibq 五音源」整理。
 *   去除重复注册、失效/不可达回退；保留五大平台及多条独立解析链。
 * @version v1.0.0
 * @author OpenAI 整合
 *
 * 平台：
 *   wy 网易云音乐 / tx QQ音乐 / kg 酷狗 / kw 酷我 / mg 咪咕
 *
 * 解析链：
 *   1. GD Studio
 *   2. Huibq LX Music API
 *   3. 溯音/OIAPI（按平台）
 *   4. 聆川
 *   5. 长青 VIP 直链模板
 *
 * 注意：
 *   - 音源属于第三方服务，稳定性/版权/地区可用性可能随时变化。
 *   - 本版不批量下载，只响应 LX Music 的 musicUrl 请求。
 */

const CONFIG = {
  timeout: 8000,
  retry: 1,

  gd: 'https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light',

  huibq: 'https://lxmusicapi.onrender.com',

  oi: {
    wy: 'https://oiapi.net/api/Music_163',
    tx: 'https://oiapi.net/api/QQ_Music',
    kw: 'https://oiapi.net/api/Kuwo',
  },

  oiQqKey: 'oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575',

  migu: 'https://api.xcvts.cn/api/music/migu',

  lingchuan: 'https://lc.guoyue2010.top/api/music/url',

  changqing: {
    wy: 'http://175.27.166.236/wy/wy.php',
    tx: 'http://175.27.166.236/kgqq/qq.php',
    kg: 'https://music.haitangw.cc/kgqq/kg.php',
    kw: 'https://musicapi.haitangw.net/music/kw.php',
    mg: 'https://music.haitangw.cc/musicapi/mg.php',
  },

  qualities: {
    wy: ['24bit', 'flac', '320k', '192k', '128k'],
    tx: ['24bit', 'flac', '320k', '192k', '128k'],
    kg: ['24bit', 'flac', '320k', '192k', '128k'],
    kw: ['24bit', 'flac', '320k', '192k', '128k'],
    mg: ['24bit', 'flac', '320k', '192k', '128k'],
  },

  names: {
    wy: '网易云音乐',
    tx: 'QQ音乐',
    kg: '酷狗音乐',
    kw: '酷我音乐',
    mg: '咪咕音乐',
  },
};

const { EVENT_NAMES, request, on, send, env, version } = globalThis.lx || {};

if (!EVENT_NAMES || !request || !on || !send) {
  throw new Error('LX Music 运行环境不可用');
}

const sleep = ms =>
  new Promise(resolve => setTimeout(resolve, ms));

const httpGet = (url, options = {}) =>
  new Promise((resolve, reject) => {
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error('请求超时'));
      }
    }, options.timeout ?? CONFIG.timeout);

    try {
      request(
        url,
        {
          method: 'GET',
          timeout: options.timeout ?? CONFIG.timeout,
          headers: options.headers || {},
          follow_max: options.follow_max,
        },
        (err, resp) => {
          if (settled) return;

          settled = true;
          clearTimeout(timer);

          if (err) {
            return reject(err);
          }

          resolve({
            status: resp?.statusCode ?? 0,
            headers: resp?.headers || {},
            body:
              typeof resp?.body === 'string'
                ? parseJson(resp.body)
                : resp?.body,
          });
        }
      );
    } catch (err) {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    }
  });

function parseJson(body) {
  const text = String(body || '').trim();

  if (!text) return body;

  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      return JSON.parse(text);
    } catch (_) {}
  }

  return body;
}

function safeUrl(value) {
  if (typeof value !== 'string') return '';

  const url = value.trim();

  return /^https?:\/\//i.test(url) ? url : '';
}

function getId(info = {}) {
  return String(
    info.songmid ??
      info.hash ??
      info.id ??
      info.mid ??
      ''
  ).trim();
}

function getName(info = {}) {
  return String(
    info.name ??
      info.songName ??
      info.title ??
      ''
  ).trim();
}

function getSinger(info = {}) {
  const value =
    info.singer ??
    info.singers ??
    info.artist ??
    '';

  return Array.isArray(value)
    ? value
        .map(x =>
          typeof x === 'string'
            ? x
            : x?.name || ''
        )
        .filter(Boolean)
        .join(' ')
    : String(value || '').trim();
}

function getAlbum(info = {}) {
  return String(
    info.albumName ??
      info.album ??
      info.albumname ??
      ''
  ).trim();
}

function qualityRank(q) {
  return {
    '24bit': 5,
    'flac24bit': 5,
    master: 5,
    flac: 4,
    '320k': 3,
    '192k': 2,
    '128k': 1,
  }[String(q).toLowerCase()] || 1;
}

function normalizeQuality(q) {
  const value = String(q || '320k').toLowerCase();

  if (value === 'flac24bit') {
    return '24bit';
  }

  if (value === 'master') {
    return '24bit';
  }

  if (
    [
      '24bit',
      'flac',
      '320k',
      '192k',
      '128k',
    ].includes(value)
  ) {
    return value;
  }

  return '320k';
}


/* ============================================================
 * 1. GD Studio
 * ============================================================ */

const GD_SOURCE = {
  wy: 'netease',
  tx: 'tencent',
  kg: 'kugou',
  kw: 'kuwo',
  mg: 'migu',
};

const GD_BR = {
  '128k': '128',
  '192k': '192',
  '320k': '320',
  flac: '740',
  '24bit': '999',
};

async function resolveGD(source, info, quality) {
  const id = getId(info);

  if (!id) {
    throw new Error('缺少歌曲ID');
  }

  const br = GD_BR[quality] || '320';

  const url =
    `${CONFIG.gd}` +
    `&types=url` +
    `&source=${GD_SOURCE[source]}` +
    `&id=${encodeURIComponent(id)}` +
    `&br=${br}`;

  const resp = await httpGet(url);

  const body = resp.body || {};

  const audio = safeUrl(body.url);

  if (!audio) {
    throw new Error(
      body.msg ||
        `GD 无 ${quality} 播放地址`
    );
  }

  return audio;
}


/* ============================================================
 * 2. Huibq
 * ============================================================ */

const HUIBQ_QUALITY = {
  '24bit': '320k',
  flac: '320k',
  '320k': '320k',
  '192k': '128k',
  '128k': '128k',
};

async function resolveHuibq(source, info, quality) {
  const id = getId(info);

  if (!id) {
    throw new Error('缺少歌曲ID');
  }

  const actual =
    HUIBQ_QUALITY[quality] || '128k';

  const url =
    `${CONFIG.huibq}/url/` +
    `${source}/` +
    `${encodeURIComponent(id)}/` +
    `${actual}`;

  const resp = await httpGet(url, {
    headers: {
      'Content-Type': 'application/json',

      'User-Agent':
        `lx-music-${env || 'desktop'}/` +
        `${version || 'unknown'}`,

      'X-Request-Key': 'share-v3',
    },
  });

  const body = resp.body || {};

  if (
    Number(body.code) !== 0 ||
    !safeUrl(body.url)
  ) {
    throw new Error(
      body.msg ||
        `Huibq 无 ${actual} 播放地址`
    );
  }

  return body.url;
}


/* ============================================================
 * 3. 溯音 / OIAPI
 * ============================================================ */

async function resolveSuyinWY(info) {
  const id = getId(info);

  if (!id) {
    throw new Error(
      '缺少网易云歌曲ID'
    );
  }

  const resp = await httpGet(
    `${CONFIG.oi.wy}?id=${encodeURIComponent(id)}`
  );

  const body = resp.body || {};

  const data = Array.isArray(body.data)
    ? body.data[0]
    : body.data;

  const url = safeUrl(
    data?.url || body.url
  );

  if (!url) {
    throw new Error(
      body.message ||
        '溯音网易云无播放地址'
    );
  }

  return url;
}

function oiQqBrCandidates(quality) {
  switch (quality) {
    case '24bit':
      return [1, 4, 5, 7];

    case 'flac':
      return [4, 5, 7];

    case '320k':
      return [5, 7];

    default:
      return [7];
  }
}

async function resolveSuyinTX(info, quality) {
  const id = getId(info);

  if (!id) {
    throw new Error(
      '缺少QQ歌曲ID'
    );
  }

  let lastError = null;

  for (
    const br of oiQqBrCandidates(quality)
  ) {
    try {
      const params = new URLSearchParams({
        key: CONFIG.oiQqKey,
        type: 'json',
        br: String(br),
        n: '1',
        mid: id,
      });

      const resp = await httpGet(
        `${CONFIG.oi.tx}?${params}`
      );

      const body = resp.body || {};

      const url = safeUrl(
        body.url ||
          body.music_url ||
          body.data?.url
      );

      if (url) {
        return url;
      }

      lastError = new Error(
        body.message ||
          'OIAPI QQ 无播放地址'
      );
    } catch (err) {
      lastError = err;
    }
  }

  throw (
    lastError ||
    new Error('溯音QQ解析失败')
  );
}

function kwKeywords(info) {
  const name = getName(info);
  const singer = getSinger(info);
  const album = getAlbum(info);

  return [
    [name, singer, album]
      .filter(Boolean)
      .join(''),

    [name, singer]
      .filter(Boolean)
      .join(''),

    name,
  ].filter(Boolean);
}

async function resolveSuyinKW(info, quality) {
  const br =
    quality === '24bit' ||
    quality === 'flac'
      ? 1
      : quality === '320k'
        ? 5
        : 7;

  let lastError = null;

  for (const msg of kwKeywords(info)) {
    try {
      const params = new URLSearchParams({
        msg,
        n: '1',
        br: String(br),
      });

      const resp = await httpGet(
        `${CONFIG.oi.kw}?${params}`
      );

      const body = resp.body || {};

      const url = safeUrl(
        body.data?.url ||
          body.url
      );

      if (url) {
        return url;
      }

      const text = String(
        body.message ||
          body.msg ||
          ''
      );

      const match =
        text.match(
          /音乐链接[：:](\S+)/
        );

      if (
        match &&
        safeUrl(match[1])
      ) {
        return match[1];
      }

      lastError = new Error(
        text ||
          'OIAPI 酷我无播放地址'
      );
    } catch (err) {
      lastError = err;
    }
  }

  throw (
    lastError ||
    new Error('溯音酷我解析失败')
  );
}

async function resolveSuyinMG(info) {
  const keywords = kwKeywords(info);

  let lastError = null;

  for (const gm of keywords) {
    try {
      const params = new URLSearchParams({
        gm,
        n: '1',
        num: '1',
        type: 'json',
      });

      const resp = await httpGet(
        `${CONFIG.migu}?${params}`
      );

      const body = resp.body || {};

      const url = safeUrl(
        body.music_url ||
          body.url ||
          body.data?.music_url
      );

      if (url) {
        return url;
      }

      lastError = new Error(
        body.message ||
          body.msg ||
          '小尘咪咕无播放地址'
      );
    } catch (err) {
      lastError = err;
    }
  }

  throw (
    lastError ||
    new Error('溯音咪咕解析失败')
  );
}

async function resolveSuyin(
  source,
  info,
  quality
) {
  switch (source) {
    case 'wy':
      return resolveSuyinWY(info);

    case 'tx':
      return resolveSuyinTX(
        info,
        quality
      );

    case 'kw':
      return resolveSuyinKW(
        info,
        quality
      );

    case 'mg':
      return resolveSuyinMG(info);

    default:
      throw new Error(
        `溯音不支持平台：${source}`
      );
  }
}


/* ============================================================
 * 4. 聆川
 * ============================================================ */

const LINGCHUAN_QUALITY = {
  '24bit': '24bit',
  flac: '320k',
  '320k': '320k',
  '192k': '128k',
  '128k': '128k',
};

async function resolveLingchuan(
  source,
  info,
  quality
) {
  const id = getId(info);

  if (!id) {
    throw new Error('缺少歌曲ID');
  }

  const actual =
    LINGCHUAN_QUALITY[quality] ||
    '128k';

  const params = new URLSearchParams({
    source,
    songId: id,
    quality: actual,
  });

  const resp = await httpGet(
    `${CONFIG.lingchuan}?${params}`,
    {
      headers: {
        'Content-Type':
          'application/json',

        'User-Agent':
          `lx-music-${env || 'desktop'}/` +
          `${version || 'unknown'}`,
      },

      follow_max: 5,
    }
  );

  const body = resp.body || {};

  const url = safeUrl(
    body.url ||
      body.data?.url ||
      body.data?.music_url
  );

  if (!url) {
    throw new Error(
      body.message ||
        body.msg ||
        '聆川无播放地址'
    );
  }

  return url;
}


/* ============================================================
 * 5. 长青 VIP
 * ============================================================ */

const CHANGQING_LEVEL = {
  '24bit': 'standard',
  flac: 'lossless',
  '320k': 'exhigh',
  '192k': 'exhigh',
  '128k': 'standard',
};

async function resolveChangqing(
  source,
  info,
  quality
) {
  const id = getId(info);

  if (!id) {
    throw new Error('缺少歌曲ID');
  }

  const base =
    CONFIG.changqing[source];

  if (!base) {
    throw new Error(
      `长青不支持平台：${source}`
    );
  }

  const params = new URLSearchParams({
    type: 'mp3',
    id,
    level:
      CHANGQING_LEVEL[quality] ||
      'exhigh',
  });

  const url = safeUrl(
    `${base}?${params}`
  );

  if (!url) {
    throw new Error(
      '长青生成的URL无效'
    );
  }

  return url;
}


/* ============================================================
 * 聚合回退
 * ============================================================ */

const PROVIDERS = [
  {
    name: 'GD Studio',
    fn: resolveGD,
  },

  {
    name: 'Huibq',
    fn: resolveHuibq,
  },

  {
    name: '溯音',
    fn: resolveSuyin,
  },

  {
    name: '聆川',
    fn: resolveLingchuan,
  },

  {
    name: '长青VIP',
    fn: resolveChangqing,
  },
];

async function resolveWithFallback(
  source,
  info,
  targetQuality
) {
  const quality =
    normalizeQuality(targetQuality);

  const errors = [];

  // 按顺序尝试，避免同时请求多个第三方接口。
  for (const provider of PROVIDERS) {
    try {
      const url =
        await provider.fn(
          source,
          info,
          quality
        );

      const safe = safeUrl(url);

      if (safe) {
        console.log(
          `[聚合音源] ${source}/${quality} ← ${provider.name}`
        );

        return safe;
      }

      throw new Error(
        '返回的播放地址无效'
      );
    } catch (err) {
      errors.push(
        `${provider.name}: ${
          err?.message || err
        }`
      );

      await sleep(80);
    }
  }

  throw new Error(
    `全部音源解析失败：${errors.join('；')}`
  );
}


/* ============================================================
 * LX Music 注册
 * ============================================================ */

const sources = {};

for (
  const source of Object.keys(
    CONFIG.qualities
  )
) {
  sources[source] = {
    name: CONFIG.names[source],
    type: 'music',
    actions: ['musicUrl'],
    qualitys:
      CONFIG.qualities[source],
  };
}

on(
  EVENT_NAMES.request,
  ({ action, source, info }) => {
    if (action !== 'musicUrl') {
      return Promise.reject(
        new Error(
          '只支持 musicUrl'
        )
      );
    }

    if (!sources[source]) {
      return Promise.reject(
        new Error(
          `不支持的平台：${source}`
        )
      );
    }

    const musicInfo =
      info?.musicInfo;

    if (!musicInfo) {
      return Promise.reject(
        new Error(
          '缺少 musicInfo'
        )
      );
    }

    return resolveWithFallback(
      source,
      musicInfo,
      info?.type || '320k'
    );
  }
);

send(
  EVENT_NAMES.inited,
  {
    status: true,
    openDevTools: false,
    sources,
  }
);

console.log(
  '[聚合音源] 去重整合版初始化完成'
);
