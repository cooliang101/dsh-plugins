import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const identifier = /^[a-z0-9][a-z0-9._@/-]{0,127}$/i;
const isId = (value) => typeof value === 'string' && identifier.test(value);
const isText = (value) => typeof value === 'string' && value.trim().length > 0;

function readPreferences(path) {
  try {
    const value = JSON.parse(readFileSync(path, 'utf8'));
    return {
      monitor: typeof value.monitor === 'string' ? value.monitor : '',
      defaultPanel: typeof value.defaultPanel === 'string' ? value.defaultPanel : '',
      disabled: new Set(Array.isArray(value.disabled) ? value.disabled.filter(isText) : []),
    };
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn('[floating-assistant] 无法读取偏好', error.message);
    return { monitor: '', defaultPanel: '', disabled: new Set() };
  }
}

function validateData(data, actions) {
  if (!['ready', 'empty'].includes(data?.status)) throw new Error('无效的数据状态');
  if (data.summary != null && typeof data.summary !== 'string') throw new Error('无效的摘要');
  const items = data.items ?? [];
  if (!Array.isArray(items) || new Set(items.map(item => item?.id)).size !== items.length ||
      items.some(item => !isId(item?.id) || !isText(item.text) ||
        (item.status != null && typeof item.status !== 'string'))) throw new Error('无效的列表项');
  const available = data.availableActions ?? [];
  if (!Array.isArray(available) || new Set(available.map(action => action?.id)).size !== available.length ||
      available.some(action => !actions.has(action?.id))) throw new Error('无效的可用操作');
  return { summary: data.summary, items, available, status: data.status };
}

