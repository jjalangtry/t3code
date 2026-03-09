/**
 * CursorAdapter - Cursor implementation of the generic provider adapter contract.
 *
 * This service owns Cursor runtime/session semantics and emits canonical
 * provider runtime events. It does not perform cross-provider routing or
 * shared fan-out.
 *
 * @module CursorAdapter
 */
import { ServiceMap } from "effect";

import type { ProviderAdapterError } from "../Errors.ts";
import type { ProviderAdapterShape } from "./ProviderAdapter.ts";

export interface CursorAdapterShape extends ProviderAdapterShape<ProviderAdapterError> {
  readonly provider: "cursor";
}

export class CursorAdapter extends ServiceMap.Service<CursorAdapter, CursorAdapterShape>()(
  "t3/provider/Services/CursorAdapter",
) {}
