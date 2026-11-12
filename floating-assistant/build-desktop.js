import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, renameSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32') throw new Error('Build the WPF helper on Windows.');

const root = fileURLToPath(new URL('.', import.meta.url));
const system = process.env.SystemRoot ?? 'C:\\Windows';
const framework = ['Framework64', 'Framework']
  .map(name => join(system, 'Microsoft.NET', name, 'v4.0.30319'))
  .find(path => existsSync(join(path, 'csc.exe')));
if (!framework) throw new Error('The .NET Framework C# compiler was not found.');

const source = join(root, 'desktop');
const bin = join(root, 'bin');
const executable = join(bin, 'DshFloatingAssistant.exe');
const pending = join(bin, 'DshFloatingAssistant.' + process.pid + '.exe');
const references = [
  'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll',
  'System.Web.Extensions.dll', 'System.Xaml.dll', 'System.Xml.dll', 'WPF/WindowsBase.dll',
  'WPF/PresentationCore.dll', 'WPF/PresentationFramework.dll',
];

mkdirSync(bin, { recursive: true });
try {
  execFileSync(join(framework, 'csc.exe'), [
    '/nologo', '/noconfig', '/target:winexe', '/optimize+', '/platform:anycpu',
    '/codepage:65001', '/utf8output', '/out:' + pending,
    '/win32manifest:' + join(source, 'app.manifest'),
    '/resource:' + join(root, 'panel.xaml') + ',panel.xaml',
    ...references.map(name => '/reference:' + join(framework, name)),
    ...readdirSync(source).filter(name => name.endsWith('.cs')).sort().map(name => join(source, name)),
  ], { stdio: 'inherit', windowsHide: true });
  renameSync(pending, executable);
} finally {
  rmSync(pending, { force: true });
}
