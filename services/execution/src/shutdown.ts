/**
 * Stop on SIGTERM without cutting a send in half.
 *
 * ECS stops a task with SIGTERM, then SIGKILL after the task's stopTimeout. Node runs as PID 1 in the container, and
 * PID 1 ignores SIGTERM unless it installs a handler -- so before this, every deploy waited out the timeout and
 * SIGKILLed the executor wherever it was: possibly between broadcasting a settlement and answering the matcher, which
 * then records a fill as failed that the chain has. (2026-10-09: SIGTERM at 20:02:25Z, killed at 20:03:19Z.)
 *
 * close() refuses new work (Fastify answers 503 on a connection that is still open; the matcher backs off and retries,
 * nothing having been sent), lets in-flight requests -- a send and its receipt wait -- finish, then exits.
 */
export function installGracefulShutdown(args: {
  close: () => Promise<void>;
  /**
   * Closes connections with no request in progress. Called repeatedly while draining: a keep-alive connection (the
   * matcher holds them) goes idle the moment its last response is sent, and would otherwise hold close() open for the
   * whole keep-alive timeout (Fastify's is 72s).
   */
  closeIdleConnections?: () => void;
  stop?: () => void;
  exit?: (code: number) => void;
  log?: (message: string) => void;
}): void {
  const exit = args.exit ?? ((code: number) => process.exit(code));
  const log = args.log ?? ((message: string) => process.stdout.write(`${JSON.stringify({ level: 'info', msg: message })}\n`));
  let stopping = false;
  const shutdown = (signal: string) => {
    if (stopping) return;
    stopping = true;
    log(`shutdown_started signal=${signal}`);
    args.stop?.();
    const sweep = args.closeIdleConnections ? setInterval(args.closeIdleConnections, 100) : undefined;
    args.close().then(
      () => {
        if (sweep) clearInterval(sweep);
        log('shutdown_complete');
        exit(0);
      },
      () => exit(1),
    );
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}
