// The Windows dashboard: a port of the macOS SwiftUI dashboard
// (Sources/aimonitor-app). Every number and label arrives already formatted in
// the agent's snapshot (Sources/AIMonitorCore/UISnapshot.swift); this file only
// lays it out and sends the user's choices back through the WebView2 host.
//
// All dynamic text goes through text nodes, never HTML: project and model
// names come from log files.
'use strict';

(() => {
  const host = window.chrome && window.chrome.webview;
  const state = {
    snap: null,
    page: 'dashboard',
    menuOpen: false,
    confirmDelete: false,
    exportedPath: null,
    scroll: {},
  };
  let confirmTimer = null;

  const send = msg => { if (host) host.postMessage(msg); };

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : String(v));
    }
    for (const c of children.flat(Infinity)) {
      if (c == null || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }

  const t = key => (state.snap && state.snap.strings[key]) || key;
  const label = text => h('div', { class: 'section-label' }, text);
  const empty = text => h('div', { class: 'empty' }, text);
  const hairline = () => h('div', { class: 'hairline' });

  function track(fraction, kind) {
    const fill = h('div', { class: 'fill' + (kind ? ' ' + kind : '') });
    fill.style.width = `${Math.min(1, Math.max(0, fraction || 0)) * 100}%`;
    return h('div', { class: 'track' }, fill);
  }

  // Same buckets as ActiveNowRow.age; Int() truncates toward zero.
  function age(lastEventAt) {
    const s = Math.trunc(Date.now() / 1000 - lastEventAt);
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.trunc(s / 60)}m`;
    return `${Math.trunc(s / 3600)}h ${Math.trunc((s % 3600) / 60)}m`;
  }

  function applyTheme() {
    const root = document.documentElement;
    root.dataset.theme = state.snap ? state.snap.settings.appearance : 'system';
    root.lang = state.snap && state.snap.settings.resolvedLanguage === 'zh' ? 'zh-CN' : 'en';
    root.style.setProperty('--hair', `${1 / (window.devicePixelRatio || 1)}px`);
  }

  // MARK: Settings changes — shown at once, confirmed by the next snapshot.

  const settingFields = {
    appearance: 'appearance',
    language: 'language',
    claude_quota_optin: 'claudeQuota',
    kimi_quota_optin: 'kimiQuota',
    notifications_enabled: 'notifications',
  };

  function setSetting(key, value) {
    const field = settingFields[key];
    state.snap.settings[field] = value === 'true' ? true : value === 'false' ? false : value;
    render();
    send({ cmd: 'setSetting', key, value });
  }

  // MARK: Today

  function dashboardPage(s) {
    const d = s.today;
    return h('div', { class: 'stack dashboard' },
      h('div', { class: 'hero' },
        h('div', { class: 'hero-main' },
          h('span', { class: 'display' }, d.tokens),
          h('span', { class: 'hero-label' }, t('tokensToday'))),
        h('div', { class: 'hero-stats' },
          [[t('time'), d.time], [t('cost'), d.cost], [t('requests'), d.requests]].map(([l, v]) =>
            h('div', { class: 'stat' }, h('span', { class: 'v' }, v), h('span', { class: 'l' }, l))))),

      d.activeNow && h('div', { class: 'active' },
        h('span', { class: 'dot' }),
        h('span', { class: 'name' }, d.activeNow.provider + (d.activeNow.model ? ` · ${d.activeNow.model}` : '')),
        h('span', { class: 'age', 'data-age': d.activeNow.lastEventAt }, age(d.activeNow.lastEventAt))),

      h('div', { class: 'section' },
        label(t('usage')),
        d.usage.length === 0
          ? empty(t('noUsageToday'))
          : d.usage.map((u, i) => h('div', { class: 'share' },
              h('span', { class: 'name' }, u.provider),
              track(u.fraction, i === 0 ? null : 'soft'),
              h('span', { class: 'pct' }, u.percent)))),

      h('div', { class: 'section' },
        h('div', { class: 'row' },
          label(t('tokenFlow')),
          h('div', { class: 'ranges' },
            [['Today', 'rangeToday'], ['7D', 'range7D'], ['30D', 'range30D'], ['All', 'rangeAll']].map(([value, key]) =>
              h('button', {
                class: 'range' + (s.settings.flowRange === value ? ' selected' : ''),
                onclick: () => { s.settings.flowRange = value; render(); send({ cmd: 'setFlowRange', value }); },
              }, t(key))))),
        d.flow.values.length === 0 ? empty(t('noUsageInRange')) : flowChart(d.flow)),

      h('div', { class: 'section quota' },
        label(t('quota')),
        d.quotas.length === 0 && empty(t('noQuotaData')),
        d.quotas.map(q => h('div', { class: 'quota-row' },
          h('div', { class: 'row baseline' },
            h('span', { class: 'title' }, q.title),
            h('span', { class: 'detail' + (q.warn ? ' warn' : '') }, q.detail)),
          track(q.fraction, q.warn ? 'warn' : 'soft'),
          q.projection && h('div', { class: 'pace' }, q.projection)))));
  }

  // Bars only, no axis chrome; the most recent bar gets the accent.
  function flowChart(flow) {
    const max = Math.max(...flow.values) || 1;
    const n = flow.values.length;
    return h('div', { class: 'flow' },
      h('div', { class: 'bars' }, flow.values.map((v, i) => {
        const bar = h('div', { class: 'bar' + (i === n - 1 ? ' last' : '') });
        bar.style.width = 'max(2px, 62%)';
        bar.style.height = `max(2px, ${(48 * v) / max}px)`;
        return h('div', { class: 'slot' }, bar);
      })),
      h('div', { class: 'labels' }, h('span', null, flow.firstLabel), h('span', null, flow.lastLabel)));
  }

  // MARK: Timeline

  function chevrons() {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 6 9');
    svg.setAttribute('class', 'chevrons');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M1 3.2 3 1.2 5 3.2M1 5.8 3 7.8 5 5.8');
    svg.append(path);
    return svg;
  }

  function pickProvider(provider) {
    state.menuOpen = false;
    state.snap.settings.timelineProvider = provider;
    render();
    send({ cmd: 'setTimelineProvider', value: provider });
  }

  function timelineHeader(s) {
    const tl = s.timeline;
    return h('div', { class: 'filter' },
      h('button', {
        class: 'filter-button',
        onclick: e => { e.stopPropagation(); state.menuOpen = !state.menuOpen; render(); },
      }, h('span', null, s.settings.timelineProvider || t('allProviders')), chevrons()),
      state.menuOpen && h('div', { class: 'menu', onclick: e => e.stopPropagation() },
        h('button', { onclick: () => pickProvider(null) }, t('allProviders')),
        h('div', { class: 'divider' }),
        tl.providers.map(p => h('button', { onclick: () => pickProvider(p) }, p))));
  }

  function timelinePage(s) {
    const days = s.timeline.days;
    if (days.length === 0) return h('div', { class: 'timeline-empty' }, empty(t('noEvents')));
    return h('div', null, days.map(day => [
      h('div', { class: 'day-label section-label' }, day.label),
      day.events.map(e => h('div', { class: 'event' },
        h('span', { class: 'time' }, e.time),
        h('div', { class: 'what' },
          h('div', { class: 'who' },
            h('span', { class: 'provider' }, e.provider),
            e.model && h('span', { class: 'model' }, e.model)),
          e.project && h('span', { class: 'project' }, e.project)),
        h('span', { class: 'tokens' }, e.tokens))),
    ]));
  }

  // MARK: Models

  function modelsPage(s) {
    return h('div', null, s.models.map(m => h('div', { class: 'model-row' },
      h('div', { class: 'row baseline' },
        h('span', { class: 'name' }, m.model),
        h('span', { class: 'tokens' }, m.tokens)),
      h('div', { class: 'row' },
        h('span', { class: 'small' }, m.provider),
        h('span', { class: 'small' }, m.detail)),
      track(m.fraction, 'soft'))));
  }

  // MARK: Settings

  function choices(options, selected, onPick) {
    return h('div', { class: 'choices' }, options.map(([value, text]) =>
      h('button', { class: 'choice' + (selected === value ? ' selected' : ''), onclick: () => onPick(value) }, text)));
  }

  function toggle(text, on, onChange) {
    return h('button', {
      class: 'toggle', role: 'switch', 'aria-checked': on ? 'true' : 'false',
      onclick: () => onChange(!on),
    }, h('span', { class: 'label' }, text), h('span', { class: 'switch' + (on ? ' on' : '') }));
  }

  const group = (title, ...body) => h('div', { class: 'section tight' }, label(title), body);
  const detail = text => h('div', { class: 'detail-text' }, text);
  const note = (name, body) => h('div', { class: 'note' }, h('span', { class: 'name' }, name), h('span', { class: 'body' }, body));

  function deleteButton() {
    return h('button', {
      class: 'delete' + (state.confirmDelete ? ' confirm' : ''),
      onclick: () => {
        clearTimeout(confirmTimer);
        if (state.confirmDelete) {
          state.confirmDelete = false;
          send({ cmd: 'deleteAll' });
        } else {
          state.confirmDelete = true;
          confirmTimer = setTimeout(() => { state.confirmDelete = false; render(); }, 3000);
        }
        render();
      },
    }, state.confirmDelete ? t('deleteConfirm') : t('deleteAll'));
  }

  function settingsPage(s) {
    const st = s.settings;
    const bool = on => (on ? 'true' : 'false');
    return h('div', { class: 'stack settings' },
      group(t('appearance'),
        choices([['system', t('appearanceSystem')], ['light', t('appearanceLight')], ['dark', t('appearanceDark')]],
          st.appearance, v => setSetting('appearance', v))),
      group(t('language'),
        choices([['system', t('languageSystem')], ['en', 'English'], ['zh', '中文']],
          st.language, v => setSetting('language', v))),
      hairline(),
      group(t('claudeQuota').toUpperCase(),
        toggle(t('claudeQuota'), st.claudeQuota, on => setSetting('claude_quota_optin', bool(on))),
        detail(t('claudeQuotaDetail'))),
      group(t('kimiQuota').toUpperCase(),
        toggle(t('kimiQuota'), st.kimiQuota, on => setSetting('kimi_quota_optin', bool(on))),
        detail(t('kimiQuotaDetail'))),
      group(t('exportCard').toUpperCase(),
        h('div', { class: 'choices' }, s.providersPresent.map(p =>
          h('button', { class: 'choice', onclick: () => send({ cmd: 'exportCard', provider: p }) }, p))),
        state.exportedPath && detail(t('exportCardDone') + state.exportedPath)),
      hairline(),
      h('div', { class: 'section' },
        label(t('collectorsAccess')),
        note('Claude Code', t('claudeCollectorNote')),
        note('Codex CLI', t('codexCollectorNote')),
        note('Kimi Code', t('kimiCollectorNote')),
        detail(t('storageNote'))),
      group(t('retention'),
        choices([['7', t('retention7')], ['30', t('retention30')], ['90', t('retention90')],
                 ['365', t('retentionYear')], ['0', t('retentionForever')]],
          st.retentionDays, v => { st.retentionDays = v; render(); send({ cmd: 'setRetention', value: v }); })),
      group(t('notifications'),
        toggle(t('notificationsDetail'), st.notifications, on => setSetting('notifications_enabled', bool(on)))),
      group('DELETE', deleteButton(), detail(t('deleteNote'))));
  }

  // MARK: Root

  const pages = [
    ['dashboard', 'tabToday', dashboardPage],
    ['timeline', 'tabTimeline', timelinePage],
    ['models', 'tabModels', modelsPage],
    ['settings', 'tabSettings', settingsPage],
  ];

  function render() {
    const app = document.getElementById('app');
    const old = app.querySelector('.page');
    if (old) state.scroll[old.dataset.page] = old.scrollTop;
    applyTheme();

    const s = state.snap;
    if (!s) {
      app.replaceChildren(
        h('div', { class: 'top' }, h('span', { class: 'title' }, 'AI Monitor')),
        h('div', { class: 'loading' }, h('div', { class: 'spinner' })));
      return;
    }

    const [, , pageView] = pages.find(([id]) => id === state.page);
    const scroller = h('div', { class: 'page', 'data-page': state.page }, pageView(s));
    app.replaceChildren(...[
      h('div', { class: 'top' },
        h('span', { class: 'title' }, s.header.title),
        h('span', { class: 'date' }, s.header.date)),
      h('nav', { class: 'tabs' }, pages.map(([id, key]) =>
        h('button', {
          class: 'tab' + (state.page === id ? ' selected' : ''),
          onclick: () => { state.page = id; state.menuOpen = false; render(); },
        }, h('span', null, t(key)), h('span', { class: 'underline' })))),
      hairline(),
      state.page === 'timeline' && [timelineHeader(s), hairline()],
      scroller,
    ].flat().filter(Boolean));
    scroller.scrollTop = state.scroll[state.page] || 0;
  }

  function receive(msg) {
    if (!msg || typeof msg !== 'object') return;
    switch (msg.type) {
      case 'snapshot':
        state.snap = msg.data;
        break;
      case 'cardExported':
        state.exportedPath = (msg.data && msg.data.path) || null;
        break;
      case 'host':
        if (msg.data && /^#[0-9A-Fa-f]{6}$/.test(msg.data.accent || '')) {
          document.documentElement.style.setProperty('--control-accent', msg.data.accent);
        }
        return;
      default:
        return;
    }
    render();
  }

  // For the host's smoke test: renders every page and returns its text.
  window.__aimonitor = {
    report() {
      if (!state.snap) return JSON.stringify({ rendered: false });
      const saved = state.page;
      const text = {};
      for (const [id] of pages) {
        state.page = id;
        render();
        text[id] = document.getElementById('app').innerText;
      }
      state.page = saved;
      render();
      return JSON.stringify({ rendered: true, generatedAt: state.snap.generatedAt, pages: text });
    },
    show(page) {
      if (!pages.some(([id]) => id === page)) return false;
      state.page = page;
      render();
      return true;
    },
  };

  document.addEventListener('click', () => { if (state.menuOpen) { state.menuOpen = false; render(); } });
  window.addEventListener('resize', applyTheme);
  setInterval(() => {
    for (const el of document.querySelectorAll('[data-age]')) el.textContent = age(Number(el.dataset.age));
  }, 1000);
  if (host) host.addEventListener('message', e => receive(e.data));

  render();
  send({ cmd: 'ready' });
})();
