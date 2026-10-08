import { Request, Response } from 'express';
import { faultInjection } from '../../app/observability/fault';

function run(path: string, rate?: string) {
  const req = { path } as Request;
  const res = { status: jest.fn().mockReturnThis(), json: jest.fn().mockReturnThis() } as unknown as Response;
  const next = jest.fn();
  faultInjection(rate)(req, res, next);
  return { res, next };
}

describe('faultInjection', () => {
  test('without CHAOS_ERROR_RATE it never touches the request', () => {
    const { res, next } = run('/api/tags', undefined);
    expect(next).toHaveBeenCalledTimes(1);
    expect(res.status).not.toHaveBeenCalled();
  });

  test('rate 1 fails every /api request with 500', () => {
    const { res, next } = run('/api/tags', '1');
    expect(res.status).toHaveBeenCalledWith(500);
    expect(res.json).toHaveBeenCalledWith({ status: 'error', message: 'injected fault' });
    expect(next).not.toHaveBeenCalled();
  });

  test('rate 1 leaves probes and metrics alone', () => {
    for (const path of ['/healthz', '/readyz', '/metrics']) {
      const { res, next } = run(path, '1');
      expect(next).toHaveBeenCalledTimes(1);
      expect(res.status).not.toHaveBeenCalled();
    }
  });

  test('rate 0 and invalid values pass everything through', () => {
    for (const rate of ['0', 'abc', '']) {
      const { res, next } = run('/api/articles', rate);
      expect(next).toHaveBeenCalledTimes(1);
      expect(res.status).not.toHaveBeenCalled();
    }
  });
});
