/// <reference types="vite/client" />

import type { NativeApi, DesktopBridge } from "@t3tools/contracts";

declare global {
  interface Window {
    nativeApi?: NativeApi;
    desktopBridge?: DesktopBridge;
    __T3CODE_WS_TOKEN__?: string;
    __T3CODE_WS_URL__?: string;
  }
}
