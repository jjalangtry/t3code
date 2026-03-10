import {
  ArrowLeftIcon,
  ChevronRightIcon,
  FolderIcon,
  GitPullRequestIcon,
  MoonIcon,
  PanelBottomIcon,
  PanelRightIcon,
  PlusIcon,
  RocketIcon,
  SettingsIcon,
  SquarePenIcon,
  SunIcon,
  TerminalIcon,
  TriangleAlertIcon,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  DndContext,
  type DragCancelEvent,
  type CollisionDetection,
  PointerSensor,
  type DragStartEvent,
  closestCorners,
  pointerWithin,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { SortableContext, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { restrictToParentElement, restrictToVerticalAxis } from "@dnd-kit/modifiers";
import { CSS } from "@dnd-kit/utilities";
import {
  DEFAULT_RUNTIME_MODE,
  DEFAULT_MODEL_BY_PROVIDER,
  type DesktopUpdateState,
  type ProjectEntry,
  ProjectId,
  ThreadId,
  type GitStatusResult,
  type ResolvedKeybindingsConfig,
} from "@t3tools/contracts";
import { useMutation, useQueries, useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocation, useNavigate, useParams } from "@tanstack/react-router";
import { useAppSettings } from "../appSettings";
import { isElectron } from "../env";
import { APP_STAGE_LABEL } from "../branding";
import { projectSearchEntriesQueryOptions } from "../lib/projectReactQuery";
import { cn, newCommandId, newProjectId, newThreadId } from "../lib/utils";
import {
  basenameOfProjectPath,
  deriveAddProjectSearchInput,
  dirnameOfProjectPath,
  normalizeAddProjectPathInput,
  resolveProjectSearchPath,
} from "../lib/addProjectPath";
import { useStore } from "../store";
import { isChatNewLocalShortcut, isChatNewShortcut, shortcutLabelForCommand } from "../keybindings";
import { derivePendingApprovals, derivePendingUserInputs } from "../session-logic";
import { gitRemoveWorktreeMutationOptions, gitStatusQueryOptions } from "../lib/gitReactQuery";
import { serverConfigQueryOptions } from "../lib/serverReactQuery";
import { readNativeApi } from "../nativeApi";
import { type DraftThreadEnvMode, useComposerDraftStore } from "../composerDraftStore";
import { selectThreadTerminalState, useTerminalStateStore } from "../terminalStateStore";
import { useTheme } from "../hooks/useTheme";
import { toastManager } from "./ui/toast";
import {
  getArm64IntelBuildWarningDescription,
  getDesktopUpdateActionError,
  getDesktopUpdateButtonTooltip,
  isDesktopUpdateButtonDisabled,
  resolveDesktopUpdateButtonAction,
  shouldShowArm64IntelBuildWarning,
  shouldHighlightDesktopUpdateError,
  shouldShowDesktopUpdateButton,
  shouldToastDesktopUpdateActionResult,
} from "./desktopUpdate.logic";
import { Alert, AlertAction, AlertDescription, AlertTitle } from "./ui/alert";
import { Button } from "./ui/button";
import { Collapsible, CollapsibleContent } from "./ui/collapsible";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";
import {
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarHeader,
  SidebarMenuAction,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarSeparator,
  SidebarTrigger,
} from "./ui/sidebar";
import { formatWorktreePathForDisplay, getOrphanedWorktreePathForThread } from "../worktreeCleanup";
import { isNonEmpty as isNonEmptyString } from "effect/String";
import { resolveThreadStatusPill } from "./Sidebar.logic";

const EMPTY_KEYBINDINGS: ResolvedKeybindingsConfig = [];
const EMPTY_PROJECT_ENTRIES: readonly ProjectEntry[] = [];
const THREAD_PREVIEW_LIMIT = 6;
const ADD_PROJECT_SUGGESTION_LIMIT = 10;

async function copyTextToClipboard(text: string): Promise<void> {
  if (typeof navigator === "undefined" || navigator.clipboard?.writeText === undefined) {
    throw new Error("Clipboard API unavailable.");
  }
  await navigator.clipboard.writeText(text);
}

function formatRelativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(diff / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

interface TerminalStatusIndicator {
  label: "Terminal process running";
  colorClass: string;
  pulse: boolean;
}

interface PrStatusIndicator {
  label: "PR open" | "PR closed" | "PR merged";
  colorClass: string;
  tooltip: string;
  url: string;
}

interface AddProjectSuggestion {
  fullPath: string;
  label: string;
  breadcrumb: string;
}

type ThreadPr = GitStatusResult["pr"];

function terminalStatusFromRunningIds(
  runningTerminalIds: string[],
): TerminalStatusIndicator | null {
  if (runningTerminalIds.length === 0) {
    return null;
  }
  return {
    label: "Terminal process running",
    colorClass: "text-teal-600 dark:text-teal-300/90",
    pulse: true,
  };
}

function prStatusIndicator(pr: ThreadPr): PrStatusIndicator | null {
  if (!pr) return null;

  if (pr.state === "open") {
    return {
      label: "PR open",
      colorClass: "text-emerald-600 dark:text-emerald-300/90",
      tooltip: `#${pr.number} PR open: ${pr.title}`,
      url: pr.url,
    };
  }
  if (pr.state === "closed") {
    return {
      label: "PR closed",
      colorClass: "text-zinc-500 dark:text-zinc-400/80",
      tooltip: `#${pr.number} PR closed: ${pr.title}`,
      url: pr.url,
    };
  }
  if (pr.state === "merged") {
    return {
      label: "PR merged",
      colorClass: "text-violet-600 dark:text-violet-300/90",
      tooltip: `#${pr.number} PR merged: ${pr.title}`,
      url: pr.url,
    };
  }
  return null;
}

function JjalangtryBrandMark() {
  return (
    <img
      alt="jjalangtry"
      className="size-7 shrink-0 rounded-[0.95rem] border border-border/60 object-cover shadow-sm"
      height={28}
      src="/jakob-icon.png"
      width={28}
    />
  );
}

/**
 * Derives the server's HTTP origin (scheme + host + port) from the same
 * sources WsTransport uses, converting ws(s) to http(s).
 */
function getServerHttpOrigin(): string {
  const bridgeUrl = window.desktopBridge?.getWsUrl();
  const envUrl = import.meta.env.VITE_WS_URL as string | undefined;
  const wsUrl =
    bridgeUrl && bridgeUrl.length > 0
      ? bridgeUrl
      : envUrl && envUrl.length > 0
        ? envUrl
        : `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.hostname}:${window.location.port}`;
  // Parse to extract just the origin, dropping path/query (e.g. ?token=…)
  const httpUrl = wsUrl.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
  try {
    return new URL(httpUrl).origin;
  } catch {
    return httpUrl;
  }
}

const serverHttpOrigin = getServerHttpOrigin();

function ProjectFavicon({ cwd }: { cwd: string }) {
  const [status, setStatus] = useState<"loading" | "loaded" | "error">("loading");

  const src = `${serverHttpOrigin}/api/project-favicon?cwd=${encodeURIComponent(cwd)}`;

  if (status === "error") {
    return <FolderIcon className="size-3.5 shrink-0 text-muted-foreground/50" />;
  }

  return (
    <img
      src={src}
      alt=""
      className={`size-3.5 shrink-0 rounded-sm object-contain ${status === "loading" ? "hidden" : ""}`}
      onLoad={() => setStatus("loaded")}
      onError={() => setStatus("error")}
    />
  );
}

type SortableProjectHandleProps = Pick<ReturnType<typeof useSortable>, "attributes" | "listeners">;

function SortableProjectItem({
  projectId,
  children,
}: {
  projectId: ProjectId;
  children: (handleProps: SortableProjectHandleProps) => React.ReactNode;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging, isOver } =
    useSortable({ id: projectId });
  return (
    <li
      ref={setNodeRef}
      style={{
        transform: CSS.Translate.toString(transform),
        transition,
      }}
      className={`group/menu-item relative rounded-md ${
        isDragging ? "z-20 opacity-80" : ""
      } ${isOver && !isDragging ? "ring-1 ring-primary/40" : ""}`}
      data-sidebar="menu-item"
      data-slot="sidebar-menu-item"
    >
      {children({ attributes, listeners })}
    </li>
  );
}

export default function Sidebar() {
  const projects = useStore((store) => store.projects);
  const threads = useStore((store) => store.threads);
  const markThreadUnread = useStore((store) => store.markThreadUnread);
  const toggleProject = useStore((store) => store.toggleProject);
  const reorderProjects = useStore((store) => store.reorderProjects);
  const clearComposerDraftForThread = useComposerDraftStore((store) => store.clearThreadDraft);
  const getDraftThreadByProjectId = useComposerDraftStore(
    (store) => store.getDraftThreadByProjectId,
  );
  const getDraftThread = useComposerDraftStore((store) => store.getDraftThread);
  const terminalStateByThreadId = useTerminalStateStore((state) => state.terminalStateByThreadId);
  const clearTerminalState = useTerminalStateStore((state) => state.clearTerminalState);
  const terminalPosition = useTerminalStateStore((state) => state.terminalPosition);
  const setTerminalPosition = useTerminalStateStore((state) => state.setTerminalPosition);
  const setProjectDraftThreadId = useComposerDraftStore((store) => store.setProjectDraftThreadId);
  const setDraftThreadContext = useComposerDraftStore((store) => store.setDraftThreadContext);
  const clearProjectDraftThreadId = useComposerDraftStore(
    (store) => store.clearProjectDraftThreadId,
  );
  const clearProjectDraftThreadById = useComposerDraftStore(
    (store) => store.clearProjectDraftThreadById,
  );
  const navigate = useNavigate();
  const isOnSettings = useLocation({ select: (loc) => loc.pathname === "/settings" });
  const { settings: appSettings } = useAppSettings();
  const { resolvedTheme, setTheme } = useTheme();
  const routeThreadId = useParams({
    strict: false,
    select: (params) => (params.threadId ? ThreadId.makeUnsafe(params.threadId) : null),
  });
  const { data: keybindings = EMPTY_KEYBINDINGS } = useQuery({
    ...serverConfigQueryOptions(),
    select: (config) => config.keybindings,
  });
  const queryClient = useQueryClient();
  const removeWorktreeMutation = useMutation(gitRemoveWorktreeMutationOptions({ queryClient }));
  const [addingProject, setAddingProject] = useState(false);
  const [newCwd, setNewCwd] = useState("");
  const [isPickingFolder, setIsPickingFolder] = useState(false);
  const [isAddingProject, setIsAddingProject] = useState(false);
  const [highlightedAddProjectSuggestionIndex, setHighlightedAddProjectSuggestionIndex] =
    useState(0);
  const [addProjectError, setAddProjectError] = useState<string | null>(null);
  const addProjectInputRef = useRef<HTMLInputElement | null>(null);
  const [renamingThreadId, setRenamingThreadId] = useState<ThreadId | null>(null);
  const [renamingTitle, setRenamingTitle] = useState("");
  const [expandedThreadListsByProject, setExpandedThreadListsByProject] = useState<
    ReadonlySet<ProjectId>
  >(() => new Set());
  const renamingCommittedRef = useRef(false);
  const renamingInputRef = useRef<HTMLInputElement | null>(null);
  const dragInProgressRef = useRef(false);
  const suppressProjectClickAfterDragRef = useRef(false);
  const [desktopUpdateState, setDesktopUpdateState] = useState<DesktopUpdateState | null>(null);
  const addProjectSearchInput = useMemo(() => deriveAddProjectSearchInput(newCwd), [newCwd]);
  const addProjectSearchEntriesQuery = useQuery(
    projectSearchEntriesQueryOptions({
      cwd: addProjectSearchInput.cwd,
      query: addProjectSearchInput.query,
      enabled: addingProject,
      limit: 20,
      staleTime: 10_000,
    }),
  );
  const addProjectSuggestions = useMemo<ReadonlyArray<AddProjectSuggestion>>(() => {
    const seenPaths = new Set<string>();
    const entries = addProjectSearchEntriesQuery.data?.entries ?? EMPTY_PROJECT_ENTRIES;

    return entries
      .filter((entry) => entry.kind === "directory")
      .map((entry) => resolveProjectSearchPath(addProjectSearchInput.cwd ?? "/", entry.path))
      .filter((fullPath) => {
        if (seenPaths.has(fullPath)) return false;
        seenPaths.add(fullPath);
        return true;
      })
      .map((fullPath) => {
        const label = basenameOfProjectPath(fullPath);
        const breadcrumb = dirnameOfProjectPath(fullPath);
        return {
          fullPath,
          label,
          breadcrumb,
        };
      })
      .slice(0, ADD_PROJECT_SUGGESTION_LIMIT);
  }, [addProjectSearchEntriesQuery.data?.entries, addProjectSearchInput.cwd]);
  const highlightedAddProjectSuggestion =
    addProjectSuggestions[highlightedAddProjectSuggestionIndex] ?? null;
  const shouldBrowseForProjectImmediately = isElectron;
  const shouldShowProjectPathEntry = addingProject && !shouldBrowseForProjectImmediately;
  const pendingApprovalByThreadId = useMemo(() => {
    const map = new Map<ThreadId, boolean>();
    for (const thread of threads) {
      map.set(thread.id, derivePendingApprovals(thread.activities).length > 0);
    }
    return map;
  }, [threads]);
  const pendingUserInputByThreadId = useMemo(() => {
    const map = new Map<ThreadId, boolean>();
    for (const thread of threads) {
      map.set(thread.id, derivePendingUserInputs(thread.activities).length > 0);
    }
    return map;
  }, [threads]);
  const projectCwdById = useMemo(
    () => new Map(projects.map((project) => [project.id, project.cwd] as const)),
    [projects],
  );
  const activeTerminalState = useMemo(
    () => (routeThreadId ? selectThreadTerminalState(terminalStateByThreadId, routeThreadId) : null),
    [routeThreadId, terminalStateByThreadId],
  );
  const threadGitTargets = useMemo(
    () =>
      threads.map((thread) => ({
        threadId: thread.id,
        branch: thread.branch,
        cwd: thread.worktreePath ?? projectCwdById.get(thread.projectId) ?? null,
      })),
    [projectCwdById, threads],
  );
  const threadGitStatusCwds = useMemo(
    () => [
      ...new Set(
        threadGitTargets
          .filter((target) => target.branch !== null)
          .map((target) => target.cwd)
          .filter((cwd): cwd is string => cwd !== null),
      ),
    ],
    [threadGitTargets],
  );
  const threadGitStatusQueries = useQueries({
    queries: threadGitStatusCwds.map((cwd) => ({
      ...gitStatusQueryOptions(cwd),
      staleTime: 30_000,
      refetchInterval: 60_000,
    })),
  });
  const prByThreadId = useMemo(() => {
    const statusByCwd = new Map<string, GitStatusResult>();
    for (let index = 0; index < threadGitStatusCwds.length; index += 1) {
      const cwd = threadGitStatusCwds[index];
      if (!cwd) continue;
      const status = threadGitStatusQueries[index]?.data;
      if (status) {
        statusByCwd.set(cwd, status);
      }
    }

    const map = new Map<ThreadId, ThreadPr>();
    for (const target of threadGitTargets) {
      const status = target.cwd ? statusByCwd.get(target.cwd) : undefined;
      const branchMatches =
        target.branch !== null && status?.branch !== null && status?.branch === target.branch;
      map.set(target.threadId, branchMatches ? (status?.pr ?? null) : null);
    }
    return map;
  }, [threadGitStatusCwds, threadGitStatusQueries, threadGitTargets]);

  const openPrLink = useCallback((event: React.MouseEvent<HTMLElement>, prUrl: string) => {
    event.preventDefault();
    event.stopPropagation();

    const api = readNativeApi();
    if (!api) {
      toastManager.add({
        type: "error",
        title: "Link opening is unavailable.",
      });
      return;
    }

    void api.shell.openExternal(prUrl).catch((error) => {
      toastManager.add({
        type: "error",
        title: "Unable to open PR link",
        description: error instanceof Error ? error.message : "An error occurred.",
      });
    });
  }, []);

  const closeAddProject = useCallback(() => {
    setAddingProject(false);
    setNewCwd("");
    setAddProjectError(null);
    setHighlightedAddProjectSuggestionIndex(0);
  }, []);

  const handleNewThread = useCallback(
    (
      projectId: ProjectId,
      options?: {
        branch?: string | null;
        worktreePath?: string | null;
        envMode?: DraftThreadEnvMode;
      },
    ): Promise<void> => {
      const hasBranchOption = options?.branch !== undefined;
      const hasWorktreePathOption = options?.worktreePath !== undefined;
      const hasEnvModeOption = options?.envMode !== undefined;
      const storedDraftThread = getDraftThreadByProjectId(projectId);
      if (storedDraftThread) {
        return (async () => {
          if (hasBranchOption || hasWorktreePathOption || hasEnvModeOption) {
            setDraftThreadContext(storedDraftThread.threadId, {
              ...(hasBranchOption ? { branch: options?.branch ?? null } : {}),
              ...(hasWorktreePathOption ? { worktreePath: options?.worktreePath ?? null } : {}),
              ...(hasEnvModeOption ? { envMode: options?.envMode } : {}),
            });
          }
          setProjectDraftThreadId(projectId, storedDraftThread.threadId);
          if (routeThreadId === storedDraftThread.threadId) {
            return;
          }
          await navigate({
            to: "/$threadId",
            params: { threadId: storedDraftThread.threadId },
          });
        })();
      }
      clearProjectDraftThreadId(projectId);

      const activeDraftThread = routeThreadId ? getDraftThread(routeThreadId) : null;
      if (activeDraftThread && routeThreadId && activeDraftThread.projectId === projectId) {
        if (hasBranchOption || hasWorktreePathOption || hasEnvModeOption) {
          setDraftThreadContext(routeThreadId, {
            ...(hasBranchOption ? { branch: options?.branch ?? null } : {}),
            ...(hasWorktreePathOption ? { worktreePath: options?.worktreePath ?? null } : {}),
            ...(hasEnvModeOption ? { envMode: options?.envMode } : {}),
          });
        }
        setProjectDraftThreadId(projectId, routeThreadId);
        return Promise.resolve();
      }
      const threadId = newThreadId();
      const createdAt = new Date().toISOString();
      return (async () => {
        setProjectDraftThreadId(projectId, threadId, {
          createdAt,
          branch: options?.branch ?? null,
          worktreePath: options?.worktreePath ?? null,
          envMode: options?.envMode ?? "local",
          runtimeMode: DEFAULT_RUNTIME_MODE,
        });

        await navigate({
          to: "/$threadId",
          params: { threadId },
        });
      })();
    },
    [
      clearProjectDraftThreadId,
      getDraftThreadByProjectId,
      navigate,
      getDraftThread,
      routeThreadId,
      setDraftThreadContext,
      setProjectDraftThreadId,
    ],
  );

  const focusMostRecentThreadForProject = useCallback(
    (projectId: ProjectId) => {
      const latestThread = threads
        .filter((thread) => thread.projectId === projectId)
        .toSorted((a, b) => {
          const byDate = new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
          if (byDate !== 0) return byDate;
          return b.id.localeCompare(a.id);
        })[0];
      if (!latestThread) return;

      void navigate({
        to: "/$threadId",
        params: { threadId: latestThread.id },
      });
    },
    [navigate, threads],
  );

  const addProjectFromPath = useCallback(
    async (rawCwd: string) => {
      const cwd = normalizeAddProjectPathInput(rawCwd);
      if (!cwd || isAddingProject) return;
      const api = readNativeApi();
      if (!api) return;

      setIsAddingProject(true);
      const finishAddingProject = () => {
        setIsAddingProject(false);
        closeAddProject();
      };

      const existing = projects.find((project) => project.cwd === cwd);
      if (existing) {
        focusMostRecentThreadForProject(existing.id);
        finishAddingProject();
        return;
      }

      const projectId = newProjectId();
      const createdAt = new Date().toISOString();
      const title = cwd.split(/[/\\]/).findLast(isNonEmptyString) ?? cwd;
      try {
        await api.orchestration.dispatchCommand({
          type: "project.create",
          commandId: newCommandId(),
          projectId,
          title,
          workspaceRoot: cwd,
          defaultModel: DEFAULT_MODEL_BY_PROVIDER.codex,
          createdAt,
        });
        await handleNewThread(projectId).catch(() => undefined);
      } catch (error) {
        const description =
          error instanceof Error ? error.message : "An error occurred while adding the project.";
        setIsAddingProject(false);
        if (shouldBrowseForProjectImmediately) {
          toastManager.add({
            type: "error",
            title: "Failed to add project",
            description,
          });
        } else {
          setAddProjectError(description);
        }
        return;
      }
      finishAddingProject();
    },
    [
      closeAddProject,
      focusMostRecentThreadForProject,
      handleNewThread,
      isAddingProject,
      projects,
      shouldBrowseForProjectImmediately,
    ],
  );

  const handleAddProject = () => {
    void addProjectFromPath(newCwd);
  };

  const canAddProject = newCwd.trim().length > 0 && !isAddingProject;

  const handlePickFolder = async () => {
    const api = readNativeApi();
    if (!api || isPickingFolder) return;
    setIsPickingFolder(true);
    let pickedPath: string | null = null;
    try {
      pickedPath = await api.dialogs.pickFolder();
    } catch {
      // Ignore picker failures and leave the current thread selection unchanged.
    }
    if (pickedPath) {
      await addProjectFromPath(pickedPath);
    } else if (!shouldBrowseForProjectImmediately) {
      addProjectInputRef.current?.focus();
    }
    setIsPickingFolder(false);
  };

  useEffect(() => {
    if (!addingProject) return;
    addProjectInputRef.current?.focus();
  }, [addingProject]);

  useEffect(() => {
    setHighlightedAddProjectSuggestionIndex(0);
  }, [newCwd]);

  useEffect(() => {
    if (highlightedAddProjectSuggestionIndex < addProjectSuggestions.length) return;
    setHighlightedAddProjectSuggestionIndex(Math.max(addProjectSuggestions.length - 1, 0));
  }, [addProjectSuggestions.length, highlightedAddProjectSuggestionIndex]);

  const handleStartAddProject = () => {
    setAddProjectError(null);
    if (shouldBrowseForProjectImmediately) {
      void handlePickFolder();
      return;
    }
    setAddingProject((prev) => !prev);
  };

  const cancelRename = useCallback(() => {
    setRenamingThreadId(null);
    renamingInputRef.current = null;
  }, []);

  const commitRename = useCallback(
    async (threadId: ThreadId, newTitle: string, originalTitle: string) => {
      const finishRename = () => {
        setRenamingThreadId((current) => {
          if (current !== threadId) return current;
          renamingInputRef.current = null;
          return null;
        });
      };

      const trimmed = newTitle.trim();
      if (trimmed.length === 0) {
        toastManager.add({ type: "warning", title: "Thread title cannot be empty" });
        finishRename();
        return;
      }
      if (trimmed === originalTitle) {
        finishRename();
        return;
      }
      const api = readNativeApi();
      if (!api) {
        finishRename();
        return;
      }
      try {
        await api.orchestration.dispatchCommand({
          type: "thread.meta.update",
          commandId: newCommandId(),
          threadId,
          title: trimmed,
        });
      } catch (error) {
        toastManager.add({
          type: "error",
          title: "Failed to rename thread",
          description: error instanceof Error ? error.message : "An error occurred.",
        });
      }
      finishRename();
    },
    [],
  );

  const handleThreadContextMenu = useCallback(
    async (threadId: ThreadId, position: { x: number; y: number }) => {
      const api = readNativeApi();
      if (!api) return;
      const clicked = await api.contextMenu.show(
        [
          { id: "rename", label: "Rename thread" },
          { id: "mark-unread", label: "Mark unread" },
          { id: "copy-thread-id", label: "Copy Thread ID" },
          { id: "delete", label: "Delete", destructive: true },
        ],
        position,
      );
      const thread = threads.find((t) => t.id === threadId);
      if (!thread) return;

      if (clicked === "rename") {
        setRenamingThreadId(threadId);
        setRenamingTitle(thread.title);
        renamingCommittedRef.current = false;
        return;
      }

      if (clicked === "mark-unread") {
        markThreadUnread(threadId);
        return;
      }
      if (clicked === "copy-thread-id") {
        try {
          await copyTextToClipboard(threadId);
          toastManager.add({
            type: "success",
            title: "Thread ID copied",
            description: threadId,
          });
        } catch (error) {
          toastManager.add({
            type: "error",
            title: "Failed to copy thread ID",
            description: error instanceof Error ? error.message : "An error occurred.",
          });
        }
        return;
      }
      if (clicked !== "delete") return;
      if (appSettings.confirmThreadDelete) {
        const confirmed = await api.dialogs.confirm(
          [
            `Delete thread "${thread.title}"?`,
            "This permanently clears conversation history for this thread.",
          ].join("\n"),
        );
        if (!confirmed) {
          return;
        }
      }
      const threadProject = projects.find((project) => project.id === thread.projectId);
      const orphanedWorktreePath = getOrphanedWorktreePathForThread(threads, threadId);
      const displayWorktreePath = orphanedWorktreePath
        ? formatWorktreePathForDisplay(orphanedWorktreePath)
        : null;
      const canDeleteWorktree = orphanedWorktreePath !== null && threadProject !== undefined;
      const shouldDeleteWorktree =
        canDeleteWorktree &&
        (await api.dialogs.confirm(
          [
            "This thread is the only one linked to this worktree:",
            displayWorktreePath ?? orphanedWorktreePath,
            "",
            "Delete the worktree too?",
          ].join("\n"),
        ));

      if (thread.session && thread.session.status !== "closed") {
        await api.orchestration
          .dispatchCommand({
            type: "thread.session.stop",
            commandId: newCommandId(),
            threadId,
            createdAt: new Date().toISOString(),
          })
          .catch(() => undefined);
      }

      try {
        await api.terminal.close({
          threadId,
          deleteHistory: true,
        });
      } catch {
        // Terminal may already be closed
      }

      const shouldNavigateToFallback = routeThreadId === threadId;
      const fallbackThreadId = threads.find((entry) => entry.id !== threadId)?.id ?? null;
      await api.orchestration.dispatchCommand({
        type: "thread.delete",
        commandId: newCommandId(),
        threadId,
      });
      clearComposerDraftForThread(threadId);
      clearProjectDraftThreadById(thread.projectId, thread.id);
      clearTerminalState(threadId);
      if (shouldNavigateToFallback) {
        if (fallbackThreadId) {
          void navigate({
            to: "/$threadId",
            params: { threadId: fallbackThreadId },
            replace: true,
          });
        } else {
          void navigate({ to: "/", replace: true });
        }
      }

      if (!shouldDeleteWorktree || !orphanedWorktreePath || !threadProject) {
        return;
      }

      try {
        await removeWorktreeMutation.mutateAsync({
          cwd: threadProject.cwd,
          path: orphanedWorktreePath,
          force: true,
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error removing worktree.";
        console.error("Failed to remove orphaned worktree after thread deletion", {
          threadId,
          projectCwd: threadProject.cwd,
          worktreePath: orphanedWorktreePath,
          error,
        });
        toastManager.add({
          type: "error",
          title: "Thread deleted, but worktree removal failed",
          description: `Could not remove ${displayWorktreePath ?? orphanedWorktreePath}. ${message}`,
        });
      }
    },
    [
      appSettings.confirmThreadDelete,
      clearComposerDraftForThread,
      clearProjectDraftThreadById,
      clearTerminalState,
      markThreadUnread,
      navigate,
      projects,
      removeWorktreeMutation,
      routeThreadId,
      threads,
    ],
  );

  const handleProjectContextMenu = useCallback(
    async (projectId: ProjectId, position: { x: number; y: number }) => {
      const api = readNativeApi();
      if (!api) return;
      const clicked = await api.contextMenu.show(
        [{ id: "delete", label: "Delete", destructive: true }],
        position,
      );
      if (clicked !== "delete") return;

      const project = projects.find((entry) => entry.id === projectId);
      if (!project) return;

      const projectThreads = threads.filter((thread) => thread.projectId === projectId);
      if (projectThreads.length > 0) {
        toastManager.add({
          type: "warning",
          title: "Project is not empty",
          description: "Delete all threads in this project before deleting it.",
        });
        return;
      }

      const confirmed = await api.dialogs.confirm(
        [`Delete project "${project.name}"?`, "This action cannot be undone."].join("\n"),
      );
      if (!confirmed) return;

      try {
        const projectDraftThread = getDraftThreadByProjectId(projectId);
        if (projectDraftThread) {
          clearComposerDraftForThread(projectDraftThread.threadId);
        }
        clearProjectDraftThreadId(projectId);
        await api.orchestration.dispatchCommand({
          type: "project.delete",
          commandId: newCommandId(),
          projectId,
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error deleting project.";
        console.error("Failed to remove project", { projectId, error });
        toastManager.add({
          type: "error",
          title: `Failed to delete "${project.name}"`,
          description: message,
        });
      }
    },
    [
      clearComposerDraftForThread,
      clearProjectDraftThreadId,
      getDraftThreadByProjectId,
      projects,
      threads,
    ],
  );

  const projectDnDSensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: { distance: 6 },
    }),
  );
  const projectCollisionDetection = useCallback<CollisionDetection>((args) => {
    const pointerCollisions = pointerWithin(args);
    if (pointerCollisions.length > 0) {
      return pointerCollisions;
    }

    return closestCorners(args);
  }, []);

  const handleProjectDragEnd = useCallback(
    (event: DragEndEvent) => {
      dragInProgressRef.current = false;
      const { active, over } = event;
      if (!over || active.id === over.id) return;
      const activeProject = projects.find((project) => project.id === active.id);
      const overProject = projects.find((project) => project.id === over.id);
      if (!activeProject || !overProject) return;
      reorderProjects(activeProject.id, overProject.id);
    },
    [projects, reorderProjects],
  );

  const handleProjectDragStart = useCallback((_event: DragStartEvent) => {
    dragInProgressRef.current = true;
    suppressProjectClickAfterDragRef.current = true;
  }, []);

  const handleProjectDragCancel = useCallback((_event: DragCancelEvent) => {
    dragInProgressRef.current = false;
  }, []);

  const handleProjectTitlePointerDownCapture = useCallback(() => {
    suppressProjectClickAfterDragRef.current = false;
  }, []);

  const handleProjectTitleClick = useCallback(
    (event: React.MouseEvent<HTMLButtonElement>, projectId: ProjectId) => {
      if (dragInProgressRef.current) {
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      if (suppressProjectClickAfterDragRef.current) {
        // Consume the synthetic click emitted after a drag release.
        suppressProjectClickAfterDragRef.current = false;
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      toggleProject(projectId);
    },
    [toggleProject],
  );

  const handleProjectTitleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLButtonElement>, projectId: ProjectId) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      if (dragInProgressRef.current) {
        return;
      }
      toggleProject(projectId);
    },
    [toggleProject],
  );

  useEffect(() => {
    const onWindowKeyDown = (event: KeyboardEvent) => {
      const activeThread = routeThreadId
        ? threads.find((thread) => thread.id === routeThreadId)
        : undefined;
      const activeDraftThread = routeThreadId ? getDraftThread(routeThreadId) : null;
      if (isChatNewLocalShortcut(event, keybindings)) {
        const projectId =
          activeThread?.projectId ?? activeDraftThread?.projectId ?? projects[0]?.id;
        if (!projectId) return;
        event.preventDefault();
        void handleNewThread(projectId);
        return;
      }

      if (!isChatNewShortcut(event, keybindings)) return;
      const projectId = activeThread?.projectId ?? activeDraftThread?.projectId ?? projects[0]?.id;
      if (!projectId) return;
      event.preventDefault();
      void handleNewThread(projectId, {
        branch: activeThread?.branch ?? activeDraftThread?.branch ?? null,
        worktreePath: activeThread?.worktreePath ?? activeDraftThread?.worktreePath ?? null,
        envMode: activeDraftThread?.envMode ?? (activeThread?.worktreePath ? "worktree" : "local"),
      });
    };

    window.addEventListener("keydown", onWindowKeyDown);
    return () => {
      window.removeEventListener("keydown", onWindowKeyDown);
    };
  }, [getDraftThread, handleNewThread, keybindings, projects, routeThreadId, threads]);

  useEffect(() => {
    if (!isElectron) return;
    const bridge = window.desktopBridge;
    if (
      !bridge ||
      typeof bridge.getUpdateState !== "function" ||
      typeof bridge.onUpdateState !== "function"
    ) {
      return;
    }

    let disposed = false;
    let receivedSubscriptionUpdate = false;
    const unsubscribe = bridge.onUpdateState((nextState) => {
      if (disposed) return;
      receivedSubscriptionUpdate = true;
      setDesktopUpdateState(nextState);
    });

    void bridge
      .getUpdateState()
      .then((nextState) => {
        if (disposed || receivedSubscriptionUpdate) return;
        setDesktopUpdateState(nextState);
      })
      .catch(() => undefined);

    return () => {
      disposed = true;
      unsubscribe();
    };
  }, []);

  const showDesktopUpdateButton = isElectron && shouldShowDesktopUpdateButton(desktopUpdateState);

  const desktopUpdateTooltip = desktopUpdateState
    ? getDesktopUpdateButtonTooltip(desktopUpdateState)
    : "Update available";

  const desktopUpdateButtonDisabled = isDesktopUpdateButtonDisabled(desktopUpdateState);
  const desktopUpdateButtonAction = desktopUpdateState
    ? resolveDesktopUpdateButtonAction(desktopUpdateState)
    : "none";
  const showArm64IntelBuildWarning =
    isElectron && shouldShowArm64IntelBuildWarning(desktopUpdateState);
  const arm64IntelBuildWarningDescription =
    desktopUpdateState && showArm64IntelBuildWarning
      ? getArm64IntelBuildWarningDescription(desktopUpdateState)
      : null;
  const desktopUpdateButtonInteractivityClasses = desktopUpdateButtonDisabled
    ? "cursor-not-allowed opacity-60"
    : "hover:bg-accent hover:text-foreground";
  const desktopUpdateButtonClasses =
    desktopUpdateState?.status === "downloaded"
      ? "text-emerald-500"
      : desktopUpdateState?.status === "downloading"
        ? "text-sky-400"
        : shouldHighlightDesktopUpdateError(desktopUpdateState)
          ? "text-rose-500 animate-pulse"
          : "text-amber-500 animate-pulse";
  const newThreadShortcutLabel = useMemo(
    () =>
      shortcutLabelForCommand(keybindings, "chat.newLocal") ??
      shortcutLabelForCommand(keybindings, "chat.new"),
    [keybindings],
  );

  const handleDesktopUpdateButtonClick = useCallback(() => {
    const bridge = window.desktopBridge;
    if (!bridge || !desktopUpdateState) return;
    if (desktopUpdateButtonDisabled || desktopUpdateButtonAction === "none") return;

    if (desktopUpdateButtonAction === "download") {
      void bridge
        .downloadUpdate()
        .then((result) => {
          if (result.completed) {
            toastManager.add({
              type: "success",
              title: "Update downloaded",
              description: "Restart the app from the update button to install it.",
            });
          }
          if (!shouldToastDesktopUpdateActionResult(result)) return;
          const actionError = getDesktopUpdateActionError(result);
          if (!actionError) return;
          toastManager.add({
            type: "error",
            title: "Could not download update",
            description: actionError,
          });
        })
        .catch((error) => {
          toastManager.add({
            type: "error",
            title: "Could not start update download",
            description: error instanceof Error ? error.message : "An unexpected error occurred.",
          });
        });
      return;
    }

    if (desktopUpdateButtonAction === "install") {
      void bridge
        .installUpdate()
        .then((result) => {
          if (!shouldToastDesktopUpdateActionResult(result)) return;
          const actionError = getDesktopUpdateActionError(result);
          if (!actionError) return;
          toastManager.add({
            type: "error",
            title: "Could not install update",
            description: actionError,
          });
        })
        .catch((error) => {
          toastManager.add({
            type: "error",
            title: "Could not install update",
            description: error instanceof Error ? error.message : "An unexpected error occurred.",
          });
        });
    }
  }, [desktopUpdateButtonAction, desktopUpdateButtonDisabled, desktopUpdateState]);

  const toggleTheme = useCallback(() => {
    setTheme(resolvedTheme === "dark" ? "light" : "dark");
  }, [resolvedTheme, setTheme]);

  const themeToggleTooltip =
    resolvedTheme === "dark" ? "Switch app to light mode" : "Switch app to dark mode";
  const terminalPositionTooltip =
    terminalPosition === "right"
      ? "Move terminal to bottom"
      : "Move terminal to right sidebar";

  const expandThreadListForProject = useCallback((projectId: ProjectId) => {
    setExpandedThreadListsByProject((current) => {
      if (current.has(projectId)) return current;
      const next = new Set(current);
      next.add(projectId);
      return next;
    });
  }, []);

  const collapseThreadListForProject = useCallback((projectId: ProjectId) => {
    setExpandedThreadListsByProject((current) => {
      if (!current.has(projectId)) return current;
      const next = new Set(current);
      next.delete(projectId);
      return next;
    });
  }, []);

  const wordmark = (
    <div className="flex items-center gap-2">
      <SidebarTrigger className="shrink-0 md:hidden" />
      <div className="mt-2 ml-1 flex min-w-0 flex-1 items-center gap-2">
        <JjalangtryBrandMark />
        <span className="truncate text-sm font-semibold tracking-tight text-foreground">
          jjalangtry
        </span>
        <span className="rounded-full bg-muted/50 px-1.5 py-0.5 text-[8px] font-medium uppercase tracking-[0.18em] text-muted-foreground/60">
          {APP_STAGE_LABEL}
        </span>
      </div>
    </div>
  );

  const headerActions = (
    <div className="ml-auto flex items-center gap-1">
      {activeTerminalState?.terminalOpen && (
        <Tooltip>
          <TooltipTrigger
            render={
              <button
                type="button"
                aria-label={terminalPositionTooltip}
                className="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                onClick={() => {
                  setTerminalPosition(terminalPosition === "right" ? "bottom" : "right");
                }}
              >
                {terminalPosition === "right" ? (
                  <PanelBottomIcon className="size-3.5" />
                ) : (
                  <PanelRightIcon className="size-3.5" />
                )}
              </button>
            }
          />
          <TooltipPopup side="bottom">{terminalPositionTooltip}</TooltipPopup>
        </Tooltip>
      )}
      <Tooltip>
        <TooltipTrigger
          render={
            <button
              type="button"
              aria-label={themeToggleTooltip}
              className="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              onClick={toggleTheme}
            >
              {resolvedTheme === "dark" ? (
                <SunIcon className="size-3.5" />
              ) : (
                <MoonIcon className="size-3.5" />
              )}
            </button>
          }
        />
        <TooltipPopup side="bottom">{themeToggleTooltip}</TooltipPopup>
      </Tooltip>
      {showDesktopUpdateButton && (
        <Tooltip>
          <TooltipTrigger
            render={
              <button
                type="button"
                aria-label={desktopUpdateTooltip}
                aria-disabled={desktopUpdateButtonDisabled || undefined}
                disabled={desktopUpdateButtonDisabled}
                className={`inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors ${desktopUpdateButtonInteractivityClasses} ${desktopUpdateButtonClasses}`}
                onClick={handleDesktopUpdateButtonClick}
              >
                <RocketIcon className="size-3.5" />
              </button>
            }
          />
          <TooltipPopup side="bottom">{desktopUpdateTooltip}</TooltipPopup>
        </Tooltip>
      )}
    </div>
  );

  return (
    <>
      {isElectron ? (
        <>
          <SidebarHeader className="drag-region h-[52px] flex-row items-center gap-2 px-4 py-0 pl-[90px]">
            {wordmark}
            {headerActions}
          </SidebarHeader>
        </>
      ) : (
        <SidebarHeader className="flex-row items-center gap-3 px-3 py-2 sm:gap-2.5 sm:px-4 sm:py-3">
          {wordmark}
          {headerActions}
        </SidebarHeader>
      )}

      <SidebarContent className="gap-0">
        {showArm64IntelBuildWarning && arm64IntelBuildWarningDescription ? (
          <SidebarGroup className="px-2 pt-2 pb-0">
            <Alert variant="warning" className="rounded-2xl border-warning/40 bg-warning/8">
              <TriangleAlertIcon />
              <AlertTitle>Intel build on Apple Silicon</AlertTitle>
              <AlertDescription>{arm64IntelBuildWarningDescription}</AlertDescription>
              {desktopUpdateButtonAction !== "none" ? (
                <AlertAction>
                  <Button
                    size="xs"
                    variant="outline"
                    disabled={desktopUpdateButtonDisabled}
                    onClick={handleDesktopUpdateButtonClick}
                  >
                    {desktopUpdateButtonAction === "download"
                      ? "Download ARM build"
                      : "Install ARM build"}
                  </Button>
                </AlertAction>
              ) : null}
            </Alert>
          </SidebarGroup>
        ) : null}
        <SidebarGroup className="px-2 py-2">
          <div className="mb-1 flex items-center justify-between px-2">
            <span className="text-[10px] font-medium uppercase tracking-wider text-muted-foreground/60">
              Projects
            </span>
            <Tooltip>
              <TooltipTrigger
                render={
                  <button
                    type="button"
                    aria-label="Add project"
                    aria-pressed={shouldShowProjectPathEntry}
                    className="inline-flex size-5 items-center justify-center rounded-md text-muted-foreground/60 transition-colors hover:bg-accent hover:text-foreground"
                    onClick={handleStartAddProject}
                  />
                }
              >
                <PlusIcon
                  className={`size-3.5 transition-transform duration-150 ${
                    shouldShowProjectPathEntry ? "rotate-45" : "rotate-0"
                  }`}
                />
              </TooltipTrigger>
              <TooltipPopup side="right">Add project</TooltipPopup>
            </Tooltip>
          </div>

          {shouldShowProjectPathEntry && (
            <div className="mb-2 px-1">
              {isElectron && (
                <button
                  type="button"
                  className="mb-1.5 flex w-full items-center justify-center gap-2 rounded-md border border-border bg-secondary py-1.5 text-xs text-foreground/80 transition-colors duration-150 hover:bg-accent hover:text-foreground disabled:cursor-not-allowed disabled:opacity-60"
                  onClick={() => void handlePickFolder()}
                  disabled={isPickingFolder || isAddingProject}
                >
                  <FolderIcon className="size-3.5" />
                  {isPickingFolder ? "Picking folder..." : "Browse for folder"}
                </button>
              )}
              <div className="flex gap-1.5">
                <input
                  ref={addProjectInputRef}
                  className={`min-w-0 flex-1 rounded-md border bg-secondary px-2 py-1 font-mono text-xs text-foreground placeholder:text-muted-foreground/40 focus:outline-none ${
                    addProjectError
                      ? "border-red-500/70 focus:border-red-500"
                      : "border-border focus:border-ring"
                  }`}
                  placeholder="/path/to/project"
                  value={newCwd}
                  onChange={(event) => {
                    setNewCwd(event.target.value);
                    setAddProjectError(null);
                    setHighlightedAddProjectSuggestionIndex(0);
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "ArrowDown") {
                      if (addProjectSuggestions.length === 0) return;
                      event.preventDefault();
                      setHighlightedAddProjectSuggestionIndex(
                        (index) => (index + 1) % addProjectSuggestions.length,
                      );
                      return;
                    }
                    if (event.key === "ArrowUp") {
                      if (addProjectSuggestions.length === 0) return;
                      event.preventDefault();
                      setHighlightedAddProjectSuggestionIndex(
                        (index) =>
                          (index - 1 + addProjectSuggestions.length) % addProjectSuggestions.length,
                      );
                      return;
                    }
                    if (event.key === "Tab") {
                      if (!highlightedAddProjectSuggestion) return;
                      event.preventDefault();
                      setNewCwd(highlightedAddProjectSuggestion.fullPath);
                      return;
                    }
                    if (event.key === "Enter") {
                      if (
                        highlightedAddProjectSuggestion &&
                        normalizeAddProjectPathInput(newCwd) !== highlightedAddProjectSuggestion.fullPath
                      ) {
                        event.preventDefault();
                        setNewCwd(highlightedAddProjectSuggestion.fullPath);
                        return;
                      }
                      handleAddProject();
                    }
                    if (event.key === "Escape") {
                      closeAddProject();
                    }
                  }}
                  autoFocus
                />
                <button
                  type="button"
                  className="shrink-0 rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground transition-colors duration-150 hover:bg-primary/90 disabled:opacity-60"
                  onClick={handleAddProject}
                  disabled={!canAddProject}
                >
                  {isAddingProject ? "Adding..." : "Add"}
                </button>
              </div>
              {addProjectError && (
                <p className="mt-1 px-0.5 text-[11px] leading-tight text-red-400">
                  {addProjectError}
                </p>
              )}
              {addProjectSuggestions.length > 0 && (
                <div className="mt-1.5 rounded-md border border-border bg-background/70 p-1">
                  <div className="px-2 pb-1 text-[10px] uppercase tracking-[0.14em] text-muted-foreground/50">
                    Searching in {addProjectSearchInput.cwd ?? "/"}
                  </div>
                  {addProjectSuggestions.map((suggestion, index) => {
                    const isHighlighted = index === highlightedAddProjectSuggestionIndex;
                    return (
                      <button
                        key={suggestion.fullPath}
                        type="button"
                        className={cn(
                          "flex w-full items-start gap-2 rounded px-2 py-1.5 text-left text-xs transition-colors duration-150",
                          isHighlighted
                            ? "bg-accent text-foreground"
                            : "text-muted-foreground hover:bg-accent/70 hover:text-foreground",
                        )}
                        onMouseDown={(event) => event.preventDefault()}
                        onClick={() => {
                          setNewCwd(suggestion.fullPath);
                          addProjectInputRef.current?.focus();
                        }}
                      >
                        <FolderIcon className="mt-0.5 size-3.5 shrink-0" />
                        <span className="min-w-0 flex-1">
                          <span className="block truncate font-mono text-foreground">
                            {suggestion.label}
                          </span>
                          <span className="block truncate font-mono text-[10px] text-muted-foreground/70">
                            {suggestion.breadcrumb}
                          </span>
                        </span>
                      </button>
                    );
                  })}
                  {addProjectSearchEntriesQuery.data?.truncated && (
                    <p className="px-2 pt-1 text-[10px] text-muted-foreground/60">
                      Narrow the path to show more matches.
                    </p>
                  )}
                </div>
              )}
              {newCwd.trim().length > 0 &&
                addProjectSearchInput.query.length > 0 &&
                addProjectSuggestions.length === 0 && (
                  <div className="mt-1.5 rounded-md border border-dashed border-border px-2 py-1.5 text-[10px] text-muted-foreground/60">
                    {addProjectSearchEntriesQuery.isFetching
                      ? "Searching directories..."
                      : "No matching directories."}
                  </div>
                )}
              <div className="mt-1.5 px-0.5">
                <button
                  type="button"
                  className="text-[11px] text-muted-foreground/50 transition-colors hover:text-muted-foreground"
                  onClick={closeAddProject}
                >
                  Cancel
                </button>
              </div>
            </div>
          )}

          <DndContext
            sensors={projectDnDSensors}
            collisionDetection={projectCollisionDetection}
            modifiers={[restrictToVerticalAxis, restrictToParentElement]}
            onDragStart={handleProjectDragStart}
            onDragEnd={handleProjectDragEnd}
            onDragCancel={handleProjectDragCancel}
          >
            <SidebarMenu>
              <SortableContext
                items={projects.map((project) => project.id)}
                strategy={verticalListSortingStrategy}
              >
                {projects.map((project) => {
                  const projectThreads = threads
                    .filter((thread) => thread.projectId === project.id)
                    .toSorted((a, b) => {
                      const byDate = new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
                      if (byDate !== 0) return byDate;
                      return b.id.localeCompare(a.id);
                    });
                  const isThreadListExpanded = expandedThreadListsByProject.has(project.id);
                  const hasHiddenThreads = projectThreads.length > THREAD_PREVIEW_LIMIT;
                  const visibleThreads =
                    hasHiddenThreads && !isThreadListExpanded
                      ? projectThreads.slice(0, THREAD_PREVIEW_LIMIT)
                      : projectThreads;

                  return (
                    <SortableProjectItem key={project.id} projectId={project.id}>
                      {(dragHandleProps) => (
                        <Collapsible
                          className="group/collapsible"
                          open={project.expanded}
                        >
                          <div className="group/project-header relative">
                            <SidebarMenuButton
                              size="sm"
                              className="gap-2 px-2 py-1.5 text-left cursor-grab active:cursor-grabbing hover:bg-accent group-hover/project-header:bg-accent group-hover/project-header:text-sidebar-accent-foreground"
                              {...dragHandleProps.attributes}
                              {...dragHandleProps.listeners}
                              onPointerDownCapture={handleProjectTitlePointerDownCapture}
                              onClick={(event) => handleProjectTitleClick(event, project.id)}
                              onKeyDown={(event) => handleProjectTitleKeyDown(event, project.id)}
                              onContextMenu={(event) => {
                                event.preventDefault();
                                void handleProjectContextMenu(project.id, {
                                  x: event.clientX,
                                  y: event.clientY,
                                });
                              }}
                            >
                              <ChevronRightIcon
                                className={`-ml-0.5 size-3.5 shrink-0 text-muted-foreground/70 transition-transform duration-150 ${
                                  project.expanded ? "rotate-90" : ""
                                }`}
                              />
                              <ProjectFavicon cwd={project.cwd} />
                              <span className="flex-1 truncate text-xs font-medium text-foreground/90">
                                {project.name}
                              </span>
                            </SidebarMenuButton>
                            <Tooltip>
                              <TooltipTrigger
                                render={
                                  <SidebarMenuAction
                                    render={
                                      <button
                                        type="button"
                                        aria-label={`Create new thread in ${project.name}`}
                                      />
                                    }
                                    showOnHover
                                    className="top-1 right-1 size-5 rounded-md p-0 text-muted-foreground/70 hover:bg-secondary hover:text-foreground"
                                    onClick={(event) => {
                                      event.preventDefault();
                                      event.stopPropagation();
                                      void handleNewThread(project.id);
                                    }}
                                  >
                                    <SquarePenIcon className="size-3.5" />
                                  </SidebarMenuAction>
                                }
                              />
                              <TooltipPopup side="top">
                                {newThreadShortcutLabel
                                  ? `New thread (${newThreadShortcutLabel})`
                                  : "New thread"}
                              </TooltipPopup>
                            </Tooltip>
                          </div>

                          <CollapsibleContent keepMounted>
                            <SidebarMenuSub className="mx-1 my-0 w-full translate-x-0 gap-0 px-1.5 py-0">
                                {visibleThreads.map((thread) => {
                                  const isActive = routeThreadId === thread.id;
                                  const threadStatus = resolveThreadStatusPill({
                                    thread,
                                    hasPendingApprovals: pendingApprovalByThreadId.get(thread.id) === true,
                                    hasPendingUserInput: pendingUserInputByThreadId.get(thread.id) === true,
                                  });
                                  const prStatus = prStatusIndicator(prByThreadId.get(thread.id) ?? null);
                                  const terminalStatus = terminalStatusFromRunningIds(
                                    selectThreadTerminalState(terminalStateByThreadId, thread.id)
                                      .runningTerminalIds,
                                  );

                                  return (
                                    <SidebarMenuSubItem key={thread.id} className="w-full">
                                      <SidebarMenuSubButton
                                        render={<div role="button" tabIndex={0} />}
                                        size="sm"
                                        isActive={isActive}
                                        className={`h-7 w-full translate-x-0 cursor-default justify-start px-2 text-left hover:bg-accent hover:text-foreground ${
                                          isActive
                                            ? "bg-accent/85 text-foreground font-medium ring-1 ring-border/70 dark:bg-accent/55 dark:ring-border/50"
                                            : "text-muted-foreground"
                                        }`}
                                        onClick={() => {
                                          void navigate({
                                            to: "/$threadId",
                                            params: { threadId: thread.id },
                                          });
                                        }}
                                        onKeyDown={(event) => {
                                          if (event.key !== "Enter" && event.key !== " ") return;
                                          event.preventDefault();
                                          void navigate({
                                            to: "/$threadId",
                                            params: { threadId: thread.id },
                                          });
                                        }}
                                        onContextMenu={(event) => {
                                          event.preventDefault();
                                          void handleThreadContextMenu(thread.id, {
                                            x: event.clientX,
                                            y: event.clientY,
                                          });
                                        }}
                                      >
                                        <div className="flex min-w-0 flex-1 items-center gap-1.5 text-left">
                                          {prStatus && (
                                            <Tooltip>
                                              <TooltipTrigger
                                                render={
                                                  <button
                                                    type="button"
                                                    aria-label={prStatus.tooltip}
                                                    className={`inline-flex items-center justify-center ${prStatus.colorClass} cursor-pointer rounded-sm outline-hidden focus-visible:ring-1 focus-visible:ring-ring`}
                                                    onClick={(event) => {
                                                      openPrLink(event, prStatus.url);
                                                    }}
                                                  >
                                                    <GitPullRequestIcon className="size-3" />
                                                  </button>
                                                }
                                              />
                                              <TooltipPopup side="top">{prStatus.tooltip}</TooltipPopup>
                                            </Tooltip>
                                          )}
                                          {threadStatus && (
                                            <span
                                              className={`inline-flex items-center gap-1 text-[10px] ${threadStatus.colorClass}`}
                                            >
                                              <span
                                                className={`h-1.5 w-1.5 rounded-full ${threadStatus.dotClass} ${
                                                  threadStatus.pulse ? "animate-pulse" : ""
                                                }`}
                                              />
                                              <span className="hidden md:inline">{threadStatus.label}</span>
                                            </span>
                                          )}
                                          {renamingThreadId === thread.id ? (
                                            <input
                                              ref={(el) => {
                                                if (el && renamingInputRef.current !== el) {
                                                  renamingInputRef.current = el;
                                                  el.focus();
                                                  el.select();
                                                }
                                              }}
                                              className="min-w-0 flex-1 truncate text-xs bg-transparent outline-none border border-ring rounded px-0.5"
                                              value={renamingTitle}
                                              onChange={(e) => setRenamingTitle(e.target.value)}
                                              onKeyDown={(e) => {
                                                e.stopPropagation();
                                                if (e.key === "Enter") {
                                                  e.preventDefault();
                                                  renamingCommittedRef.current = true;
                                                  void commitRename(thread.id, renamingTitle, thread.title);
                                                } else if (e.key === "Escape") {
                                                  e.preventDefault();
                                                  renamingCommittedRef.current = true;
                                                  cancelRename();
                                                }
                                              }}
                                              onBlur={() => {
                                                if (!renamingCommittedRef.current) {
                                                  void commitRename(thread.id, renamingTitle, thread.title);
                                                }
                                              }}
                                              onClick={(e) => e.stopPropagation()}
                                            />
                                          ) : (
                                            <span className="min-w-0 flex-1 truncate text-xs">
                                              {thread.title}
                                            </span>
                                          )}
                                        </div>
                                        <div className="ml-auto flex shrink-0 items-center gap-1.5">
                                          {terminalStatus && (
                                            <span
                                              role="img"
                                              aria-label={terminalStatus.label}
                                              title={terminalStatus.label}
                                              className={`inline-flex items-center justify-center ${terminalStatus.colorClass}`}
                                            >
                                              <TerminalIcon
                                                className={`size-3 ${terminalStatus.pulse ? "animate-pulse" : ""}`}
                                              />
                                            </span>
                                          )}
                                          <span
                                            className={`text-[10px] ${
                                              isActive ? "text-foreground/65" : "text-muted-foreground/40"
                                            }`}
                                          >
                                            {formatRelativeTime(thread.createdAt)}
                                          </span>
                                        </div>
                                      </SidebarMenuSubButton>
                                    </SidebarMenuSubItem>
                                  );
                                })}

                                {hasHiddenThreads && !isThreadListExpanded && (
                                  <SidebarMenuSubItem className="w-full">
                                    <SidebarMenuSubButton
                                      render={<button type="button" />}
                                      size="sm"
                                      className="h-6 w-full translate-x-0 justify-start px-2 text-left text-[10px] text-muted-foreground/60 hover:bg-accent hover:text-muted-foreground/80"
                                      onClick={() => {
                                        expandThreadListForProject(project.id);
                                      }}
                                    >
                                      <span>Show more</span>
                                    </SidebarMenuSubButton>
                                  </SidebarMenuSubItem>
                                )}
                                {hasHiddenThreads && isThreadListExpanded && (
                                  <SidebarMenuSubItem className="w-full">
                                    <SidebarMenuSubButton
                                      render={<button type="button" />}
                                      size="sm"
                                      className="h-6 w-full translate-x-0 justify-start px-2 text-left text-[10px] text-muted-foreground/60 hover:bg-accent hover:text-muted-foreground/80"
                                      onClick={() => {
                                        collapseThreadListForProject(project.id);
                                      }}
                                    >
                                      <span>Show less</span>
                                    </SidebarMenuSubButton>
                                  </SidebarMenuSubItem>
                                )}
                              </SidebarMenuSub>
                          </CollapsibleContent>
                        </Collapsible>
                      )}
                    </SortableProjectItem>
                  );
                })}
              </SortableContext>
            </SidebarMenu>
          </DndContext>

          {projects.length === 0 && !shouldShowProjectPathEntry && (
            <div className="px-2 pt-4 text-center text-xs text-muted-foreground/60">
              No projects yet
            </div>
          )}
        </SidebarGroup>
      </SidebarContent>

      <SidebarSeparator />
      <SidebarFooter className="p-2">
        <SidebarMenu>
          <SidebarMenuItem>
            {isOnSettings ? (
              <SidebarMenuButton
                size="sm"
                className="gap-2 px-2 py-1.5 text-muted-foreground/70 hover:bg-accent hover:text-foreground"
                onClick={() => window.history.back()}
              >
                <ArrowLeftIcon className="size-3.5" />
                <span className="text-xs">Back</span>
              </SidebarMenuButton>
            ) : (
              <SidebarMenuButton
                size="sm"
                className="gap-2 px-2 py-1.5 text-muted-foreground/70 hover:bg-accent hover:text-foreground"
                onClick={() => void navigate({ to: "/settings" })}
              >
                <SettingsIcon className="size-3.5" />
                <span className="text-xs">Settings</span>
              </SidebarMenuButton>
            )}
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </>
  );
}
