/** DSH 桌面截图插件：给 Agent 注册 screenshot 工具。
 *
 * 调用即通过 Windows GDI（CopyFromScreen）抓取整个虚拟桌面（所有显示器、
 * 任意应用窗口），弹出微信式全屏遮罩由用户框选区域，裁剪保存 PNG 并把
 * 文件路径返回给 Agent。逻辑全部在插件自带的 capture.ps1（PowerShell +
 * .NET）里完成，随插件分发，不依赖任何外部服务或常驻进程。
 */
import { execFile, spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { mkdtempSync, mkdirSync } from 'node:fs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CAPTURE_PS1 = join(HERE, 'capture.ps1');
const HOTKEY_WATCH_PS1 = join(HERE, 'hotkey-watch.ps1');
const HOTKEY_OUTPUT_DIR = join(tmpdir(), 'dsh-screenshot');
const DEFAULT_TIMEOUT_MS = 120_000;

/* 全局热键：Ctrl+Alt+A（刻意避开微信的 Alt+A 与 DSH 归档对话的 Ctrl+Shift+A）。
 * Win32 修饰符：MOD_ALT=0x1，MOD_CONTROL=0x2，MOD_SHIFT=0x4；VK_A=0x41。 */
const HOTKEY_MODIFIER = 0x1 | 0x2;   // Alt + Ctrl
const HOTKEY_VK = 0x41;              // A

/** @param {string[]} args @param {number} timeoutMs @param {AbortSignal} signal */
function runCapture(args, timeoutMs, signal) {
  return new Promise((resolve, reject) => {
    const child = execFile('powershell.exe',
      ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', CAPTURE_PS1, ...args],
      { timeout: timeoutMs, maxBuffer: 1024 * 1024, windowsHide: true },
      (error, stdout, stderr) => {
        if (error && error.killed) {
          reject(new Error(`截图等待超时（>${timeoutMs / 1000}s），用户可能没有完成框选。`));
          return;
        }
        resolve({ stdout: String(stdout ?? ''), stderr: String(stderr ?? ''), error });
      });
    const abort = () => child.kill();
    signal.addEventListener('abort', abort, { once: true });
    child.once('exit', () => signal.removeEventListener('abort', abort));
  });
}

export const inject = ['tools'];

async function captureRegion(timeoutMs, signal) {
  signal.throwIfAborted();
  const dir = mkdtempSync(join(tmpdir(), 'dsh-screenshot-'));
  const outPath = join(dir, 'screenshot.png');
  const { stdout, stderr, error } = await runCapture(['-OutPath', outPath], timeoutMs, signal);
  signal.throwIfAborted();
  const lines = stdout.split(/\r?\n/).filter(line => line.trim().startsWith('{'));
  let result;
  try {
    result = JSON.parse(lines[lines.length - 1]);
  } catch {
    throw new Error(`截图进程未返回结果（exit=${error?.code ?? '?'}）。stderr: ${stderr.slice(0, 400)}`);
  }
  if (!result.ok && result.reason !== 'cancelled') throw new Error(`截图失败：${result.reason}`);
  return result;
}

export function apply(ctx) {
  /* ---- 全局热键守护（Ctrl+Alt+A 唤起截图，独立隐藏进程）---- */
  mkdirSync(HOTKEY_OUTPUT_DIR, { recursive: true });
  const watcher = spawn('powershell.exe', [
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', HOTKEY_WATCH_PS1,
    '-ScriptPath', CAPTURE_PS1,
    '-OutDir', HOTKEY_OUTPUT_DIR,
    '-Modifier', String(HOTKEY_MODIFIER),
    '-VirtualKey', String(HOTKEY_VK),
    '-HotkeyName', 'Ctrl+Alt+A',
    '-OwnerProcessId', String(process.pid),
  ], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true, detached: false });
  watcher.stderr.setEncoding('utf8').on('data', (message) => {
    console.error('[dsh-screenshot] ' + message.trim());
  });
  watcher.once('error', (error) => {
    console.error('[dsh-screenshot] 无法启动全局热键守护进程', error);
  });
  watcher.once('exit', (code) => {
    if (code && code !== 2) console.error(`[dsh-screenshot] 全局热键守护进程退出（${code}）`);
  });

  // Cordis 在悬浮助手可用时挂载贡献，服务卸载时释放该注册。
  const floating = ctx.inject(['floatingAssistant'], (scope) => scope.floatingAssistant.register(
    'dsh-screenshot',
    [{
      version: 1,
      id: 'desktop',
      title: '桌面截图',
      provider: 'read',
      actions: [{ id: 'capture', label: '开始截图', handler: 'capture', hideWindow: true }],
    }],
    {
      read: () => ({
        status: 'ready',
        summary: '框选屏幕上的任意区域。确认后，截图和标注会保存为 PNG。',
        availableActions: [{ id: 'capture' }],
      }),
      async capture({ signal }) {
        const result = await captureRegion(DEFAULT_TIMEOUT_MS, signal);
        return { status: 'ok', message: result.ok ? `已保存到 ${result.path}` : '已取消截图。' };
      },
    },
  ));

  /* ---- Agent 工具：screenshot ---- */
  const dispose = ctx.tools.register({
    name: 'screenshot',
    description:
      '截取 Windows 桌面（整个屏幕，含所有应用窗口与多显示器），微信 PC 式交互：' +
      '桌面弹出全屏压暗遮罩，框选后可在工具栏标注、完成、取消或另存为。截图和标注一并保存为 PNG，' +
      '返回其文件路径。需要查看图片内容时用 read_image 打开该路径；' +
      '用户取消时返回 cancelled。调用会阻塞直到用户完成或取消截图，' +
      '需要用户配合操作屏幕时提前告知。',
    parameters: {
      timeout_ms: {
        type: 'number',
        description: '等待用户完成框选的最长时间（毫秒），默认 120000。',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args, exec) {
      const timeoutMs = Number.isFinite(args.timeout_ms) && args.timeout_ms > 1000
        ? args.timeout_ms : DEFAULT_TIMEOUT_MS;
      const result = await captureRegion(timeoutMs, exec.signal);
      if (!result.ok) {
        return JSON.stringify({ ok: false, reason: 'cancelled', note: '用户取消了截图。' });
      }
      return JSON.stringify({
        ok: true,
        path: result.path,
        region: { x: result.x, y: result.y, width: result.width, height: result.height },
        note: 'PNG 已保存到该路径；用 read_image 打开即可查看。按 Ctrl+Alt+A 也可随时手动唤起截图（自动复制到剪贴板）。',
      }, null, 2);
    },
    presentCall: () => ({
      card: 'generic',
      title: '桌面截图',
      kind: 'other',
      rawInput: {},
    }),
  });
  return () => {
    floating.dispose();
    watcher.kill();
    dispose();
  };
}
