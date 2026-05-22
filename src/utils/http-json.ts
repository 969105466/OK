/**
 * JSON HTTP client.
 * On Windows: PowerShell Invoke-RestMethod (Node fetch/https often times out).
 * Elsewhere: Node https (IPv4).
 */
import { execFile } from 'node:child_process';
import https from 'node:https';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

async function getJsonPowerShell<T>(url: string, timeoutMs: number): Promise<T> {
  const escaped = url.replace(/'/g, "''");
  const sec = Math.max(5, Math.ceil(timeoutMs / 1000));
  const script =
    `$ProgressPreference='SilentlyContinue';` +
    `$r=Invoke-RestMethod -Uri '${escaped}' -TimeoutSec ${sec};` +
    `$r | ConvertTo-Json -Compress -Depth 12`;

  const { stdout } = await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    {
      maxBuffer: 64 * 1024 * 1024,
      timeout: timeoutMs + 10_000,
    },
  );

  const text = stdout.trim();
  if (!text) throw new Error('empty PowerShell response');
  return JSON.parse(text) as T;
}

async function postJsonPowerShell(
  url: string,
  payload: Record<string, unknown>,
  timeoutMs: number,
): Promise<unknown> {
  const body = JSON.stringify(payload).replace(/'/g, "''");
  const sec = Math.max(5, Math.ceil(timeoutMs / 1000));
  const escaped = url.replace(/'/g, "''");
  const script =
    `$ProgressPreference='SilentlyContinue';` +
    `$b='${body}';` +
    `Invoke-RestMethod -Uri '${escaped}' -Method Post -ContentType 'application/json; charset=utf-8' -Body $b -TimeoutSec ${sec} | ConvertTo-Json -Compress -Depth 5`;

  const { stdout } = await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    { maxBuffer: 4 * 1024 * 1024, timeout: timeoutMs + 10_000 },
  );

  const text = stdout.trim();
  if (!text) return {};
  return JSON.parse(text);
}

function getJsonNode<T>(url: string, timeoutMs: number): Promise<T> {
  const u = new URL(url);
  return new Promise((resolve, reject) => {
    const req = https.get(
      {
        hostname: u.hostname,
        port: 443,
        path: u.pathname + u.search,
        family: 4,
        servername: u.hostname,
        headers: { 'User-Agent': 'bn-paper-market/1.0' },
      },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => {
          body += c;
        });
        res.on('end', () => {
          if ((res.statusCode ?? 0) >= 400) {
            reject(
              new Error(`HTTP ${res.statusCode}: ${body.slice(0, 200)}`),
            );
            return;
          }
          try {
            resolve(JSON.parse(body) as T);
          } catch (e) {
            reject(e);
          }
        });
      },
    );
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`timeout ${timeoutMs}ms`));
    });
  });
}

export async function getJson<T>(url: string, timeoutMs = 25_000): Promise<T> {
  if (process.platform === 'win32') {
    return getJsonPowerShell<T>(url, timeoutMs);
  }
  return getJsonNode<T>(url, timeoutMs);
}

export async function postJson(
  url: string,
  payload: Record<string, unknown>,
  timeoutMs = 30_000,
): Promise<unknown> {
  if (process.platform === 'win32') {
    return postJsonPowerShell(url, payload, timeoutMs);
  }

  const u = new URL(url);
  const body = JSON.stringify(payload);
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: u.hostname,
        port: 443,
        path: u.pathname,
        method: 'POST',
        family: 4,
        servername: u.hostname,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => {
          data += c;
        });
        res.on('end', () => {
          if ((res.statusCode ?? 0) >= 400) {
            reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 300)}`));
            return;
          }
          try {
            resolve(JSON.parse(data));
          } catch {
            resolve(data);
          }
        });
      },
    );
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`timeout ${timeoutMs}ms`));
    });
    req.write(body);
    req.end();
  });
}
