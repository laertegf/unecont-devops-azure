import express from 'express';
import cors from 'cors';
import * as bodyParser from 'body-parser';
import routes from './app/routes/routes';
import HttpException from './app/models/http-exception.model';
import prisma from './prisma/prisma-client';
import health, { markShuttingDown } from './app/observability/health';
import { httpObservability } from './app/observability/metrics';
import { faultInjection } from './app/observability/fault';
import { log } from './app/observability/logger';

const app = express();

/**
 * App Configuration
 */

app.disable('x-powered-by');
app.use(httpObservability);
app.use(health);
app.use(faultInjection()); // no-op unless CHAOS_ERROR_RATE is set (pipeline tests only)
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(routes);

// Serves images
app.use(express.static(__dirname + '/assets'));

app.get('/', (req: express.Request, res: express.Response) => {
  res.json({ status: 'API is running on /api' });
});

/* eslint-disable */
app.use(
  (
    err: Error | HttpException,
    req: express.Request,
    res: express.Response,
    next: express.NextFunction,
  ) => {
    // @ts-ignore
    if (err && err.name === 'UnauthorizedError') {
      return res.status(401).json({
        status: 'error',
        message: 'missing authorization credentials',
      });
      // @ts-ignore
    } else if (err && err.errorCode) {
      // @ts-ignore
      res.status(err.errorCode).json(err.message);
    } else if (err) {
      log('error', 'unhandled error', {
        path: req.originalUrl,
        error: err.name,
        detail: err.message.trim().split('\n').pop(),
        stack: err.stack,
      });
      res.status(500).json(err.message);
    }
  },
);
/* eslint-enable */

/**
 * Server activation
 */

const PORT = Number(process.env.PORT) || 3000;

const server = app.listen(PORT, () => {
  log('info', 'server started', { port: PORT, node: process.version });
});

/**
 * Graceful shutdown: on SIGTERM (rolling update, scale down, docker stop) stop accepting
 * connections, let in-flight requests finish and close the database pool.
 * The hard timeout stays below Kubernetes' terminationGracePeriodSeconds (30s).
 */
function shutdown(signal: string) {
  log('info', 'shutdown requested', { signal });
  markShuttingDown();
  server.close(async () => {
    await prisma.$disconnect();
    log('info', 'shutdown complete');
    process.exit(0);
  });
  setTimeout(() => {
    log('error', 'shutdown timed out, forcing exit');
    process.exit(1);
  }, 20_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