export function createPanels({ path, render, suspend }) {
  const preferences = readPreferences(path);
  const panels = new Map();
  const active = new Map();
  const notices = new Map();
  let selected;
  let expanded = false;
  let settings = false;
  let read;
  let snapshot = { status: 'empty' };
  let revision = 0;
  let closed = false;
  let suspended = false;

  function publish() {
    if (closed) return;
    render({
      type: 'render', settings, selected, monitor: preferences.monitor,
      defaultPanel: preferences.defaultPanel,
      panels: [...panels.values()].map(({ key, title }) => ({
        key, title, enabled: !preferences.disabled.has(key),
      })),
      snapshot: {
        revision, status: snapshot.status, summary: snapshot.summary, items: snapshot.items,
        message: snapshot.message || notices.get(selected),
        actions: snapshot.available?.map(({ id }) => {
          const action = panels.get(selected).actions.get(id);
          return { id, label: action.label, disabled: active.has(selected) || suspended };
        }),
      },
    });
  }

  function save() {
    mkdirSync(dirname(path), { recursive: true });
    const temporary = path + '.' + process.pid + '.tmp';
    writeFileSync(temporary, JSON.stringify({ ...preferences, disabled: [...preferences.disabled] }));
    renameSync(temporary, path);
  }

  function available(key) {
    return panels.has(key) && !preferences.disabled.has(key);
  }

  function fallback() {
    if (available(preferences.defaultPanel)) return preferences.defaultPanel;
    return [...panels.keys()].sort().find(available);
  }

  async function refresh() {
    read?.abort();
    revision++;
    snapshot = { status: 'empty' };
    const panel = panels.get(selected);
    if (!expanded || settings || !panel) return publish();
    const controller = new AbortController();
    read = controller;
    const timeout = AbortSignal.timeout(8_000);
    const signal = AbortSignal.any([controller.signal, timeout]);
    snapshot = { status: 'loading' };
    publish();
    try {
      const result = await raceAbort(signal, () => panel.provider({ panelId: panel.id, signal }));
      if (read === controller && !controller.signal.aborted) snapshot = validateData(result, panel.actions);
    } catch (error) {
      if (controller.signal.aborted || read !== controller) return;
      console.warn('[floating-assistant]', panel.key, error.message);
      snapshot = { status: 'error', message: '读取失败，请刷新重试。' };
    }
    if (read === controller && !controller.signal.aborted) publish();
  }

  function updateSelection() {
    if (!available(selected)) {
      selected = fallback();
      void refresh();
    } else publish();
  }

  async function operate({ id, key: source, revision: displayedRevision }) {
    if (source !== selected || displayedRevision !== revision) return;
    const panel = panels.get(selected);
    const action = panel?.actions.get(id);
    const state = snapshot.available?.find(entry => entry.id === id);
    if (!expanded || settings || !action || !state || active.has(selected) || suspended) return;
    const { key } = panel;
    const controller = new AbortController();
    active.set(key, controller);
    notices.delete(key);
    if (action.hideWindow) suspended = true;
    publish();
    let restore;
    let ownsSuspension = action.hideWindow;
    let refreshRequested = false;
    function releaseWindow() {
      if (!ownsSuspension) return;
      restore?.();
      ownsSuspension = false;
      suspended = false;
    }
    const resume = () => { if (restore) releaseWindow(); };
    controller.signal.addEventListener('abort', resume, { once: true });
    const timer = setTimeout(() => {
      if (controller.signal.aborted) return;
      resume();
      notices.set(key, '等待超时，结果尚未确认。');
      publish();
    }, 125_000);
    timer.unref();
    try {
      if (action.hideWindow) restore = await suspend(controller.signal);
      controller.signal.throwIfAborted();
      const result = await action.handler({ panelId: panel.id, actionId: id,
        contextToken: state.contextToken, signal: controller.signal });
      if (controller.signal.aborted) return;
      if (!['ok', 'error'].includes(result?.status)) throw new Error('无效的操作结果');
      const message = typeof result.message === 'string' ? result.message : '';
      notices.set(key, message || (result.status === 'error' ? '操作失败。' : ''));
      refreshRequested = result.refresh === true;
    } catch (error) {
      if (!controller.signal.aborted) {
        console.warn('[floating-assistant]', key, id, error.message);
        notices.set(key, '操作失败，请查看实际状态。');
      }
    } finally {
      clearTimeout(timer);
      controller.signal.removeEventListener('abort', resume);
      releaseWindow();
      if (active.get(key) === controller) active.delete(key);
      if (!closed && !controller.signal.aborted && refreshRequested && selected === key) void refresh();
      else publish();
    }
  }

  return {
    register(pluginId, declarations, handlers) {
      if (!isId(pluginId) || !Array.isArray(declarations)) throw new TypeError('无效的面板注册');
      const registered = [];
      const ids = declarations.map(panel => panel?.id);
      for (const declaration of declarations) {
        try {
          const { version, id, title, provider, actions = [] } = declaration;
          const key = pluginId + ':' + id;
          const resolve = name => isId(name) && Object.hasOwn(handlers, name) &&
            typeof handlers[name] === 'function' ? handlers[name] : undefined;
          if (version !== 1 || !isId(id) || !isText(title) || !resolve(provider) ||
              ids.indexOf(id) !== ids.lastIndexOf(id) || panels.has(key) || !Array.isArray(actions)) {
            throw new Error('版本、声明、处理器或面板 ID 无效');
          }
          const actionMap = new Map();
          for (const action of actions) {
            const handler = resolve(action.handler);
            if (!isId(action.id) || !isText(action.label) || !handler || actionMap.has(action.id)) {
              throw new Error('操作声明无效');
            }
            actionMap.set(action.id, { label: action.label, hideWindow: action.hideWindow === true, handler });
          }
          panels.set(key, { key, id, title, provider: resolve(provider), actions: actionMap });
          registered.push(key);
        } catch (error) {
          console.warn('[floating-assistant]', pluginId, declaration?.id, error.message);
        }
      }
      updateSelection();
      return () => {
        for (const key of registered.splice(0)) {
          panels.delete(key);
          active.get(key)?.abort();
          active.delete(key);
          notices.delete(key);
        }
        updateSelection();
      };
    },
    invalidate(pluginId, panelId) {
      if (selected === pluginId + ':' + panelId && expanded && !settings) void refresh();
    },
    receive(event) {
      switch (event.type) {
        case 'ready': publish(); break;
        case 'expand': expanded = true; settings = false; selected = fallback(); void refresh(); break;
        case 'collapse': expanded = false; settings = false; read?.abort(); break;
        case 'settings': settings = !settings; void refresh(); break;
        case 'select': if (available(event.key)) { selected = event.key; void refresh(); } break;
        case 'refresh': notices.delete(selected); void refresh(); break;
        case 'action': void operate(event); break;
        case 'monitor':
          if (typeof event.monitor === 'string') { preferences.monitor = event.monitor; save(); publish(); }
          break;
        case 'default':
          if (available(event.key)) { preferences.defaultPanel = event.key; save(); publish(); }
          break;
        case 'toggle':
          if (!panels.has(event.key)) break;
          if (preferences.disabled.has(event.key)) preferences.disabled.delete(event.key);
          else preferences.disabled.add(event.key);
          save();
          updateSelection();
          break;
      }
    },
    close() {
      closed = true;
      read?.abort();
      for (const controller of active.values()) controller.abort();
    },
  };
}

function raceAbort(signal, run) {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve().then(run).then(resolve, reject)
      .finally(() => signal.removeEventListener('abort', abort));
  });
}
