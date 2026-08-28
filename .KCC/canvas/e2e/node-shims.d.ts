/**
 * Minimal ambient shims for the Node built-ins the deterministic E2E
 * control-plane server uses.
 *
 * The canvas is a browser bundle: the toolchain has no ``@types/node``
 * and the strict tsconfig (``noUncheckedIndexedAccess`` /
 * ``exactOptionalPropertyTypes``) type-checks ``e2e/`` too.  These
 * declarations cover exactly the Node API surface the fixture-backed
 * server touches — nothing more, nothing weaker.  They are
 * deliberately permissive (a test harness, never shipped); the E2E
 * assertions verify the observable behavior.
 */
declare module "node:http" {
  export interface IncomingMessage {
    method?: string;
    url?: string;
    on(event: "data", listener: (chunk: unknown) => void): void;
    on(event: "end", listener: () => void): void;
    on(event: "error", listener: (error: Error) => void): void;
  }

  export interface ServerResponse {
    writeHead(status: number, headers?: Record<string, string>): void;
    end(body?: string): void;
  }

  export interface Server {
    listen(port: number, host: string, callback: () => void): void;
    address(): { port: number } | null;
    close(): void;
    on(event: "error", listener: (error: Error) => void): void;
  }

  export function createServer(
    handler?: (request: IncomingMessage, response: ServerResponse) => void,
  ): Server;
}

declare module "node:fs" {
  export function readFileSync(path: string, encoding: string): string;
  export function existsSync(path: string): boolean;
}

declare module "node:path" {
  export function join(...parts: string[]): string;
  export function dirname(path: string): string;
  export function extname(path: string): string;
  export function normalize(path: string): string;
  export function relative(from: string, to: string): string;
}

declare module "node:url" {
  export function fileURLToPath(url: string): string;
}
