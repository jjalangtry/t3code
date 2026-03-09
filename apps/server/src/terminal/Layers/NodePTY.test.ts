import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import { Effect, FileSystem, Path } from "effect";
import { describe, expect, test } from "vitest";

import { ensureNodePtySpawnHelperExecutable, resolveElectronUnpackedPath } from "./NodePTY";

it.layer(NodeServices.layer)("ensureNodePtySpawnHelperExecutable", (it) => {
  it.effect("adds executable bits when helper exists but is not executable", () =>
    Effect.gen(function* () {
      if (process.platform === "win32") return;

      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;

      const dir = yield* fs.makeTempDirectoryScoped({ prefix: "pty-helper-test-" });
      const helperPath = path.join(dir, "spawn-helper");
      yield* fs.writeFileString(helperPath, "#!/bin/sh\nexit 0\n");
      yield* fs.chmod(helperPath, 0o644);

      yield* ensureNodePtySpawnHelperExecutable(helperPath);

      const mode = (yield* fs.stat(helperPath)).mode & 0o777;
      assert.equal(mode & 0o111, 0o111);
    }),
  );

  it.effect("keeps executable helper as executable", () =>
    Effect.gen(function* () {
      if (process.platform === "win32") return;

      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;

      const dir = yield* fs.makeTempDirectoryScoped({ prefix: "pty-helper-test-" });
      const helperPath = path.join(dir, "spawn-helper");
      yield* fs.writeFileString(helperPath, "#!/bin/sh\nexit 0\n");
      yield* fs.chmod(helperPath, 0o755);

      yield* ensureNodePtySpawnHelperExecutable(helperPath);

      const mode = (yield* fs.stat(helperPath)).mode & 0o777;
      assert.equal(mode & 0o111, 0o111);
    }),
  );
});

describe("resolveElectronUnpackedPath", () => {
  test("rewrites packaged electron paths to app.asar.unpacked", () => {
    expect(
      resolveElectronUnpackedPath("/tmp/T3/resources/app.asar/node_modules/node-pty/package.json"),
    ).toBe("/tmp/T3/resources/app.asar.unpacked/node_modules/node-pty/package.json");
  });

  test("leaves unpacked and development paths unchanged", () => {
    expect(
      resolveElectronUnpackedPath(
        "/tmp/T3/resources/app.asar.unpacked/node_modules/node-pty/package.json",
      ),
    ).toBe("/tmp/T3/resources/app.asar.unpacked/node_modules/node-pty/package.json");
    expect(
      resolveElectronUnpackedPath(
        "/home/jjalangtry/repos/t3code/node_modules/node-pty/package.json",
      ),
    ).toBe("/home/jjalangtry/repos/t3code/node_modules/node-pty/package.json");
  });
});
