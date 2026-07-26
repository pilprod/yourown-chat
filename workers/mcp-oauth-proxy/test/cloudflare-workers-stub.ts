export class WorkerEntrypoint<
  Env = unknown,
  Props extends Record<string, unknown> = Record<string, unknown>,
> {
  protected ctx: ExecutionContext<Props>;
  protected env: Env;

  constructor(ctx: ExecutionContext<Props>, env: Env) {
    this.ctx = ctx;
    this.env = env;
  }
}
