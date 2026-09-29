import { NextFunction, Request, Response } from 'express';
import client from 'prom-client';
import { log } from './logger';

export const register = new client.Registry();
register.setDefaultLabels({ app: process.env.SERVICE_NAME || 'realworld-api' });

// Process metrics: CPU, memory, event loop lag, GC...
client.collectDefaultMetrics({ register });

const labelNames = ['method', 'route', 'status_code'];

const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests handled by the API',
  labelNames,
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency in seconds',
  labelNames,
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

// Probes and scrapes run every few seconds; logging or counting them only adds noise.
const IGNORED_PATHS = new Set(['/healthz', '/readyz', '/metrics']);

/**
 * Uses the matched route template (/api/articles/:slug) as label, never the raw URL,
 * otherwise every slug becomes a new time series (cardinality explosion).
 * Express resets req.baseUrl once the nested router is done, so the /api prefix
 * (the only mount point, see routes.ts) is restored from the original URL.
 */
function routeOf(req: Request): string {
  if (!req.route?.path) return 'unmatched';
  const prefix = req.originalUrl.startsWith('/api/') ? '/api' : '';
  return `${prefix}${req.route.path}`;
}

export function httpObservability(req: Request, res: Response, next: NextFunction): void {
  if (IGNORED_PATHS.has(req.path)) return next();

  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    const labels = { method: req.method, route: routeOf(req), status_code: String(res.statusCode) };
    httpRequests.inc(labels);
    httpDuration.observe(labels, seconds);

    const level = res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info';
    log(level, 'request', {
      method: req.method,
      path: req.originalUrl,
      route: labels.route,
      status: res.statusCode,
      duration_ms: Math.round(seconds * 1000),
    });
  });
  next();
}
