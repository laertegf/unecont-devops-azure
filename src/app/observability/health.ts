import { Request, Response, Router } from 'express';
import prisma from '../../prisma/prisma-client';
import { register } from './metrics';

let shuttingDown = false;

export function markShuttingDown(): void {
  shuttingDown = true;
}

const router = Router();

/**
 * Liveness: only says the process is alive and the event loop responds.
 * It does NOT check the database: if Postgres goes down, restarting every pod
 * would not fix anything and would only add a restart storm on top of the outage.
 */
router.get('/healthz', (_req: Request, res: Response) => {
  res.json({ status: 'ok' });
});

/**
 * Readiness: the API is useless without the database, so a pod that cannot reach it
 * leaves the Service endpoints until it recovers. During shutdown it returns 503 so
 * Kubernetes stops sending new traffic before the process exits.
 */
router.get('/readyz', async (_req: Request, res: Response) => {
  if (shuttingDown) {
    res.status(503).json({ status: 'shutting down' });
    return;
  }
  try {
    await prisma.$queryRaw`SELECT 1`;
    res.json({ status: 'ready' });
  } catch {
    res.status(503).json({ status: 'database unavailable' });
  }
});

router.get('/metrics', async (_req: Request, res: Response) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

export default router;
