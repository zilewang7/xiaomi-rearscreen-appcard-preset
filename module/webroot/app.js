/* ==========================================================================
   背屏应用卡中心 · 状态面板
   --------------------------------------------------------------------------
   兼容性：APatch 与 KernelSU 的 WebUI 桥 API 完全一致，都是注入 window.ksu：
       exec(cmd)                     → 同步返回 stdout
       exec(cmd, cbName)             → 回调 cbName(errno, stdout, stderr)
       exec(cmd, optionsJson, cbName)
       toast(msg) / moduleInfo()
   新版 KernelSU 还支持 ksu://icon/<pkg> 直接取应用图标。
   所以这里手写一个薄适配层，不依赖 npm 打包（模块必须免构建才能直接刷）。
   ========================================================================== */

'use strict';

// ------------------------------------------------------------------ 模块路径
const MODDIR = (function () {
    try {
        const info = JSON.parse(window.ksu.moduleInfo());
        if (info && info.id) return '/data/adb/modules/' + info.id;
    } catch (e) { /* 桥不支持 moduleInfo，往下走 */ }

    const m = location.pathname.match(/\/data\/adb\/modules\/([^/]+)\//);
    if (m) return '/data/adb/modules/' + m[1];

    // 兜底：UpToDown 的仓库路径也可能出现在 hash / query
    const s = location.href.match(/\/data\/adb\/modules\/([^/]+)\//);
    if (s) return '/data/adb/modules/' + s[1];

    return '/data/adb/modules/rearscreen_appcard_preset';
})();

const STATUS_SH = MODDIR + '/status.sh';
const FETCH_SH  = MODDIR + '/fetch.sh';
const LOGPACK_SH = MODDIR + '/logpack.sh';
const PA_PKG = 'com.miui.personalassistant';

// ------------------------------------------------------------------ shell 桥
let cbSeq = 0;
let bridgeMode = 'cb2';          // 'cb2' | 'cb3' | 'sync'

function hasBridge() {
    return !!(window.ksu && typeof window.ksu.exec === 'function');
}

function exec(cmd, timeoutMs) {
    const limit = timeoutMs || 90000;
    return new Promise(function (resolve) {
        if (!hasBridge()) {
            resolve({ errno: -1, stdout: '', stderr: 'NO_BRIDGE' });
            return;
        }

        const name = '__appcard_cb_' + (++cbSeq);
        let settled = false;

        function finish(errno, stdout, stderr) {
            if (settled) return;
            settled = true;
            try { delete window[name]; } catch (e) { window[name] = undefined; }
            resolve({
                errno: typeof errno === 'number' ? errno : -1,
                stdout: stdout == null ? '' : String(stdout),
                stderr: stderr == null ? '' : String(stderr)
            });
        }

        window[name] = function (errno, stdout, stderr) { finish(errno, stdout, stderr); };
        window.setTimeout(function () { finish(-1, '', 'TIMEOUT'); }, limit);

        try {
            if (bridgeMode === 'sync') {
                finish(0, window.ksu.exec(cmd), '');
            } else if (bridgeMode === 'cb3') {
                window.ksu.exec(cmd, '{}', name);
            } else {
                window.ksu.exec(cmd, name);
            }
        } catch (e) {
            // 签名不匹配 → 换一种再试
            try {
                window.ksu.exec(cmd, '{}', name);
                bridgeMode = 'cb3';
            } catch (e2) {
                try {
                    finish(0, window.ksu.exec(cmd), '');
                    bridgeMode = 'sync';
                } catch (e3) {
                    finish(-1, '', String(e3));
                }
            }
        }
    });
}

function toast(msg) {
    try {
        if (window.ksu && typeof window.ksu.toast === 'function') { window.ksu.toast(msg); return; }
    } catch (e) { /* 忽略，用页内提示 */ }
    showToast(msg);
}

function showToast(msg) {
    const el = document.getElementById('toast');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(function () { el.classList.remove('show'); }, 2600);
}

// shell 单引号转义
function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

// ------------------------------------------------------------------ 行协议解析
function parseProtocol(text) {
    const records = [];
    let cur = null;

    text.split('\n').forEach(function (raw) {
        const line = raw.replace(/\r$/, '');

        if (line === '@@') {
            if (cur) records.push(cur);
            cur = { id: '', level: 'info', title: '', detail: '', fix: '', pkg: '', action: '' };
            return;
        }
        if (!cur) return;

        const i = line.indexOf('=');
        if (i < 0) return;

        const k = line.slice(0, i);
        const v = line.slice(i + 1);
        if (Object.prototype.hasOwnProperty.call(cur, k)) cur[k] = v;
    });

    if (cur) records.push(cur);
    return records;
}

// ------------------------------------------------------------------ 渲染
const SECTIONS = [
    { key: 'env',    title: '运行环境' },
    { key: 'conf',   title: '冲突检测' },
    { key: 'res',    title: '资源' },
    { key: 'inj',    title: '注入状态' },
    { key: 'pre',    title: '预设内容' },
    { key: 'card',   title: '卡片就绪度' },
    { key: 'app',    title: '应用卡中心' },
    { key: 'result', title: '结论' }
];

const MARK = { ok: '\u2713', warn: '!', fail: '\u2715', info: '\u00b7' };

// 某些检查项光靠文字说不清，还得让用户去点别的地方 —— 那就直接在卡片上给个按钮。
// status.sh 通过行协议里的 action=<id> 指定用哪个动作，这里查表执行。
const ACTIONS = {
    clear_reareye: {
        label: '清除 REAREye 预设包',
        busy: '清除中…',
        hint: '再点一次就会删除 REAREye 的预设资源包（只删缓存，不动它的应用和设置）',
        cmd: 'sh ' + q(MODDIR + '/clear-reareye.sh')
    }
};

function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
}

// 多行文本：先转义再把换行还原成 <br>，否则脚本输出会被挤成一长条
function escNl(s) {
    return esc(s).replace(/\n/g, '<br>');
}

function render(records) {
    const wrap = document.getElementById('sections');
    wrap.innerHTML = '';

    let nOk = 0, nWarn = 0, nFail = 0;

    SECTIONS.forEach(function (sec) {
        const items = records.filter(function (r) {
            return r.id === sec.key || r.id.indexOf(sec.key + '.') === 0;
        });
        if (!items.length) return;

        const div = document.createElement('div');
        div.className = 'section';

        const h2 = document.createElement('h2');
        h2.textContent = sec.title;
        div.appendChild(h2);

        items.forEach(function (r) {
            if (r.level === 'ok') nOk++;
            else if (r.level === 'warn') nWarn++;
            else if (r.level === 'fail') nFail++;

            const el = document.createElement('div');
            el.className = 'item ' + (r.level || 'info');

            let html = '<div class="dot">' + (MARK[r.level] || MARK.info) + '</div>';

            if (sec.key === 'card' && r.pkg && hasBridge()) {
                html += '<img class="icon" alt="" src="ksu://icon/' + encodeURIComponent(r.pkg) +
                        '" onerror="this.style.display=\'none\'">';
            }

            html += '<div class="body">';
            html += '<div class="t">' + esc(r.title) + '</div>';
            if (r.detail) html += '<div class="d">' + esc(r.detail) + '</div>';
            if (r.fix)    html += '<div class="fix">' + esc(r.fix) + '</div>';
            if (r.action && ACTIONS[r.action]) {
                html += '<button class="fixbtn" type="button">' +
                        esc(ACTIONS[r.action].label) + '</button>';
            }
            html += '</div>';

            el.innerHTML = html;

            const ab = el.querySelector('button.fixbtn');
            if (ab) {
                ab.addEventListener('click', function () { runAction(r.action, ab); });
            }
            div.appendChild(el);
        });

        wrap.appendChild(div);
    });

    // 顶部徽章
    const badge = document.getElementById('badge');
    badge.className = 'badge';
    if (nFail > 0) {
        badge.classList.add('fail');
        badge.textContent = nFail + ' 项异常';
    } else if (nWarn > 0) {
        badge.classList.add('warn');
        badge.textContent = nWarn + ' 项注意';
    } else if (nOk > 0) {
        badge.classList.add('ok');
        badge.textContent = '一切正常';
    } else {
        badge.textContent = '无数据';
    }
}

// 头部摘要：从 env.* 里挑出设备/系统
function renderHeroMeta(records) {
    function pick(id) {
        const r = records.find(function (x) { return x.id === id; });
        return r ? r.detail : '';
    }
    const el = document.getElementById('meta');
    el.innerHTML =
        '<span>设备 <b>' + esc(pick('env.device') || '—') + '</b></span>' +
        '<span>系统 <b>' + esc(pick('env.os') || '—') + '</b></span>' +
        '<span>Root <b>' + esc((pick('env.root') || '—').split('；')[0]) + '</b></span>';
}

// ------------------------------------------------------------------ 主流程
let lastReport = '';

async function refresh(silent) {
    const badge = document.getElementById('badge');
    const wrap = document.getElementById('sections');

    badge.className = 'badge busy';
    badge.innerHTML = '<span class="spinner"></span>检测中';
    if (!silent && !wrap.querySelector('.section')) {
        wrap.innerHTML = '<div class="empty"><span class="spinner"></span>正在检查模块状态…</div>';
    }

    if (!hasBridge()) {
        wrap.innerHTML =
            '<div class="err">当前环境没有 WebUI 桥（window.ksu）。<br><br>' +
            '请从 <b>APatch / KernelSU 管理器的模块卡片</b>点开本页面，<br>' +
            '或安装 WebUI X / KSU WebUI Standalone 后再打开。<br><br>' +
            '不想装的话，直接在管理器模块卡片上点「操作」也能看到同样的诊断。</div>';
        badge.className = 'badge fail';
        badge.textContent = '无法访问';
        return;
    }

    const res = await exec('sh ' + q(STATUS_SH));

    if (res.errno !== 0 && res.stderr) {
        wrap.innerHTML = '<div class="err">诊断脚本执行失败：<br>' + esc(res.stderr) + '</div>';
        badge.className = 'badge fail';
        badge.textContent = '执行失败';
        return;
    }

    const records = parseProtocol(res.stdout);
    if (!records.length) {
        wrap.innerHTML = '<div class="err">诊断脚本没有输出。<br>修复：在管理器里重刷模块，或点「导出日志」反馈。</div>';
        badge.className = 'badge fail';
        badge.textContent = '无输出';
        return;
    }

    lastReport = res.stdout;
    render(records);
    renderHeroMeta(records);
}

// ------------------------------------------------------------------ 操作
async function actFetch(btn) {
    btn.disabled = true;
    const old = btn.textContent;
    btn.textContent = '补齐中…';
    showToast('已在后台开始补齐资源，可继续用手机');

    // 丢到后台，立刻返回，不阻塞界面
    await exec('(nohup sh ' + q(FETCH_SH) + ' >/dev/null 2>&1 &) ; echo started', 15000);

    // 轮询进度，最多 3 分钟
    let ticks = 0;
    const timer = setInterval(async function () {
        ticks++;
        await refresh(true);
        if (ticks >= 18) {
            clearInterval(timer);
            btn.disabled = false;
            btn.textContent = old;
            showToast('后台补齐结束，请查看「资源」一栏');
        }
    }, 10000);
}

async function actRestartApp(btn) {
    btn.disabled = true;
    await exec('am force-stop ' + PA_PKG);
    toast('已停止应用卡中心，打开背屏即会重新读取预设');
    setTimeout(function () { btn.disabled = false; }, 1200);
}

// 往列表最前面插一张结果卡（refresh 会把整棵 DOM 重画，所以要在 refresh 之后再插）
function prependCard(title, detail, fix) {
    const box = document.createElement('div');
    box.className = 'item info';
    box.innerHTML = '<div class="dot">\u00b7</div><div class="body">' +
        '<div class="t">' + esc(title) + '</div>' +
        (detail ? '<div class="d">' + escNl(detail) + '</div>' : '') +
        (fix ? '<div class="fix">' + escNl(fix) + '</div>' : '') + '</div>';
    const wrap = document.getElementById('sections');
    wrap.insertBefore(box, wrap.firstChild);
}

// 执行 status.sh 用 action=<id> 指定的修复动作
async function runAction(id, btn) {
    const a = ACTIONS[id];
    if (!a) return;

    // 故意不用 window.confirm：弹不弹得出来取决于管理器有没有实现 onJsConfirm，
    // 没实现的管理器会静默丢弃对话框，按钮看起来就「点了没反应」。
    // 改成连点两次确认，只依赖 DOM，任何管理器都一样。
    if (btn.dataset.armed !== '1') {
        btn.dataset.armed = '1';
        btn.textContent = '再点一次确认';
        btn.classList.add('armed');
        clearTimeout(btn._t);
        btn._t = setTimeout(function () {
            btn.dataset.armed = '';
            btn.textContent = a.label;
            btn.classList.remove('armed');
        }, 8000);
        showToast(a.hint || '再点一次确认');
        return;
    }

    btn.dataset.armed = '';
    clearTimeout(btn._t);
    btn.classList.remove('armed');
    btn.disabled = true;
    btn.textContent = a.busy || '处理中…';

    const res = await exec(a.cmd, 60000);
    const out = (res.stdout || '').trim();
    const ok = /\bRESULT=ok\b/.test(out);
    const nothing = /\bRESULT=nothing\b/.test(out);

    // 去掉给机器看的那行，剩下的原样给用户看
    let lines = out.split('\n').filter(function (l) {
        return l.indexOf('RESULT=') !== 0;
    });
    // 脚本第一行是「已清除…：」这种标题，卡片标题已经说了，去掉免得重复
    if (lines.length > 1) lines = lines.slice(1);
    const human = lines.join('\n').trim();

    await refresh(true);

    prependCard(
        ok ? '已清除 REAREye 预设包' : (nothing ? '无需清除' : '清除失败'),
        human || (ok ? 'REAREye 的重定向钩子已失效' : '请导出日志反馈'),
        ok ? '重启手机后打开背屏即可看到卡片' : ''
    );
    window.scrollTo(0, 0);   // 结果卡插在最上面，别让它落在屏幕外
    showToast(ok ? '已清除，重启手机后生效' : (nothing ? '没有找到 REAREye 预设包' : '清除失败'));
}

async function actLogpack(btn) {
    btn.disabled = true;
    const old = btn.textContent;
    btn.textContent = '打包中…';

    const res = await exec('sh ' + q(LOGPACK_SH), 120000);
    const path = (res.stdout || '').trim().split('\n').pop();

    btn.disabled = false;
    btn.textContent = old;

    if (path && path.indexOf('/') === 0) {
        showToast('日志已保存：' + path);
        // 再存一份到剪贴板附近的地方，方便用户找
        window.__lastLogPath = path;
        const box = document.createElement('div');
        box.className = 'item info';
        box.innerHTML = '<div class="dot">\u00b7</div><div class="body">' +
            '<div class="t">日志包已生成</div>' +
            '<div class="d">' + esc(path) + '</div>' +
            '<div class="fix">用文件管理器进入 内部存储/Download 就能看到，直接发给开发者即可</div></div>';
        const wrap = document.getElementById('sections');
        wrap.insertBefore(box, wrap.firstChild);
    } else {
        showToast('打包失败，请把下面这段发给我');
        wrap_report();
    }
}

function wrap_report() {
    const ta = document.createElement('textarea');
    ta.value = lastReport;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); showToast('诊断内容已复制'); }
    catch (e) { showToast('复制失败，请手动截图'); }
    document.body.removeChild(ta);
}

