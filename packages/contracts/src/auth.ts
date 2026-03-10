import { Schema } from "effect";

import { TrimmedNonEmptyString } from "./baseSchemas";

export const AppAuthSession = Schema.Struct({
  authRequired: Schema.Boolean,
  authenticated: Schema.Boolean,
  username: Schema.NullOr(TrimmedNonEmptyString),
});
export type AppAuthSession = typeof AppAuthSession.Type;

export const AppAuthLoginInput = Schema.Struct({
  username: TrimmedNonEmptyString,
  password: Schema.String.check(Schema.isNonEmpty()),
});
export type AppAuthLoginInput = typeof AppAuthLoginInput.Type;

export const AppAuthLoginResult = Schema.Struct({
  session: AppAuthSession,
  sessionToken: TrimmedNonEmptyString,
});
export type AppAuthLoginResult = typeof AppAuthLoginResult.Type;

export const AppAuthErrorResponse = Schema.Struct({
  message: TrimmedNonEmptyString,
});
export type AppAuthErrorResponse = typeof AppAuthErrorResponse.Type;
