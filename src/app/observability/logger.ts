/**
 * Minimal structured logger.
 *
 * One JSON object per line on stdout, so Docker/Kubernetes collect it without
 * any agent inside the container, and Loki/Alloy can parse the fields
 * (level, status, route...) instead of regex-matching free text.
 */
type Level = 'debug' | 'info' | 'warn' | 'error';

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const minLevel = LEVELS[(process.env.LOG_LEVEL as Level) || 'info'] ?? LEVELS.info;
const service = process.env.SERVICE_NAME || 'realworld-api';

export function log(level: Level, msg: string, fields: Record<string, unknown> = {}): void {
  if (LEVELS[level] < minLevel) return;
  const line = { ts: new Date().toISOString(), level, service, msg, ...fields };
  process.stdout.write(JSON.stringify(line) + '\n');
}