async function actCopy() {
    // 用文本报告更好读，方便贴到社区
    const res = await exec('sh ' + q(STATUS_SH) + ' --text', 60000);
    const text = '【背屏应用卡中心 诊断】\n' + (res.stdout || lastReport);

    if (navigator.clipboard && navigator.clipboard.writeText) {
        try {
            await navigator.clipboard.writeText(text);
            showToast('诊断内容已复制，可直接粘贴');
            return;
        } catch (e) { /* 降级 */ }
    }

    // WebView 里剪贴板常常不可用 → 落盘一份
    const b64 = btoa(unescape(encodeURIComponent(text)));
    const res2 = await exec(
        'echo ' + q(b64) + ' | base64 -d > /sdcard/Download/appcard-diagnose.txt && echo ok',
        30000);
    if ((res2.stdout || '').indexOf('ok') >= 0) {
        showToast('已保存到 Download/appcard-diagnose.txt');
    } else {
        wrap_report();
    }
}

// ------------------------------------------------------------------ 启动
// 底部操作栏是 fixed 的，按钮换行时高度会变 —— 动态给 body 留出对应空间，
// 否则最后一个分组会被压住（真机上验证过）
function syncDockPadding() {
    const dock = document.querySelector('.dock');
    if (!dock) return;
    document.body.style.paddingBottom =
        (dock.getBoundingClientRect().height + 20) + 'px';
}

document.addEventListener('DOMContentLoaded', function () {
    document.getElementById('btn-refresh').addEventListener('click', function () { refresh(false); });
    document.getElementById('btn-fetch').addEventListener('click', function () { actFetch(this); });
    document.getElementById('btn-restart').addEventListener('click', function () { actRestartApp(this); });
    document.getElementById('btn-log').addEventListener('click', function () { actLogpack(this); });
    document.getElementById('btn-copy').addEventListener('click', function () { actCopy(this); });

    syncDockPadding();
    if (window.ResizeObserver) {
        new ResizeObserver(syncDockPadding).observe(document.querySelector('.dock'));
    }
    window.addEventListener('resize', syncDockPadding);

    refresh(false);
});

// 回到前台时自动刷新
document.addEventListener('visibilitychange', function () {
    if (!document.hidden) refresh(true);
});
