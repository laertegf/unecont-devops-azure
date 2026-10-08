import { NextFunction, Request, Response } from 'express';

/**
 * Fault injection, used only to test the deploy pipeline: a version that starts, passes
 * the probes and then fails real requests. That is the case "rollback by readiness" never
 * catches, and deploy.sh must catch it through the error rate instead.
 *
 * Off unless CHAOS_ERROR_RATE (0..1) is set. Probes and /metrics are never affected,
 * otherwise the pod would simply not become Ready and the test would prove nothing.
 */
export function faultInjection(rate = process.env.CHAOS_ERROR_RATE) {
  const errorRate = Number(rate);
  const enabled = rate !== undefined && rate !== '' && Number.isFinite(errorRate) && errorRate > 0;

  return (req: Request, res: Response, next: NextFunction): void => {
    if (!enabled || !req.path.startsWith('/api') || Math.random() >= errorRate) return next();
    res.status(500).json({ status: 'error', message: 'injected fault' });
  };
}
