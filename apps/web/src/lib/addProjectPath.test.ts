import { assert, describe, it } from "vitest";

import {
  basenameOfProjectPath,
  deriveAddProjectSearchInput,
  dirnameOfProjectPath,
  normalizeAddProjectPathInput,
  resolveProjectSearchPath,
} from "./addProjectPath";

describe("addProjectPath", () => {
  it("normalizes path separators and trims whitespace", () => {
    assert.equal(normalizeAddProjectPathInput("  /mnt/c/Users  "), "/mnt/c/Users");
    assert.equal(normalizeAddProjectPathInput("C:\\Users\\jakob"), "C:/Users/jakob");
  });

  it("derives search input for partial absolute paths", () => {
    assert.deepEqual(deriveAddProjectSearchInput("/home/jjalangtry/re"), {
      cwd: "/home/jjalangtry",
      query: "re",
      normalizedInput: "/home/jjalangtry/re",
    });
  });

  it("treats trailing slashes as an explicit directory", () => {
    assert.deepEqual(deriveAddProjectSearchInput("/home/jjalangtry/"), {
      cwd: "/home/jjalangtry",
      query: "",
      normalizedInput: "/home/jjalangtry/",
    });
  });

  it("uses root search for single-segment inputs", () => {
    assert.deepEqual(deriveAddProjectSearchInput("repo"), {
      cwd: "/",
      query: "repo",
      normalizedInput: "repo",
    });
  });

  it("rebuilds absolute paths from search results", () => {
    assert.equal(resolveProjectSearchPath("/", "home/jjalangtry"), "/home/jjalangtry");
    assert.equal(
      resolveProjectSearchPath("/home/jjalangtry", "repos/t3code"),
      "/home/jjalangtry/repos/t3code",
    );
  });

  it("extracts readable path labels", () => {
    assert.equal(basenameOfProjectPath("/home/jjalangtry/repos"), "repos");
    assert.equal(dirnameOfProjectPath("/home/jjalangtry/repos"), "/home/jjalangtry");
    assert.equal(basenameOfProjectPath("/"), "/");
    assert.equal(dirnameOfProjectPath("/repo"), "/");
  });
});
