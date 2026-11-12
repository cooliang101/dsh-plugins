import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPanels } from './panels.js';

export function apply(ctx) {
  if (process.platform !== 'win32') return;
  const child = spawn('powershell.exe', [
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
    fileURLToPath(new URL('./desktop.ps1', import.meta.url)),
  ], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  const lines = createInterface({ input: child.stdout });
  let stopped = false;
  let sequence = 0;
  let hidden;

  function send(message) {
    if (!stopped && !child.stdin.destroyed) child.stdin.write(JSON.stringify(message) + '\n');
  }

  const panels = createPanels({
    path: join(process.env.LOCALAPPDATA ?? homedir(), 'DSH', 'floating-assistant', 'preferences.json'),
    render: send,
    async suspend(signal) {
      const id = ++sequence;
      const restore = () => send({ type: 'restore', id });
      const wait = AbortSignal.any([signal, AbortSignal.timeout(3_000)]);
      try {
        wait.throwIfAborted();
        await new Promise((resolve, reject) => {
          const abort = () => reject(wait.reason);
          wait.addEventListener('abort', abort, { once: true });
          hidden = { id, resolve, cleanup: () => wait.removeEventListener('abort', abort) };
          send({ type: 'hide', id });
        });
        return restore;
      } catch (error) {
        restore();
        throw error;
      } finally {
        hidden?.cleanup();
        hidden = undefined;
      }
    },
  });

  function stop() {
    if (stopped) return;
    stopped = true;
    panels.close();
    lines.close();
    child.stdin.destroy();
    if (child.exitCode === null) child.kill();
  }

  child.stdin.on('error', stop);
  child.stderr.setEncoding('utf8').on('data', message => console.error('[floating-assistant]', message.trim()));
  child.once('error', error => { console.error('[floating-assistant]', error.message); stop(); });
  child.once('exit', code => {
    if (!stopped && code) console.error('[floating-assistant] 桌面进程退出', code);
    stop();
  });
  lines.on('line', line => {
    try {
      const event = JSON.parse(line);
      if (event.type === 'hidden') {
        if (hidden?.id === event.id) hidden.resolve();
      } else panels.receive(event);
    } catch (error) {
      console.warn('[floating-assistant] 无法处理桌面消息', error.message);
    }
  });
  ctx.provide('floatingAssistant', { register: panels.register, invalidate: panels.invalidate });
  return stop;
}
