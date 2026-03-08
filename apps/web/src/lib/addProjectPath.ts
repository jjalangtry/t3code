export interface AddProjectSearchInput {
  cwd: string | null;
  query: string;
  normalizedInput: string;
}

export function normalizeAddProjectPathInput(value: string): string {
  return value.trim().replaceAll("\\", "/");
}

export function deriveAddProjectSearchInput(value: string): AddProjectSearchInput {
  const normalizedInput = normalizeAddProjectPathInput(value);
  if (normalizedInput.length === 0) {
    return {
      cwd: null,
      query: "",
      normalizedInput,
    };
  }

  if (normalizedInput === "/") {
    return {
      cwd: "/",
      query: "",
      normalizedInput,
    };
  }

  if (normalizedInput.endsWith("/")) {
    return {
      cwd: normalizedInput.slice(0, -1) || "/",
      query: "",
      normalizedInput,
    };
  }

  const lastSlashIndex = normalizedInput.lastIndexOf("/");
  if (lastSlashIndex === -1) {
    return {
      cwd: "/",
      query: normalizedInput,
      normalizedInput,
    };
  }

  return {
    cwd: lastSlashIndex === 0 ? "/" : normalizedInput.slice(0, lastSlashIndex),
    query: normalizedInput.slice(lastSlashIndex + 1),
    normalizedInput,
  };
}

export function resolveProjectSearchPath(cwd: string, relativePath: string): string {
  if (cwd === "/") {
    return `/${relativePath}`;
  }
  return `${cwd.replace(/\/+$/, "")}/${relativePath}`;
}

export function basenameOfProjectPath(path: string): string {
  if (path === "/") return "/";
  const normalizedPath = path.replace(/\/+$/, "");
  const lastSlashIndex = normalizedPath.lastIndexOf("/");
  return lastSlashIndex === -1 ? normalizedPath : normalizedPath.slice(lastSlashIndex + 1);
}

export function dirnameOfProjectPath(path: string): string {
  if (path === "/") return "/";
  const normalizedPath = path.replace(/\/+$/, "");
  const lastSlashIndex = normalizedPath.lastIndexOf("/");
  if (lastSlashIndex <= 0) {
    return "/";
  }
  return normalizedPath.slice(0, lastSlashIndex);
}
