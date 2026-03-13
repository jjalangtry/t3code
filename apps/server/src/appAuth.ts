import crypto from "node:crypto";
import type { IncomingHttpHeaders } from "node:http";

import type { AppAuthLoginInput, AppAuthLoginResult, AppAuthSession } from "@t3tools/contracts";

export const APP_AUTH_SESSION_QUERY_PARAM = "auth_session";

interface AppAuthManagerConfig {
  readonly username: string | undefined;
  readonly password: string | undefined;
  readonly sessionTtlDays: number;
}

interface AppAuthSessionRecord {
  readonly token: string;
  readonly username: string;
  readonly expiresAt: number;
}

function normalizeUsername(value: string): string {
  return value.trim();
}

function sha256(value: string): Buffer {
  return crypto.createHash("sha256").update(value, "utf8").digest();
}

function timingSafeEqualString(left: string, right: string): boolean {
  return crypto.timingSafeEqual(sha256(left), sha256(right));
}

function readBearerToken(headers: IncomingHttpHeaders): string | undefined {
  const authorization = headers.authorization;
  if (typeof authorization !== "string") {
    return undefined;
  }
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || undefined;
}

export class AppAuthManager {
  private readonly sessions = new Map<string, AppAuthSessionRecord>();

  constructor(private readonly config: AppAuthManagerConfig) {}

  get isEnabled(): boolean {
    return Boolean(this.config.username && this.config.password);
  }

  readSessionToken(
    requestUrl: string | URL | undefined,
    headers: IncomingHttpHeaders,
  ): string | undefined {
    const bearerToken = readBearerToken(headers);
    if (bearerToken) {
      return bearerToken;
    }

    if (!requestUrl) {
      return undefined;
    }

    try {
      const url = requestUrl instanceof URL ? requestUrl : new URL(requestUrl, "http://localhost");
      return url.searchParams.get(APP_AUTH_SESSION_QUERY_PARAM) ?? undefined;
    } catch {
      return undefined;
    }
  }

  readSession(sessionToken: string | undefined): AppAuthSession {
    if (!this.isEnabled) {
      return {
        authRequired: false,
        authenticated: true,
        username: null,
      };
    }

    const session = this.validateSessionToken(sessionToken);
    if (!session) {
      return {
        authRequired: true,
        authenticated: false,
        username: null,
      };
    }

    return {
      authRequired: true,
      authenticated: true,
      username: session.username,
    };
  }

  login(input: AppAuthLoginInput): AppAuthLoginResult | null {
    if (!this.isEnabled || !this.config.username || !this.config.password) {
      return null;
    }

    const normalizedExpectedUsername = normalizeUsername(this.config.username);
    const normalizedProvidedUsername = normalizeUsername(input.username);
    const validUsername = timingSafeEqualString(
      normalizedProvidedUsername,
      normalizedExpectedUsername,
    );
    const validPassword = timingSafeEqualString(input.password, this.config.password);

    if (!validUsername || !validPassword) {
      return null;
    }

    const token = crypto.randomBytes(32).toString("base64url");
    const expiresAt = Date.now() + Math.max(1, this.config.sessionTtlDays) * 24 * 60 * 60 * 1000;
    const session: AppAuthSessionRecord = {
      token,
      username: normalizedExpectedUsername,
      expiresAt,
    };
    this.sessions.set(token, session);

    return {
      session: {
        authRequired: true,
        authenticated: true,
        username: session.username,
      },
      sessionToken: token,
    };
  }

  logout(sessionToken: string | undefined): void {
    if (!sessionToken) {
      return;
    }
    this.sessions.delete(sessionToken);
  }

  validateSessionToken(sessionToken: string | undefined): AppAuthSessionRecord | null {
    this.cleanupExpiredSessions();

    if (!sessionToken) {
      return null;
    }

    const session = this.sessions.get(sessionToken);
    if (!session) {
      return null;
    }
    if (session.expiresAt <= Date.now()) {
      this.sessions.delete(sessionToken);
      return null;
    }
    return session;
  }

  private cleanupExpiredSessions(): void {
    const now = Date.now();
    for (const [token, session] of this.sessions.entries()) {
      if (session.expiresAt <= now) {
        this.sessions.delete(token);
      }
    }
  }
}
