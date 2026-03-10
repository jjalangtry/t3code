import {
  AppAuthErrorResponse,
  type AppAuthLoginResult as AppAuthLoginResultPayload,
  AppAuthLoginResult,
  type AppAuthSession as AppAuthSessionPayload,
  AppAuthSession,
} from "@t3tools/contracts";
import { Schema } from "effect";

const APP_AUTH_SESSION_STORAGE_KEY = "t3code.app_auth.session_token";

const decodeAppAuthSession = Schema.decodeUnknownSync(AppAuthSession);
const decodeAppAuthLoginResult = Schema.decodeUnknownSync(AppAuthLoginResult);
const decodeAppAuthErrorResponse = Schema.decodeUnknownSync(AppAuthErrorResponse);

export function resolveServerHttpOrigin(): string {
  if (typeof window === "undefined") return "";
  const bridgeUrl = window.desktopBridge?.getWsUrl?.();
  const envUrl = import.meta.env.VITE_WS_URL as string | undefined;
  const injectedWsUrl = window.__T3CODE_WS_URL__;
  const wsCandidate =
    typeof bridgeUrl === "string" && bridgeUrl.length > 0
      ? bridgeUrl
      : typeof envUrl === "string" && envUrl.length > 0
        ? envUrl
        : typeof injectedWsUrl === "string" && injectedWsUrl.length > 0
          ? injectedWsUrl
          : null;

  if (!wsCandidate) {
    return window.location.origin;
  }

  try {
    const wsUrl = new URL(wsCandidate);
    const protocol =
      wsUrl.protocol === "wss:" ? "https:" : wsUrl.protocol === "ws:" ? "http:" : wsUrl.protocol;
    return `${protocol}//${wsUrl.host}`;
  } catch {
    return window.location.origin;
  }
}

export function readStoredAppAuthSessionToken(): string | null {
  if (typeof window === "undefined") {
    return null;
  }
  const token = window.localStorage.getItem(APP_AUTH_SESSION_STORAGE_KEY);
  if (!token || token.trim().length === 0) {
    return null;
  }
  return token;
}

export function writeStoredAppAuthSessionToken(token: string): void {
  if (typeof window === "undefined") {
    return;
  }
  window.localStorage.setItem(APP_AUTH_SESSION_STORAGE_KEY, token);
}

export function clearStoredAppAuthSessionToken(): void {
  if (typeof window === "undefined") {
    return;
  }
  window.localStorage.removeItem(APP_AUTH_SESSION_STORAGE_KEY);
}

export function appendAppAuthSessionToUrl(rawUrl: string): string {
  const sessionToken = readStoredAppAuthSessionToken();
  if (!sessionToken) {
    return rawUrl.startsWith("/") ? `${resolveServerHttpOrigin()}${rawUrl}` : rawUrl;
  }

  const url = rawUrl.startsWith("/")
    ? new URL(rawUrl, resolveServerHttpOrigin())
    : new URL(rawUrl);
  url.searchParams.set("auth_session", sessionToken);
  return url.toString();
}

function authHeaders(): HeadersInit | undefined {
  const sessionToken = readStoredAppAuthSessionToken();
  if (!sessionToken) {
    return undefined;
  }
  return {
    Authorization: `Bearer ${sessionToken}`,
  };
}

function authUrl(pathname: string): string {
  return `${resolveServerHttpOrigin()}${pathname}`;
}

export async function fetchAppAuthSession(): Promise<AppAuthSessionPayload> {
  const headers = authHeaders();
  const response = await fetch(authUrl("/api/auth/session"), {
    method: "GET",
    ...(headers ? { headers } : {}),
  });

  const payload = decodeAppAuthSession(await response.json());
  if (payload.authRequired && !payload.authenticated) {
    clearStoredAppAuthSessionToken();
  }
  return payload;
}

export async function loginWithAppAuth(input: {
  username: string;
  password: string;
}): Promise<AppAuthLoginResultPayload> {
  const response = await fetch(authUrl("/api/auth/login"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(input),
  });

  const raw = await response.json().catch(() => null);
  if (!response.ok) {
    if (raw !== null) {
      let errorMessage: string | null = null;
      try {
        errorMessage = decodeAppAuthErrorResponse(raw).message;
      } catch {
        errorMessage = null;
      }
      if (errorMessage) {
        throw new Error(errorMessage);
      }
    }
    throw new Error("Login failed.");
  }

  const payload = decodeAppAuthLoginResult(raw);
  writeStoredAppAuthSessionToken(payload.sessionToken);
  return payload;
}

export async function logoutAppAuth(): Promise<void> {
  try {
    const headers = authHeaders();
    await fetch(authUrl("/api/auth/logout"), {
      method: "POST",
      ...(headers ? { headers } : {}),
    });
  } finally {
    clearStoredAppAuthSessionToken();
  }
}
