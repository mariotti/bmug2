import { describe, it, expect, vi, afterEach } from "vitest";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { open } from "@tauri-apps/plugin-dialog";
import {
  isDaily,
  el,
  helpIcon,
  formatKb,
  buildProjectStatsCells,
  formatSchedule,
  timeInputValue,
  parseTimeInput,
  buildScheduleEditor,
  buildReplicationEditor,
  findUntrackedProjects,
  buildUntrackedProjectsNotice,
  buildIgnoreToggles,
  buildBmuignoreEditor,
  buildScheduleInfoPanel,
  sourceLabel,
  isMac,
  runJob,
  buildRunBanner,
  renderDashboard,
  formatVersion,
  buildUpdateAvailableNotice,
  runSearch,
  renderSearchResults,
  setSourceSchedule,
  clearSourceSchedule,
  saveIgnoreSettings,
  removeSource,
  setHousekeepingSchedule,
  clearHousekeepingSchedule,
  setReplication,
  clearReplication,
  renderSetup,
  renderSettings,
  buildProtonFolderBrowser,
  buildGoogleDriveFolderBrowser,
  buildReplicationSection,
  init,
  type Schedule,
  type StatusProject,
  type StatusResult,
  type BackupSource,
  type IgnoreSettings,
  type IgnoreSettingsInput,
  type ReplicationStatus,
  type ReplicationRequest,
  type RunOutput,
  type RunBanner,
  type UpdateCheck,
  type LocateResult,
  type LocateHit,
  type DefaultPaths,
  type InstallOutcome,
  type RemoteEntry,
} from "./main";

// runJob awaits listen() before doing anything else observable from a test
// (see its own "listen before invoking" comment in main.ts), so it needs a
// resolved stand-in here regardless of which test exercises it.
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));
// renderDashboard's own fetches, plus whichever job command a test drives,
// all go through this - the user-journey tests below mock the whole surface
// rather than injecting callbacks, since the point is exercising the real
// click -> invoke -> event -> re-render wiring, not a unit in isolation.
// Defaults to a never-resolving promise (not undefined) so the several
// pre-existing tests above that don't care about invoke at all - but still
// trigger a fire-and-forget invoke(...).then(...) somewhere, e.g.
// buildReplicationEditor's eager rclone_available check - don't crash on
// "Cannot read properties of undefined (reading 'then')".
const { pendingForever } = vi.hoisted(() => ({ pendingForever: () => new Promise(() => {}) }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(pendingForever) }));
// Real openUrl/revealItemInDir both go through the Tauri IPC bridge,
// which doesn't exist in this jsdom test environment - mocked here
// once for every test, same reasoning as the two mocks above. Both
// default to a resolved promise (not undefined) since main.ts chains
// .catch() off revealItemInDir's result.
vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(() => Promise.resolve()),
  revealItemInDir: vi.fn(() => Promise.resolve()),
}));
// directoryField's Browse button goes through this - same reasoning
// as the two mocks above. Defaults to a never-resolving promise so a
// test that doesn't click Browse never relies on the dialog picker.
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn(pendingForever) }));

function ignoreSettings(overrides: Partial<IgnoreSettings> = {}): IgnoreSettings {
  return {
    gitignore: true,
    gitignore_exists: true,
    bmuignore: false,
    bmuignore_content: "",
    ...overrides,
  };
}

function project(overrides: Partial<StatusProject> = {}): StatusProject {
  return {
    name: "proj",
    last_run: null,
    last_change: null,
    snapshot_count: 0,
    mirror_size_kb: 0,
    history_size_kb: null,
    old_layout: false,
    ...overrides,
  };
}

function source(overrides: Partial<BackupSource> = {}): BackupSource {
  return { name: "proj", path: "/home/proj", schedule: null, ...overrides };
}

describe("isDaily", () => {
  it("is true for a {hour, minute} schedule", () => {
    expect(isDaily({ hour: 2, minute: 0 })).toBe(true);
  });
  it("is false for a {minutes} schedule", () => {
    expect(isDaily({ minutes: 30 })).toBe(false);
  });
});

describe("el", () => {
  it("sets the tag, attributes, and children", () => {
    const node = el("button", { type: "button", class: "x" }, ["Save"]);
    expect(node.tagName).toBe("BUTTON");
    expect(node.getAttribute("type")).toBe("button");
    expect(node.getAttribute("class")).toBe("x");
    expect(node.textContent).toBe("Save");
  });

  it("accepts other DOM nodes as children, not just strings", () => {
    const child = el("span", {}, ["inner"]);
    const parent = el("div", {}, [child]);
    expect(parent.firstElementChild).toBe(child);
  });
});

describe("helpIcon", () => {
  it("shows a circled ? with the description as its tooltip", () => {
    const icon = helpIcon("Does the thing.");
    expect(icon.textContent).toBe("?");
    expect(icon.getAttribute("title")).toBe("Does the thing.");
  });

  it("appends a CLI equivalent to the tooltip when given one", () => {
    const icon = helpIcon("Does the thing.", "backmeup.sh ~/Documents");
    const title = icon.getAttribute("title")!;
    expect(title).toContain("Does the thing.");
    expect(title).toContain("CLI equivalent:");
    expect(title).toContain("backmeup.sh ~/Documents");
  });

  it("omits the CLI equivalent section entirely when none is given", () => {
    const icon = helpIcon("Does the thing.");
    expect(icon.getAttribute("title")).not.toContain("CLI equivalent");
  });
});

describe("formatKb", () => {
  it("renders null as a dash", () => {
    expect(formatKb(null)).toBe("-");
  });
  it("renders sub-MB sizes in KB", () => {
    expect(formatKb(512)).toBe("512 KB");
  });
  it("renders MB-and-above sizes with one decimal", () => {
    expect(formatKb(2048)).toBe("2.0 MB");
    expect(formatKb(1536)).toBe("1.5 MB");
  });
  it("treats exactly 1024 KB as the MB boundary", () => {
    expect(formatKb(1024)).toBe("1.0 MB");
  });
});

describe("formatSchedule", () => {
  it("zero-pads a daily schedule", () => {
    expect(formatSchedule({ hour: 2, minute: 5 })).toBe("Daily at 02:05");
  });
  it("renders an interval schedule in minutes", () => {
    expect(formatSchedule({ minutes: 30 })).toBe("Every 30 minutes");
  });
});

describe("timeInputValue", () => {
  it("zero-pads hour and minute for an <input type=time>", () => {
    expect(timeInputValue({ hour: 9, minute: 5 })).toBe("09:05");
  });
});

describe("parseTimeInput", () => {
  it("parses a well-formed HH:MM value", () => {
    expect(parseTimeInput("14:30")).toEqual({ hour: 14, minute: 30 });
  });
  it.each(["", "2:5", "14:3", "not-a-time", "14:300", "1430"])(
    "rejects %s",
    (value) => {
      expect(parseTimeInput(value)).toBeNull();
    },
  );
});

describe("sourceLabel", () => {
  it("passes index and live through unchanged", () => {
    expect(sourceLabel("index")).toBe("index");
    expect(sourceLabel("live")).toBe("live");
  });
  it("collapses anything else to archived", () => {
    expect(sourceLabel("archived_filelist")).toBe("archived");
  });
});

describe("isMac", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("is true when navigator.platform mentions Mac", () => {
    vi.stubGlobal("navigator", { platform: "MacIntel" });
    expect(isMac()).toBe(true);
  });

  it("is false otherwise", () => {
    vi.stubGlobal("navigator", { platform: "Linux x86_64" });
    expect(isMac()).toBe(false);
  });
});

describe("buildScheduleInfoPanel", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns null on macOS when Full Disk Access is already granted", () => {
    vi.stubGlobal("navigator", { platform: "MacIntel" });
    expect(buildScheduleInfoPanel(true)).toBeNull();
  });

  it("shows the Full Disk Access warning on macOS when it is not granted", () => {
    vi.stubGlobal("navigator", { platform: "MacIntel" });
    const panel = buildScheduleInfoPanel(false);
    expect(panel?.textContent).toContain("Full Disk Access");
  });

  it("shows the lingering-session note on Linux regardless of hasFullDiskAccess", () => {
    vi.stubGlobal("navigator", { platform: "Linux x86_64" });
    expect(buildScheduleInfoPanel(true)?.textContent).toContain("lingering");
    expect(buildScheduleInfoPanel(false)?.textContent).toContain("lingering");
  });
});

describe("findUntrackedProjects", () => {
  const status: StatusResult = {
    sync_dir: "/sync",
    history_dir: "/history",
    projects: [
      project({ name: "already-tracked" }),
      project({ name: "cli-only" }),
      project({ name: "old-layout-project", old_layout: true }),
    ],
  };
  const sources: BackupSource[] = [source({ name: "already-tracked" })];

  it("excludes projects that already have a tracked Backup Source", () => {
    const result = findUntrackedProjects(status, sources);
    expect(result.map((p) => p.name)).not.toContain("already-tracked");
  });

  it("excludes old_layout projects even if untracked", () => {
    const result = findUntrackedProjects(status, sources);
    expect(result.map((p) => p.name)).not.toContain("old-layout-project");
  });

  it("includes a project with real history that isn't tracked yet", () => {
    const result = findUntrackedProjects(status, sources);
    expect(result.map((p) => p.name)).toEqual(["cli-only"]);
  });
});

describe("buildUntrackedProjectsNotice", () => {
  it("returns null when there is nothing untracked", () => {
    expect(buildUntrackedProjectsNotice([], "/bin")).toBeNull();
  });

  it("lists one row per untracked project", () => {
    const notice = buildUntrackedProjectsNotice(
      [project({ name: "docs" }), project({ name: "photos" })],
      "/bin",
    );
    expect(notice).not.toBeNull();
    const rows = notice!.querySelectorAll("tbody tr");
    expect(rows).toHaveLength(2);
    expect(rows[0].textContent).toContain("docs");
    expect(rows[1].textContent).toContain("photos");
    expect(notice!.querySelector("button")).not.toBeNull();
  });

  it("shows last-run and size stats for an untracked project, not just its name", () => {
    const notice = buildUntrackedProjectsNotice(
      [
        project({
          name: "docs",
          last_run: "2026-10-16 10:00:00",
          last_change: "2026-10-15 09:00:00",
          snapshot_count: 3,
          mirror_size_kb: 2048,
          history_size_kb: 512,
        }),
      ],
      "/bin",
    );
    const row = notice!.querySelector("tbody tr")!;
    expect(row.textContent).toContain("2026-10-16 10:00:00");
    expect(row.textContent).toContain("2026-10-15 09:00:00");
    expect(row.textContent).toContain("3");
    expect(row.textContent).toContain("2.0 MB");
    expect(row.textContent).toContain("512 KB");
  });
});

describe("buildProjectStatsCells", () => {
  it("renders a dash in every cell when there is no known status yet", () => {
    const cells = buildProjectStatsCells(undefined);
    expect(cells).toHaveLength(4);
    expect(cells.map((c) => c.textContent)).toEqual(["-", "-", "-", "-"]);
  });

  it("renders a known project's real stats", () => {
    const cells = buildProjectStatsCells(
      project({
        last_change: "2026-10-15 09:00:00",
        snapshot_count: 3,
        mirror_size_kb: 2048,
        history_size_kb: 512,
      }),
    );
    expect(cells.map((c) => c.textContent)).toEqual([
      "2026-10-15 09:00:00",
      "3",
      "2.0 MB",
      "512 KB",
    ]);
  });

  it("renders a dash for a history size that's genuinely null", () => {
    const cells = buildProjectStatsCells(project({ history_size_kb: null }));
    expect(cells[3].textContent).toBe("-");
  });
});

describe("buildScheduleEditor", () => {
  it("starts on Daily with 02:00 when there is no current schedule", () => {
    const editor = buildScheduleEditor(null, vi.fn(), vi.fn());
    const timeInput = editor.querySelector("input[type=time]") as HTMLInputElement;
    const select = editor.querySelector("select") as HTMLSelectElement;
    expect(select.value).toBe("daily");
    expect(timeInput.value).toBe("02:00");
  });

  it("starts on Interval when the current schedule is an interval", () => {
    const current: Schedule = { minutes: 10 };
    const editor = buildScheduleEditor(current, vi.fn(), vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    expect(select.value).toBe("interval");
  });

  it("Save calls onSave with the parsed daily time", () => {
    const onSave = vi.fn();
    const editor = buildScheduleEditor(null, onSave, vi.fn());
    const timeInput = editor.querySelector("input[type=time]") as HTMLInputElement;
    timeInput.value = "03:15";
    const [saveBtn] = editor.querySelectorAll("button");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith({ hour: 3, minute: 15 });
  });

  it("Save does not call onSave when the daily time is malformed", () => {
    const onSave = vi.fn();
    const editor = buildScheduleEditor(null, onSave, vi.fn());
    const timeInput = editor.querySelector("input[type=time]") as HTMLInputElement;
    timeInput.value = "garbage";
    const [saveBtn] = editor.querySelectorAll("button");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).not.toHaveBeenCalled();
  });

  it("Cancel calls onCancel", () => {
    const onCancel = vi.fn();
    const editor = buildScheduleEditor(null, vi.fn(), onCancel);
    const [, cancelBtn] = editor.querySelectorAll("button");
    cancelBtn.dispatchEvent(new Event("click"));
    expect(onCancel).toHaveBeenCalledOnce();
  });
});

// The editor's button count/order keeps shifting as Browse buttons are
// added per remote field - select by label instead of position so
// future additions don't require re-deriving every test's indices.
function buttonLabeled(root: HTMLElement, text: string): HTMLButtonElement {
  const match = Array.from(root.querySelectorAll("button")).find((b) => b.textContent === text);
  if (!match) throw new Error(`no button labeled "${text}"`);
  return match;
}

describe("buildReplicationEditor", () => {
  const off: ReplicationStatus = { backend: "off" };

  it("starts on rclone with empty remotes when off", () => {
    const editor = buildReplicationEditor(off, vi.fn(), vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    const [remoteSync, remoteBackups] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    expect(select.value).toBe("rclone");
    expect(remoteSync.value).toBe("");
    expect(remoteBackups.value).toBe("");
  });

  it("starts on rclone pre-filled when currently configured for rclone", () => {
    const current: ReplicationStatus = {
      backend: "rclone",
      remote_sync: "remote:a",
      remote_backups: "remote:b",
    };
    const editor = buildReplicationEditor(current, vi.fn(), vi.fn());
    const [remoteSync, remoteBackups] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    expect(remoteSync.value).toBe("remote:a");
    expect(remoteBackups.value).toBe("remote:b");
  });

  it("starts on proton pre-filled when currently configured for proton", () => {
    const current: ReplicationStatus = { backend: "proton", remote: "/bmug2/host" };
    const editor = buildReplicationEditor(current, vi.fn(), vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    const [, , protonRemote] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    expect(select.value).toBe("proton");
    expect(protonRemote.value).toBe("/bmug2/host");
  });

  it("Save calls onSave with rclone fields when both remotes are filled", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const [remoteSync, remoteBackups] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    remoteSync.value = "remote:a";
    remoteBackups.value = "remote:b";
    const saveBtn = buttonLabeled(editor, "Save");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith({
      backend: "rclone",
      remote_sync: "remote:a",
      remote_backups: "remote:b",
    });
  });

  it("Save does not call onSave when an rclone remote is missing", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const [remoteSync] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    remoteSync.value = "remote:a";
    const saveBtn = buttonLabeled(editor, "Save");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).not.toHaveBeenCalled();
  });

  it("Save calls onSave with a null remote for proton when left blank", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    select.value = "proton";
    select.dispatchEvent(new Event("change"));
    const saveBtn = buttonLabeled(editor, "Save");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith({ backend: "proton", remote: null });
  });

  it("Save calls onSave with the typed remote for proton when given", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    select.value = "proton";
    select.dispatchEvent(new Event("change"));
    const [, , protonRemote] = editor.querySelectorAll("input") as NodeListOf<HTMLInputElement>;
    protonRemote.value = "/bmug2/custom";
    const saveBtn = buttonLabeled(editor, "Save");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith({ backend: "proton", remote: "/bmug2/custom" });
  });

  it("Cancel calls onCancel", () => {
    const onCancel = vi.fn();
    const editor = buildReplicationEditor(off, vi.fn(), onCancel);
    const cancelBtn = buttonLabeled(editor, "Cancel");
    cancelBtn.dispatchEvent(new Event("click"));
    expect(onCancel).toHaveBeenCalledOnce();
  });

  it("has a Mounted folder option in the backend select", () => {
    const editor = buildReplicationEditor(off, vi.fn(), vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    const options = Array.from(select.options).map((o) => o.value);
    expect(options).toContain("local_path");
  });

  it("starts on local_path pre-filled when currently configured as local_path", () => {
    const current: ReplicationStatus = {
      backend: "local_path",
      path_sync: "/cloud/bmug2/SYNC",
      path_backups: "/cloud/bmug2/BackUp",
    };
    const editor = buildReplicationEditor(current, vi.fn(), vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    expect(select.value).toBe("local_path");
    const inputs = Array.from(editor.querySelectorAll<HTMLInputElement>("input[type=text]"));
    const pathSyncInput = inputs.find((i) => i.value === "/cloud/bmug2/SYNC");
    const pathBackupsInput = inputs.find((i) => i.value === "/cloud/bmug2/BackUp");
    expect(pathSyncInput).not.toBeUndefined();
    expect(pathBackupsInput).not.toBeUndefined();
  });

  it("Save emits local_path request with both paths when local_path is selected and both filled", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    select.value = "local_path";
    select.dispatchEvent(new Event("change"));

    // Find visible inputs after switching to local_path (rclone inputs are hidden)
    const allInputs = Array.from(editor.querySelectorAll<HTMLInputElement>("input[type=text]"));
    const visibleInputs = allInputs.filter((i) => {
      let ancestor: HTMLElement | null = i;
      while (ancestor) {
        if (ancestor.style.display === "none") return false;
        ancestor = ancestor.parentElement;
      }
      return true;
    });
    visibleInputs[0].value = "/cloud/bmug2/SYNC";
    visibleInputs[1].value = "/cloud/bmug2/BackUp";
    buttonLabeled(editor, "Save").dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith({
      backend: "local_path",
      path_sync: "/cloud/bmug2/SYNC",
      path_backups: "/cloud/bmug2/BackUp",
    });
  });

  it("Save does not call onSave for local_path when a path is missing", () => {
    const onSave = vi.fn();
    const editor = buildReplicationEditor(off, onSave, vi.fn());
    const select = editor.querySelector("select") as HTMLSelectElement;
    select.value = "local_path";
    select.dispatchEvent(new Event("change"));
    // leave both path inputs empty
    buttonLabeled(editor, "Save").dispatchEvent(new Event("click"));
    expect(onSave).not.toHaveBeenCalled();
  });
});

describe("buildIgnoreToggles", () => {
  it("reflects the current gitignore/bmuignore checkbox state", () => {
    const toggles = buildIgnoreToggles(ignoreSettings({ gitignore: false, bmuignore: true }), vi.fn());
    const [gitignoreCheck, bmuignoreCheck] = toggles.querySelectorAll(
      "input[type=checkbox]",
    ) as NodeListOf<HTMLInputElement>;
    expect(gitignoreCheck.checked).toBe(false);
    expect(bmuignoreCheck.checked).toBe(true);
  });

  it("notes when .gitignore isn't present in the folder", () => {
    const toggles = buildIgnoreToggles(ignoreSettings({ gitignore_exists: false }), vi.fn());
    expect(toggles.textContent).toContain("not present in this folder");
  });

  it("fires onToggle with the field and new value on change, not on render", () => {
    const onToggle = vi.fn();
    const toggles = buildIgnoreToggles(ignoreSettings(), onToggle);
    const [gitignoreCheck, bmuignoreCheck] = toggles.querySelectorAll(
      "input[type=checkbox]",
    ) as NodeListOf<HTMLInputElement>;
    expect(onToggle).not.toHaveBeenCalled();

    bmuignoreCheck.checked = true;
    bmuignoreCheck.dispatchEvent(new Event("change"));
    expect(onToggle).toHaveBeenCalledWith("bmuignore", true);

    gitignoreCheck.checked = false;
    gitignoreCheck.dispatchEvent(new Event("change"));
    expect(onToggle).toHaveBeenCalledWith("gitignore", false);
  });
});

describe("buildBmuignoreEditor", () => {
  it("pre-fills the textarea with the current .bmuignore content", () => {
    const editor = buildBmuignoreEditor("node_modules/\n*.log\n", vi.fn(), vi.fn());
    const textarea = editor.querySelector("textarea") as HTMLTextAreaElement;
    expect(textarea.value).toBe("node_modules/\n*.log\n");
  });

  it("Save calls onSave with the current textarea content", () => {
    const onSave = vi.fn();
    const editor = buildBmuignoreEditor("", onSave, vi.fn());
    const textarea = editor.querySelector("textarea") as HTMLTextAreaElement;
    textarea.value = "*.tmp\n";
    const [saveBtn] = editor.querySelectorAll("button");
    saveBtn.dispatchEvent(new Event("click"));
    expect(onSave).toHaveBeenCalledWith("*.tmp\n");
  });

  it("Cancel calls onCancel", () => {
    const onCancel = vi.fn();
    const editor = buildBmuignoreEditor("", vi.fn(), onCancel);
    const [, cancelBtn] = editor.querySelectorAll("button");
    cancelBtn.dispatchEvent(new Event("click"));
    expect(onCancel).toHaveBeenCalledOnce();
  });
});

describe("buildRunBanner", () => {
  function render(banner: RunBanner) {
    return buildRunBanner(banner);
  }

  it("renders a success banner with the ok styling and no log", () => {
    const banner = render({ ok: true, message: "Backup for proj1 completed." });
    expect(banner.className).toBe("run-banner run-banner-ok");
    expect(banner.textContent).toBe("Backup for proj1 completed.");
    expect(banner.querySelector("pre")).toBeNull();
  });

  it("renders a failure banner with the error styling and the full log", () => {
    const banner = render({
      ok: false,
      message: "Backup for proj1 failed.",
      log: "rsync: connection unexpectedly closed\nrsync error: error in rsync protocol data stream",
    });
    expect(banner.className).toBe("run-banner run-banner-error");
    expect(banner.querySelector("p")?.textContent).toBe("Backup for proj1 failed.");
    const log = banner.querySelector("pre");
    expect(log?.className).toBe("log log-error");
    expect(log?.textContent).toBe("rsync: connection unexpectedly closed\nrsync error: error in rsync protocol data stream");
  });

  it("renders a failure banner with no log element when no log was given", () => {
    const banner = render({ ok: false, message: "Backup for proj1 failed." });
    expect(banner.className).toBe("run-banner run-banner-error");
    expect(banner.querySelector("pre")).toBeNull();
  });
});

describe("runJob", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(listen).mockReset();
  });

  // Mirrors the two real shapes runJob is wired into: a per-source row
  // (buildSourcesSection - a <tr><td><pre></td></tr>) and Housekeeping's row
  // (buildHousekeepingSection - a plain <div><pre></div>). A real bug once
  // slipped through specifically because it only broke one of these two
  // shapes (inferring the row from logEl.parentElement - correct for the
  // <div> case, wrong for the <tr> one) - exercising both here so that
  // class of bug can't silently come back.
  function perSourceRow() {
    const logEl = el("pre", { class: "log" }, []);
    const row = el("tr", {}, [el("td", {}, [logEl])]);
    row.style.display = "none";
    return { row, logEl };
  }

  function housekeepingRow() {
    const logEl = el("pre", { class: "log" }, []);
    const row = el("div", {}, [logEl]);
    row.style.display = "none";
    return { row, logEl };
  }

  // Never resolves - these tests only inspect the synchronous "while
  // running" state runJob sets up before its first await, not completion
  // handling (which goes through renderDashboard, exercised separately via
  // the browser-based end-to-end check, not a unit test).
  const pendingJob = (): (() => Promise<RunOutput>) => () => new Promise(() => {});

  it("reveals only the triggering job's own row, leaving a sibling job's row hidden", () => {
    vi.mocked(listen).mockResolvedValue(vi.fn());
    const source = perSourceRow();
    const housekeeping = housekeepingRow();
    const sourceTrigger = el("button", { class: "job-trigger-btn" }, ["Run now"]);
    const hkTrigger = el("button", { class: "job-trigger-btn" }, ["Run now"]);
    document.querySelector("#app")!.append(source.row, housekeeping.row, sourceTrigger, hkTrigger);

    void runJob("/bin", sourceTrigger, source.row, source.logEl, "backup-progress", pendingJob(), {
      ok: "done",
      fail: "failed",
    });

    expect(source.row.style.display).toBe("");
    expect(housekeeping.row.style.display).toBe("none");
  });

  it("disables every job-trigger-btn, leaves unrelated buttons alone, and spins the clicked one", () => {
    vi.mocked(listen).mockResolvedValue(vi.fn());
    const source = perSourceRow();
    const sourceTrigger = el("button", { class: "job-trigger-btn" }, ["Run now"]);
    const hkTrigger = el("button", { class: "job-trigger-btn" }, ["Run now"]);
    const scheduleBtn = el("button", {}, ["Set schedule"]);
    document.querySelector("#app")!.append(source.row, sourceTrigger, hkTrigger, scheduleBtn);

    void runJob("/bin", sourceTrigger, source.row, source.logEl, "backup-progress", pendingJob(), {
      ok: "done",
      fail: "failed",
    });

    expect(sourceTrigger.disabled).toBe(true);
    expect(sourceTrigger.textContent).toContain("Running…");
    expect(sourceTrigger.querySelector(".spinner")).not.toBeNull();
    expect(hkTrigger.disabled).toBe(true);
    expect(scheduleBtn.disabled).toBe(false);
  });

  it("appends each streamed line to the triggering job's own log, not a sibling's", async () => {
    let handler: ((event: { payload: string }) => void) | undefined;
    vi.mocked(listen).mockImplementation(async (_event, cb) => {
      handler = cb as (event: { payload: string }) => void;
      return () => {};
    });
    const source = perSourceRow();
    const housekeeping = housekeepingRow();
    const sourceTrigger = el("button", { class: "job-trigger-btn" }, ["Run now"]);
    document.querySelector("#app")!.append(source.row, housekeeping.row, sourceTrigger);

    void runJob("/bin", sourceTrigger, source.row, source.logEl, "backup-progress", pendingJob(), {
      ok: "done",
      fail: "failed",
    });
    await Promise.resolve();
    await Promise.resolve();

    handler?.({ payload: "proj1/file1.txt" });

    expect(source.logEl.textContent).toBe("proj1/file1.txt\n");
    expect(housekeeping.logEl.textContent).toBe("");
  });
});

// Turns the manual browser scratch-harness verification done during this
// PR's own implementation (mocking Tauri's invoke/event system in a real
// tab, clicking Run Now, watching it stream and reset) into a committed,
// repeatable test instead of a one-off check that gets thrown away. Drives
// the real click -> runBackupNow/runHousekeepingNow -> runJob -> invoke ->
// event -> renderDashboard chain end to end, not just runJob in isolation.
describe("user journeys (renderDashboard end to end)", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
    vi.mocked(listen).mockReset();
  });

  function deferred<T>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((res) => {
      resolve = res;
    });
    return { promise, resolve };
  }

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  function sectionByHeading(heading: string): HTMLElement {
    // startsWith, not === : an h2's own textContent now also includes
    // its trailing helpIcon's "?" (see main.ts's helpIcon calls).
    const section = Array.from(document.querySelectorAll<HTMLElement>("#app > section")).find(
      (s) => s.querySelector("h2")?.textContent?.startsWith(heading),
    );
    if (!section) throw new Error(`no section with heading "${heading}"`);
    return section;
  }

  // Covers everything renderDashboard fetches for one real source and no
  // housekeeping schedule/replication configured - the same minimal shape
  // the scratch harness used. `jobCommand`/`jobResult` wire up whichever of
  // run_backup_now / run_housekeeping_now the test below is driving.
  function mockDashboardInvoke(jobCommand: string, jobResult: Promise<RunOutput>) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      switch (cmd) {
        case "get_status":
          return { sync_dir: "/fake/sync", history_dir: "/fake/sync-BP", projects: [] } satisfies StatusResult;
        case "list_sources":
          return [{ name: "proj1", path: "/fake/src/proj1", schedule: null }] satisfies BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_ignore_settings":
          return {
            gitignore: true,
            gitignore_exists: true,
            bmuignore: false,
            bmuignore_content: "",
          } satisfies IgnoreSettings;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        case jobCommand:
          return jobResult;
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  it("per-source Run Now: click streams progress, disables Housekeeping's button too, and ends on a clean success banner", async () => {
    vi.mocked(listen).mockResolvedValue(vi.fn());
    const job = deferred<RunOutput>();
    mockDashboardInvoke("run_backup_now", job.promise);

    await renderDashboard("/bin");

    const sourceTrigger = document.querySelector<HTMLButtonElement>(".sources-table .job-trigger-btn")!;
    const hkTrigger = sectionByHeading("Housekeeping").querySelector<HTMLButtonElement>(".job-trigger-btn")!;
    sourceTrigger.dispatchEvent(new Event("click"));

    // Synchronous "while running" state - runJob sets all of this before
    // its first await, so no flush is needed to observe it.
    expect(sourceTrigger.disabled).toBe(true);
    expect(sourceTrigger.textContent).toContain("Running…");
    expect(hkTrigger.disabled).toBe(true);
    const sourceLog = document.querySelector<HTMLElement>(".sources-table pre.log")!;
    expect(sourceLog.closest("tr")!.style.display).toBe("");

    await waitFor(() => vi.mocked(listen).mock.calls.length > 0);
    const [, listenHandler] = vi.mocked(listen).mock.calls[0];
    (listenHandler as (event: { payload: string }) => void)({ payload: "proj1/file1.txt" });
    expect(sourceLog.textContent).toBe("proj1/file1.txt\n");

    job.resolve({ ok: true, log: "proj1/file1.txt\n" });
    await waitFor(() => document.querySelector(".run-banner") !== null);

    const banner = document.querySelector(".run-banner")!;
    expect(banner.className).toBe("run-banner run-banner-ok");
    expect(banner.textContent).toBe("Backup for proj1 completed.");
    // renderDashboard rebuilt everything fresh - re-query, don't reuse the
    // (now detached) elements from before the re-render.
    const resetTrigger = document.querySelector<HTMLButtonElement>(".sources-table .job-trigger-btn")!;
    expect(resetTrigger.disabled).toBe(false);
    expect(resetTrigger.textContent).toBe("Run now");
    expect(sectionByHeading("Housekeeping").querySelector<HTMLButtonElement>(".job-trigger-btn")!.disabled).toBe(
      false,
    );
  });

  it("Housekeeping Run now: click streams progress, disables the source's button too, and ends on a clean success banner", async () => {
    vi.mocked(listen).mockResolvedValue(vi.fn());
    const job = deferred<RunOutput>();
    mockDashboardInvoke("run_housekeeping_now", job.promise);

    await renderDashboard("/bin");

    const hkSection = sectionByHeading("Housekeeping");
    const hkTrigger = hkSection.querySelector<HTMLButtonElement>(".job-trigger-btn")!;
    const sourceTrigger = document.querySelector<HTMLButtonElement>(".sources-table .job-trigger-btn")!;
    hkTrigger.dispatchEvent(new Event("click"));

    expect(hkTrigger.disabled).toBe(true);
    expect(hkTrigger.textContent).toContain("Running…");
    expect(sourceTrigger.disabled).toBe(true);
    const hkLog = hkSection.querySelector<HTMLElement>("pre.log")!;
    expect(hkLog.parentElement!.style.display).toBe("");

    await waitFor(() => vi.mocked(listen).mock.calls.length > 0);
    const [, listenHandler] = vi.mocked(listen).mock.calls[0];
    (listenHandler as (event: { payload: string }) => void)({ payload: "Indexed 42 files" });
    expect(hkLog.textContent).toBe("Indexed 42 files\n");

    job.resolve({ ok: true, log: "Indexed 42 files\n" });
    await waitFor(() => document.querySelector(".run-banner") !== null);

    const banner = document.querySelector(".run-banner")!;
    expect(banner.className).toBe("run-banner run-banner-ok");
    expect(banner.textContent).toBe("Housekeeping completed.");
    const resetTrigger = sectionByHeading("Housekeeping").querySelector<HTMLButtonElement>(".job-trigger-btn")!;
    expect(resetTrigger.disabled).toBe(false);
    expect(document.querySelector<HTMLButtonElement>(".sources-table .job-trigger-btn")!.disabled).toBe(false);
  });
});

describe("renderDashboard shows each source's own status inline", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
    vi.mocked(listen).mockReset();
  });

  function mockStatus(projects: StatusProject[]) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      switch (cmd) {
        case "get_status":
          return { sync_dir: "/fake/sync", history_dir: "/fake/sync-BP", projects } satisfies StatusResult;
        case "list_sources":
          return [{ name: "proj1", path: "/fake/src/proj1", schedule: null }] satisfies BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_ignore_settings":
          return {
            gitignore: true,
            gitignore_exists: true,
            bmuignore: false,
            bmuignore_content: "",
          } satisfies IgnoreSettings;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        case "remove_source":
          return undefined;
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  it("Remove needs a second click to confirm, and Cancel backs out without removing anything", async () => {
    mockStatus([project({ name: "proj1" })]);

    await renderDashboard("/bin");

    const removeBtn = document.querySelector<HTMLButtonElement>(".sources-table .remove-btn")!;
    expect(removeBtn.textContent).toBe("Remove");

    removeBtn.dispatchEvent(new Event("click"));
    expect(removeBtn.textContent).toBe("Really remove?");
    const cancelBtn = document.querySelector<HTMLButtonElement>(".remove-cancel-btn")!;
    expect(cancelBtn.style.display).not.toBe("none");
    expect(vi.mocked(invoke)).not.toHaveBeenCalledWith("remove_source", expect.anything());

    cancelBtn.dispatchEvent(new Event("click"));
    expect(removeBtn.textContent).toBe("Remove");
    expect(cancelBtn.style.display).toBe("none");
    expect(vi.mocked(invoke)).not.toHaveBeenCalledWith("remove_source", expect.anything());

    removeBtn.dispatchEvent(new Event("click"));
    removeBtn.dispatchEvent(new Event("click"));
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("remove_source", { path: "/fake/src/proj1" });
  });

  it("shows a tracked source's real stats in its own row, with no separate status table", async () => {
    mockStatus([
      project({
        name: "proj1",
        last_run: "2026-10-16 10:00:00",
        last_change: "2026-10-15 09:00:00",
        snapshot_count: 3,
        mirror_size_kb: 2048,
        history_size_kb: 512,
      }),
    ]);

    await renderDashboard("/bin");

    expect(document.querySelector(".status-table")).toBeNull();
    const row = document.querySelector(".sources-table .source-info-row")!;
    expect(row.textContent).toContain("2026-10-15 09:00:00");
    expect(row.textContent).toContain("3");
    expect(row.textContent).toContain("2.0 MB");
    expect(row.textContent).toContain("512 KB");
  });

  it("wires a non-empty help tooltip onto every (?) icon on the dashboard", async () => {
    mockStatus([]);

    await renderDashboard("/bin");

    // 8 of the 9 planned icons live on this screen. mockStatus's own
    // list_sources stub always returns one source ("proj1") regardless
    // of the projects argument - that source contributes 2 icons
    // (Respect .gitignore + Use .bmuignore), and the remaining 6 come
    // from header tooltips (Backup sources, Schedule column,
    // Housekeeping, Off-site replication, Search, Last-change column).
    // The 9th icon (Update now) lives on the Settings screen.
    const icons = document.querySelectorAll<HTMLElement>(".help-icon");
    expect(icons).toHaveLength(8);
    icons.forEach((icon) => {
      expect(icon.textContent).toBe("?");
      expect(icon.getAttribute("title")).toBeTruthy();
    });
  });

  it("scopes the old-layout badge and warning to that one source's row", async () => {
    mockStatus([project({ name: "proj1", old_layout: true })]);

    await renderDashboard("/bin");

    const row = document.querySelector(".sources-table .source-info-row")!;
    expect(row.querySelector(".badge-old-layout")).not.toBeNull();
    const warning = document.querySelector(".note-old-layout")!;
    expect(warning.textContent).toContain("proj1: old layout");
  });
});

describe("formatVersion", () => {
  it("joins a [major, minor, patch] tuple with dots", () => {
    expect(formatVersion([2, 16, 3])).toBe("2.16.3");
  });
});

describe("buildUpdateAvailableNotice", () => {
  it("returns null when no update is available", () => {
    const check: UpdateCheck = { current: [2, 16, 2], latest: [2, 16, 2], update_available: false };
    expect(buildUpdateAvailableNotice(check, "/bin")).toBeNull();
  });

  it("names both versions and offers a way to Settings when an update is available", () => {
    const check: UpdateCheck = { current: [2, 16, 2], latest: [2, 16, 3], update_available: true };
    const notice = buildUpdateAvailableNotice(check, "/bin");
    expect(notice?.textContent).toContain("2.16.3");
    expect(notice?.textContent).toContain("2.16.2");
    expect(notice?.querySelector("button")?.textContent).toBe("Go to Settings");
  });
});

describe("renderSearchResults", () => {
  function result(overrides: Partial<LocateResult> = {}): LocateResult {
    return {
      patterns: ["x"],
      indexed: true,
      counts: { index: 0, live: 0, archived_filelist: 0 },
      results: [],
      ...overrides,
    };
  }

  function hits(n: number): LocateHit[] {
    return Array.from({ length: n }, (_, i) => ({ path: `/sync/proj1/file${i}.txt`, source: "live" }));
  }

  afterEach(() => {
    // mockClear, not mockReset: keep the factory default (a resolved
    // promise) other tests outside this block rely on implicitly -
    // reset would wipe it and make a later fire-and-forget call crash.
    vi.mocked(revealItemInDir).mockClear();
  });

  it("notes when nothing is indexed", () => {
    const box = el("div", {}, []);
    renderSearchResults(result({ indexed: false }), box);
    expect(box.textContent).toContain("No locate installed");
  });

  it("shows No matches for an empty result set", () => {
    const box = el("div", {}, []);
    renderSearchResults(result({ results: [] }), box);
    expect(box.textContent).toContain("No matches.");
  });

  it("lists each hit with its source tag, path, and a Reveal control", () => {
    const box = el("div", {}, []);
    renderSearchResults(
      result({ results: [{ path: "/sync/proj1/a.txt", source: "live" }, { path: "/archive/proj1/b.txt", source: "archived_filelist" }] }),
      box,
    );
    const items = box.querySelectorAll("li");
    expect(items).toHaveLength(2);
    expect(items[0].textContent).toContain("/sync/proj1/a.txt");
    expect(items[0].querySelector(".source-tag")?.className).toBe("source-tag source-live");
    expect(items[1].querySelector(".source-tag")?.textContent).toBe("archived");

    const revealBtn = items[0].querySelector<HTMLButtonElement>(".reveal-btn")!;
    revealBtn.dispatchEvent(new Event("click"));
    expect(revealItemInDir).toHaveBeenCalledWith("/sync/proj1/a.txt");
  });

  it("explains a stale result clearly instead of showing a raw OS error", async () => {
    // Real bug, found by the user: a result whose file has since moved
    // or been deleted (e.g. a build-output dir regenerated after the
    // index was last refreshed) rejected with a bare OS errno string -
    // "No such file or directory (os error 2)" - no context for why.
    vi.mocked(revealItemInDir).mockRejectedValueOnce(new Error("No such file or directory (os error 2)"));
    const box = el("div", {}, []);
    renderSearchResults(result({ results: [{ path: "/sync/proj1/gone.txt", source: "live" }] }), box);

    box.querySelector<HTMLButtonElement>(".reveal-btn")!.dispatchEvent(new Event("click"));
    await Promise.resolve(); // let the rejected promise's .catch run
    await Promise.resolve();

    const errorText = box.querySelector(".reveal-error")!.textContent!;
    expect(errorText).toContain("no longer there");
    expect(errorText).toContain("No such file or directory (os error 2)");
  });

  it("hides pagination controls entirely when everything fits on one page", () => {
    const box = el("div", {}, []);
    renderSearchResults(result({ results: hits(5) }), box);
    expect(box.querySelectorAll("li")).toHaveLength(5);
    expect(box.querySelector(".search-pagination")).toBeNull();
  });

  it("paginates a large result set entirely client-side - no re-fetch, all real matches reachable", () => {
    const box = el("div", {}, []);
    renderSearchResults(result({ results: hits(250) }), box);

    // Page 1: first 100, label reflects the true total.
    expect(box.querySelectorAll("li")).toHaveLength(100);
    expect(box.querySelector("li")!.textContent).toContain("file0.txt");
    const pagination = box.querySelector(".search-pagination")!;
    expect(pagination.textContent).toContain("Page 1 of 3");
    expect(pagination.textContent).toContain("250");
    const prevBtn = pagination.querySelector<HTMLButtonElement>(".search-page-prev")!;
    const nextBtn = pagination.querySelector<HTMLButtonElement>(".search-page-next")!;
    expect(prevBtn.disabled).toBe(true);
    expect(nextBtn.disabled).toBe(false);

    // Next: page 2, a different slice of the same in-memory array.
    nextBtn.dispatchEvent(new Event("click"));
    expect(box.querySelectorAll("li")).toHaveLength(100);
    expect(box.querySelector("li")!.textContent).toContain("file100.txt");
    expect(box.querySelector(".search-pagination")!.textContent).toContain("Page 2 of 3");

    // Next again: the final, shorter page (250 - 200 = 50).
    box.querySelector<HTMLButtonElement>(".search-page-next")!.dispatchEvent(new Event("click"));
    expect(box.querySelectorAll("li")).toHaveLength(50);
    expect(box.querySelector("li")!.textContent).toContain("file200.txt");
    const lastPagination = box.querySelector(".search-pagination")!;
    expect(lastPagination.textContent).toContain("Page 3 of 3");
    expect(lastPagination.querySelector<HTMLButtonElement>(".search-page-next")!.disabled).toBe(true);

    // Previous: back to page 2.
    box.querySelector<HTMLButtonElement>(".search-page-prev")!.dispatchEvent(new Event("click"));
    expect(box.querySelector(".search-pagination")!.textContent).toContain("Page 2 of 3");
  });

  it("Reveal on a later page operates on that page's actual hit, not page 1's", () => {
    const box = el("div", {}, []);
    renderSearchResults(result({ results: hits(150) }), box);
    box.querySelector<HTMLButtonElement>(".search-page-next")!.dispatchEvent(new Event("click"));

    const revealBtn = box.querySelector<HTMLButtonElement>(".reveal-btn")!;
    revealBtn.dispatchEvent(new Event("click"));
    expect(revealItemInDir).toHaveBeenCalledWith("/sync/proj1/file100.txt");
  });
});

describe("runSearch", () => {
  afterEach(() => {
    vi.mocked(invoke).mockReset();
  });

  it("shows a loading state immediately, then the real results on success", async () => {
    vi.mocked(invoke).mockResolvedValue({
      patterns: ["x"],
      indexed: true,
      counts: { index: 1, live: 0, archived_filelist: 0 },
      results: [{ path: "/sync/proj1/a.txt", source: "index" }],
    });
    const box = el("div", {}, []);
    const run = runSearch("/bin", ["x"], box);
    expect(box.textContent).toBe("Searching…");
    await run;
    expect(box.textContent).toContain("/sync/proj1/a.txt");
  });

  it("shows the error message on failure instead of leaving Searching… stuck", async () => {
    vi.mocked(invoke).mockRejectedValue(new Error("locate: command not found"));
    const box = el("div", {}, []);
    await runSearch("/bin", ["x"], box);
    expect(box.textContent).toContain("locate: command not found");
  });
});

// The eight simplest dashboard mutators (schedule/ignore/replication
// set-or-clear, remove) all share one shape: invoke a single command, then
// re-render cleanly on success or with an error banner on failure. One
// table covers all of them instead of eight near-identical test bodies.
describe("dashboard mutators (schedule/ignore/replication/remove)", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
  });

  function baseSource(overrides: Partial<BackupSource> = {}): BackupSource {
    return { name: "proj1", path: "/src/proj1", schedule: null, ...overrides };
  }

  // Every mutator's catch block fires renderDashboard with `void` rather
  // than awaiting it, so the mutator's own promise can resolve before the
  // re-render (several more invoke round-trips) actually finishes.
  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  function mockInvoke(command: string, behavior: "resolve" | "reject") {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd === command) {
        if (behavior === "reject") throw new Error(`${command} failed`);
        return undefined;
      }
      switch (cmd) {
        case "get_status":
          return { sync_dir: "/fake/sync", history_dir: "/fake/sync-BP", projects: [] } satisfies StatusResult;
        case "list_sources":
          return [] as BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        case "get_ignore_settings":
          return { gitignore: true, bmuignore: false, bmuignore_content: "" };
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  const mutators: { name: string; command: string; run: () => Promise<void> }[] = [
    {
      name: "setSourceSchedule",
      command: "set_source_schedule",
      run: () => setSourceSchedule("/bin", baseSource(), { hour: 2, minute: 0 }),
    },
    {
      name: "clearSourceSchedule",
      command: "clear_source_schedule",
      run: () => clearSourceSchedule("/bin", baseSource()),
    },
    {
      name: "saveIgnoreSettings",
      command: "set_ignore_settings",
      run: () =>
        saveIgnoreSettings("/bin", baseSource(), {
          gitignore: true,
          bmuignore: false,
          bmuignore_content: "",
        } satisfies IgnoreSettingsInput),
    },
    { name: "removeSource", command: "remove_source", run: () => removeSource("/bin", baseSource()) },
    {
      name: "setHousekeepingSchedule",
      command: "set_housekeeping_schedule",
      run: () => setHousekeepingSchedule("/bin", { hour: 2, minute: 0 }),
    },
    {
      name: "clearHousekeepingSchedule",
      command: "clear_housekeeping_schedule",
      run: () => clearHousekeepingSchedule("/bin"),
    },
    {
      name: "setReplication",
      command: "set_replication",
      run: () => setReplication("/bin", { backend: "proton", remote: null } satisfies ReplicationRequest),
    },
    { name: "clearReplication", command: "clear_replication", run: () => clearReplication("/bin") },
  ];

  for (const { name, command, run } of mutators) {
    it(`${name} invokes ${command} and re-renders cleanly with no banner on success`, async () => {
      mockInvoke(command, "resolve");
      await run();
      await waitFor(() => document.querySelector("#app")!.textContent!.includes("bmug2"));
      expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === command)).toBe(true);
      expect(document.querySelector(".run-banner")).toBeNull();
    });

    it(`${name} shows an error banner with the failure message when ${command} rejects`, async () => {
      mockInvoke(command, "reject");
      await run();
      await waitFor(() => document.querySelector(".run-banner") !== null);
      const banner = document.querySelector(".run-banner");
      expect(banner?.className).toBe("run-banner run-banner-error");
      expect(banner?.textContent).toContain(`${command} failed`);
    });
  }
});

describe("user journeys (install setup wizard)", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
  });

  const defaults: DefaultPaths = {
    sync_dir: "/home/alex/Backups/rsyncBackup",
    backup_dir: "/home/alex/Backups/rsyncBackup-BP",
    index_dir: "/home/alex/Backups/rsyncBackup/.locate.dir",
    install_dir: "/home/alex/usr/bmu",
  };

  // overrides[cmd] is either a value to resolve with, or an Error to
  // throw - lets each test only spell out the one or two commands it
  // actually cares about, same economy as the dashboard-mutator tests'
  // own mockInvoke above.
  function mockInstallFlow(overrides: Record<string, unknown> = {}) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd in overrides) {
        const value = overrides[cmd];
        if (value instanceof Error) throw value;
        return value;
      }
      switch (cmd) {
        case "get_default_paths":
          return defaults;
        case "find_existing_installs":
          return [] as string[];
        case "get_status":
          return { sync_dir: "/x", history_dir: "/x-BP", projects: [] } satisfies StatusResult;
        case "list_sources":
          return [] as BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  it("shows the new-install tab active by default, form pre-filled from get_default_paths", async () => {
    mockInstallFlow();
    await renderSetup();
    const tabs = document.querySelectorAll<HTMLButtonElement>(".tabs .tab");
    expect(tabs[0].classList.contains("active")).toBe(true);
    expect(tabs[1].classList.contains("active")).toBe(false);
    const inputs = document.querySelectorAll<HTMLInputElement>("form input[type=text]");
    expect(inputs[0].value).toBe(defaults.sync_dir);
    expect(inputs[3].value).toBe(defaults.install_dir);
  });

  it("wires a non-empty help tooltip onto every directory field, each naming its own CLI flag", async () => {
    mockInstallFlow();
    await renderSetup();

    const icons = document.querySelectorAll<HTMLElement>(".help-icon");
    expect(icons).toHaveLength(4);
    icons.forEach((icon) => {
      expect(icon.textContent).toBe("?");
      expect(icon.getAttribute("title")).toBeTruthy();
    });
    const titles = Array.from(icons).map((icon) => icon.getAttribute("title"));
    expect(titles.some((t) => t!.includes("--sync-dir="))).toBe(true);
    expect(titles.some((t) => t!.includes("--backup-dir="))).toBe(true);
    expect(titles.some((t) => t!.includes("--index-dir="))).toBe(true);
    expect(titles.some((t) => t!.includes("--install-dir="))).toBe(true);
  });

  it("IndexDB follows SYNC automatically until edited directly", async () => {
    mockInstallFlow();
    await renderSetup();
    const syncInput = document.querySelector<HTMLInputElement>("#sync-dir")!;
    const indexInput = document.querySelector<HTMLInputElement>("#index-dir")!;

    syncInput.value = "/custom/sync";
    syncInput.dispatchEvent(new Event("input"));
    expect(indexInput.value).toBe("/custom/sync/.locate.dir");

    // Typing into IndexDB directly detaches it - further SYNC edits
    // must not override what the user just chose.
    indexInput.value = "/elsewhere/fast-local-index";
    indexInput.dispatchEvent(new Event("input"));
    syncInput.value = "/another/sync";
    syncInput.dispatchEvent(new Event("input"));
    expect(indexInput.value).toBe("/elsewhere/fast-local-index");
  });

  it("picking IndexDB via Browse also detaches it from SYNC, not just typing", async () => {
    mockInstallFlow();
    await renderSetup();
    const syncInput = document.querySelector<HTMLInputElement>("#sync-dir")!;
    const indexInput = document.querySelector<HTMLInputElement>("#index-dir")!;
    const indexField = indexInput.closest(".field")!;

    vi.mocked(open).mockResolvedValueOnce("/picked/via-browse");
    indexField.querySelector<HTMLButtonElement>(".browse-btn")!.dispatchEvent(new Event("click"));
    await waitFor(() => indexInput.value === "/picked/via-browse");

    syncInput.value = "/another/sync";
    syncInput.dispatchEvent(new Event("input"));
    expect(indexInput.value).toBe("/picked/via-browse");
  });

  it("picking SYNC via Browse updates IndexDB while it is still attached", async () => {
    mockInstallFlow();
    await renderSetup();
    const syncInput = document.querySelector<HTMLInputElement>("#sync-dir")!;
    const indexInput = document.querySelector<HTMLInputElement>("#index-dir")!;
    const syncField = syncInput.closest(".field")!;

    vi.mocked(open).mockResolvedValueOnce("/browsed/sync");
    syncField.querySelector<HTMLButtonElement>(".browse-btn")!.dispatchEvent(new Event("click"));
    await waitFor(() => syncInput.value === "/browsed/sync");

    expect(indexInput.value).toBe("/browsed/sync/.locate.dir");
  });

  it("switching to the existing-install tab shows its own form instead", async () => {
    mockInstallFlow({ find_existing_installs: [] });
    await renderSetup();
    document.querySelectorAll<HTMLButtonElement>(".tabs .tab")[1].dispatchEvent(new Event("click"));

    // build() fully replaces the tabs on every re-render, so re-query
    // rather than reuse the (now-detached) button captured above.
    const [newTab, existingTab] = document.querySelectorAll<HTMLButtonElement>(".tabs .tab");
    expect(newTab.classList.contains("active")).toBe(false);
    expect(existingTab.classList.contains("active")).toBe(true);
    expect(document.querySelector("form input#bin-dir")).not.toBeNull();
    expect(document.querySelector("form input#sync-dir")).toBeNull();

    // Only one field here, and no CLI flag exists for "use an existing
    // install" (it's a GUI-only concept) - just a description, same as
    // helpIcon's own no-cliExample mode already supports.
    const icon = document.querySelector<HTMLElement>(".help-icon")!;
    expect(icon.getAttribute("title")).toContain("backmeup.setup.sh");
  });

  it("submitting the new-install form calls install_bmug2 with the typed paths and renders the dashboard on success", async () => {
    mockInstallFlow({
      install_bmug2: { bin_dir: "/home/alex/usr/bmu/bin", log: "" } satisfies InstallOutcome,
    });
    await renderSetup();
    const inputs = document.querySelectorAll<HTMLInputElement>("form input[type=text]");
    inputs[0].value = "/custom/sync";
    document.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));

    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "install_bmug2"));
    const [, args] = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === "install_bmug2")!;
    expect(args).toEqual({
      request: {
        mode: "new",
        sync_dir: "/custom/sync",
        backup_dir: defaults.backup_dir,
        index_dir: defaults.index_dir,
        install_dir: defaults.install_dir,
      },
    });
    // A fresh install has no sources yet - buildSourcesSection shows
    // this message instead of a table (see its own `sources.length ===
    // 0` branch), so that's the real marker a dashboard render landed.
    await waitFor(() => document.querySelector("#app")!.textContent!.includes("No backup sources yet"));
  });

  it("a failed new install renders the error screen, and Back returns to setup", async () => {
    mockInstallFlow({ install_bmug2: new Error("disk full") });
    await renderSetup();
    document.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));

    await waitFor(() => document.querySelector(".error-heading") !== null);
    expect(document.querySelector("pre")!.textContent).toBe("Error: disk full");

    buttonLabeled(document.body, "Back").dispatchEvent(new Event("click"));
    await waitFor(() => document.querySelector(".tabs") !== null);
  });

  it("existing-install suggestions are clickable and fill the bin-dir field", async () => {
    mockInstallFlow({ find_existing_installs: ["/home/alex/usr/bmu"] });
    await renderSetup();
    const [, existingTab] = document.querySelectorAll<HTMLButtonElement>(".tabs .tab");
    existingTab.dispatchEvent(new Event("click"));

    await waitFor(() => document.querySelector(".suggestion-btn") !== null);
    document.querySelector<HTMLButtonElement>(".suggestion-btn")!.dispatchEvent(new Event("click"));
    expect(document.querySelector<HTMLInputElement>("#bin-dir")!.value).toBe("/home/alex/usr/bmu");
  });

  it("an empty find_existing_installs result shows no suggestions, just the manual field", async () => {
    mockInstallFlow({ find_existing_installs: [] });
    await renderSetup();
    const [, existingTab] = document.querySelectorAll<HTMLButtonElement>(".tabs .tab");
    existingTab.dispatchEvent(new Event("click"));
    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "find_existing_installs"));
    expect(document.querySelector(".suggestion-btn")).toBeNull();
  });

  it("submitting the existing-install form with a typed path calls install_bmug2 with mode existing", async () => {
    mockInstallFlow({
      find_existing_installs: [],
      install_bmug2: { bin_dir: "/typed/bin", log: "" } satisfies InstallOutcome,
    });
    await renderSetup();
    const [, existingTab] = document.querySelectorAll<HTMLButtonElement>(".tabs .tab");
    existingTab.dispatchEvent(new Event("click"));
    document.querySelector<HTMLInputElement>("#bin-dir")!.value = "/typed/bin";
    document.querySelector("form")!.dispatchEvent(new Event("submit", { cancelable: true }));

    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "install_bmug2"));
    const [, args] = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === "install_bmug2")!;
    expect(args).toEqual({ request: { mode: "existing", bin_dir: "/typed/bin" } });
  });
});

describe("user journeys (Settings/update)", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
  });

  function mockSettingsFlow(overrides: Record<string, unknown> = {}) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd in overrides) {
        const value = overrides[cmd];
        if (value instanceof Error) throw value;
        return value;
      }
      switch (cmd) {
        case "get_status":
          return { sync_dir: "/x", history_dir: "/x-BP", projects: [] } satisfies StatusResult;
        case "list_sources":
          return [] as BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  const upToDate: UpdateCheck = { current: [2, 15, 0], latest: [2, 15, 0], update_available: false };
  const behind: UpdateCheck = { current: [2, 15, 0], latest: [2, 16, 0], update_available: true };

  it("shows up-to-date with no Update button when already current", async () => {
    mockSettingsFlow({ check_for_update: upToDate });
    await renderSettings("/bin");
    expect(document.querySelector(".settings-uptodate")).not.toBeNull();
    expect(Array.from(document.querySelectorAll("button")).some((b) => b.textContent === "Update now…")).toBe(
      false,
    );
  });

  it("offers Update now when behind, and shows an inline error (not a full error screen) when the check itself fails", async () => {
    mockSettingsFlow({ check_for_update: behind });
    await renderSettings("/bin");
    expect(buttonLabeled(document.body, "Update now…")).toBeTruthy();

    document.querySelector("#app")!.innerHTML = "";
    mockSettingsFlow({ check_for_update: new Error("offline") });
    await renderSettings("/bin");
    expect(document.querySelector(".settings-check-error")!.textContent).toContain("offline");
    expect(document.querySelector(".error-heading")).toBeNull();
  });

  it("Update now -> confirm -> apply_update success renders the dashboard with a success banner", async () => {
    mockSettingsFlow({
      check_for_update: behind,
      apply_update: { bin_dir: "/bin", log: "re-ran install.sh" } satisfies InstallOutcome,
    });
    await renderSettings("/bin");
    buttonLabeled(document.body, "Update now…").dispatchEvent(new Event("click"));
    expect(document.querySelector(".settings-confirm")).not.toBeNull();

    buttonLabeled(document.body, "Yes, install the update").dispatchEvent(new Event("click"));
    await waitFor(() => document.querySelector(".run-banner") !== null);
    const banner = document.querySelector(".run-banner");
    expect(banner?.className).toBe("run-banner run-banner-ok");
    expect(banner?.textContent).toContain("Updated successfully.");
  });

  it("Update now -> confirm -> apply_update failure renders the error screen", async () => {
    mockSettingsFlow({ check_for_update: behind, apply_update: new Error("network down") });
    await renderSettings("/bin");
    buttonLabeled(document.body, "Update now…").dispatchEvent(new Event("click"));
    buttonLabeled(document.body, "Yes, install the update").dispatchEvent(new Event("click"));

    await waitFor(() => document.querySelector(".error-heading") !== null);
    expect(document.querySelector("pre")!.textContent).toBe("Error: network down");
  });

  it("Cancel on the confirm screen returns to Settings without updating", async () => {
    mockSettingsFlow({ check_for_update: behind });
    await renderSettings("/bin");
    buttonLabeled(document.body, "Update now…").dispatchEvent(new Event("click"));
    buttonLabeled(document.body, "Cancel").dispatchEvent(new Event("click"));

    await waitFor(() => document.querySelector(".settings-version") !== null);
    expect(vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "apply_update")).toBe(false);
  });
});

describe("user journeys (app bootstrap: init)", () => {
  afterEach(() => {
    document.querySelector("#app")!.innerHTML = "";
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
  });

  function mockBootstrap(overrides: Record<string, unknown> = {}) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd in overrides) {
        const value = overrides[cmd];
        if (value instanceof Error) throw value;
        return value;
      }
      switch (cmd) {
        case "check_for_update":
          // Deliberately not cached here - init() treats a failed
          // background check as non-blocking either way.
          throw new Error("offline");
        case "get_status":
          return { sync_dir: "/x", history_dir: "/x-BP", projects: [] } satisfies StatusResult;
        case "list_sources":
          return [] as BackupSource[];
        case "get_housekeeping_schedule":
          return null;
        case "get_replication_status":
          return { backend: "off" } satisfies ReplicationStatus;
        case "get_replication_capability":
          return undefined;
        case "has_full_disk_access":
          return true;
        case "get_default_paths":
          return {
            sync_dir: "/x",
            backup_dir: "/x-BP",
            index_dir: "/x/.locate.dir",
            install_dir: "/usr/bmu",
          } satisfies DefaultPaths;
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  it("an existing install renders the dashboard", async () => {
    mockBootstrap({ check_existing_install: "/usr/bmu/bin" });
    await init();
    // No sources mocked - buildSourcesSection shows this instead of a
    // table (see its own `sources.length === 0` branch).
    await waitFor(() => document.querySelector("#app")!.textContent!.includes("No backup sources yet"));
  });

  it("no existing install renders the setup wizard", async () => {
    mockBootstrap({ check_existing_install: null });
    await init();
    await waitFor(() => document.querySelector(".tabs") !== null);
  });

  it("check_existing_install itself failing renders the error screen", async () => {
    mockBootstrap({ check_existing_install: new Error("permission denied") });
    await init();
    await waitFor(() => document.querySelector(".error-heading") !== null);
    expect(document.querySelector("pre")!.textContent).toBe("Error: permission denied");
  });
});

describe("buildReplicationSection", () => {
  it("off: shows a Set up button that reveals the (already-tested) editor", () => {
    const section = buildReplicationSection({ backend: "off" }, { ok: true }, "/bin");
    expect(section.textContent).toContain("Off");
    buttonLabeled(section, "Set up replication").dispatchEvent(new Event("click"));
    expect(section.querySelector("select")).not.toBeNull();
  });

  it("configured for rclone: shows both remotes and Edit/Turn off", () => {
    const status: ReplicationStatus = { backend: "rclone", remote_sync: "gdrive:a", remote_backups: "gdrive:b" };
    const section = buildReplicationSection(status, { ok: true }, "/bin");
    expect(section.textContent).toContain("rclone -> gdrive:a / gdrive:b");
    expect(() => buttonLabeled(section, "Edit")).not.toThrow();
    expect(() => buttonLabeled(section, "Turn off")).not.toThrow();
  });

  it("configured for Proton Drive: shows the HISTORY-only label", () => {
    const status: ReplicationStatus = { backend: "proton", remote: "/my-files/bmug2" };
    const section = buildReplicationSection(status, { ok: true }, "/bin");
    expect(section.textContent).toContain("Proton Drive (HISTORY only) -> /my-files/bmug2");
  });

  it("Turn off calls clear_replication for the right binDir", () => {
    vi.mocked(invoke).mockImplementation(pendingForever);
    const status: ReplicationStatus = { backend: "proton", remote: "/my-files/bmug2" };
    const section = buildReplicationSection(status, { ok: true }, "/the-bin-dir");
    buttonLabeled(section, "Turn off").dispatchEvent(new Event("click"));
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("clear_replication", { binDir: "/the-bin-dir" });
    vi.mocked(invoke).mockReset();
  });

  it("an unmet capability renders just the message, no controls", () => {
    const section = buildReplicationSection(
      { backend: "off" },
      { ok: false, message: "rclone/proton-drive not found on PATH" },
      "/bin",
    );
    expect(section.textContent).toContain("rclone/proton-drive not found on PATH");
    expect(section.querySelector("button")).toBeNull();
  });

  it("configured for local_path: shows both paths and Edit/Turn off", () => {
    const status: ReplicationStatus = {
      backend: "local_path",
      path_sync: "/cloud/SYNC",
      path_backups: "/cloud/BackUp",
    };
    const section = buildReplicationSection(status, { ok: true }, "/bin");
    expect(section.textContent).toContain("/cloud/SYNC");
    expect(section.textContent).toContain("/cloud/BackUp");
    expect(() => buttonLabeled(section, "Edit")).not.toThrow();
    expect(() => buttonLabeled(section, "Turn off")).not.toThrow();
  });
});

describe("buildProtonFolderBrowser", () => {
  afterEach(() => {
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
  });

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  function mockProton(overrides: Record<string, unknown> = {}) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd in overrides) {
        const value = overrides[cmd];
        if (value instanceof Error) throw value;
        return value;
      }
      switch (cmd) {
        case "proton_drive_signed_in":
          return true;
        case "list_proton_folder":
          return [] as RemoteEntry[];
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  it("not signed in: offers a sign-in button, and signing in re-renders loaded", async () => {
    mockProton({ proton_drive_signed_in: false });
    const browser = buildProtonFolderBrowser("/my-files", vi.fn(), vi.fn());
    await waitFor(() => browser.textContent!.includes("Not signed in"));

    mockProton({ proton_drive_login: undefined, list_proton_folder: [] as RemoteEntry[] });
    buttonLabeled(browser, "Sign in to Proton Drive…").dispatchEvent(new Event("click"));
    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "proton_drive_login"));
    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "list_proton_folder"));
  });

  it("signed in: lists folders only, descending into one re-fetches that path", async () => {
    mockProton({
      list_proton_folder: [
        { name: "Documents", is_folder: true },
        { name: "notes.txt", is_folder: false },
      ] satisfies RemoteEntry[],
    });
    const browser = buildProtonFolderBrowser("/my-files", vi.fn(), vi.fn());
    await waitFor(() => browser.querySelector(".remote-folder-list") !== null);

    expect(browser.textContent).toContain("Documents");
    expect(browser.textContent).not.toContain("notes.txt");

    mockProton({ list_proton_folder: [] as RemoteEntry[] });
    buttonLabeled(browser, "Documents").dispatchEvent(new Event("click"));
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(
        ([cmd, args]) => cmd === "list_proton_folder" && (args as { path: string }).path === "/my-files/Documents",
      ),
    );
  });

  it(`"Use" fires onChoose with the current path`, async () => {
    mockProton();
    const onChoose = vi.fn();
    const browser = buildProtonFolderBrowser("/my-files", onChoose, vi.fn());
    await waitFor(() => browser.querySelector(".remote-folder-list") !== null);
    buttonLabeled(browser, 'Use "/my-files"').dispatchEvent(new Event("click"));
    expect(onChoose).toHaveBeenCalledWith("/my-files");
  });

  it("creating a folder calls create_proton_folder then reloads the listing", async () => {
    mockProton();
    const browser = buildProtonFolderBrowser("/my-files", vi.fn(), vi.fn());
    await waitFor(() => browser.querySelector(".remote-folder-list") !== null);

    mockProton({ create_proton_folder: undefined, list_proton_folder: [] as RemoteEntry[] });
    browser.querySelector<HTMLInputElement>('input[placeholder="New folder name"]')!.value = "Archive";
    buttonLabeled(browser, "Create").dispatchEvent(new Event("click"));
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "create_proton_folder"),
    );
    const [, args] = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === "create_proton_folder")!;
    expect(args).toEqual({ parent: "/my-files", name: "Archive" });
  });

  it("a listing failure shows an inline error and Cancel", async () => {
    mockProton({ list_proton_folder: new Error("rpc timeout") });
    const onCancel = vi.fn();
    const browser = buildProtonFolderBrowser("/my-files", vi.fn(), onCancel);
    await waitFor(() => browser.querySelector(".settings-check-error") !== null);
    expect(browser.textContent).toContain("rpc timeout");
    buttonLabeled(browser, "Cancel").dispatchEvent(new Event("click"));
    expect(onCancel).toHaveBeenCalledOnce();
  });
});

describe("buildGoogleDriveFolderBrowser", () => {
  afterEach(() => {
    vi.mocked(invoke).mockReset();
    vi.mocked(invoke).mockImplementation(pendingForever);
  });

  async function waitFor(predicate: () => boolean, maxTicks = 50) {
    for (let i = 0; i < maxTicks && !predicate(); i++) {
      await Promise.resolve();
    }
    expect(predicate()).toBe(true);
  }

  function mockDrive(overrides: Record<string, unknown> = {}) {
    vi.mocked(invoke).mockImplementation(async (cmd: string) => {
      if (cmd in overrides) {
        const value = overrides[cmd];
        if (value instanceof Error) throw value;
        return value;
      }
      switch (cmd) {
        case "list_drive_remotes":
          return [] as string[];
        case "list_rclone_folder":
          return [] as RemoteEntry[];
        default:
          throw new Error(`unmocked invoke command in test: ${cmd}`);
      }
    });
  }

  it("no remotes: offers to connect, and connecting reloads remotes", async () => {
    mockDrive({ list_drive_remotes: [] as string[] });
    const browser = buildGoogleDriveFolderBrowser("", vi.fn(), vi.fn());
    await waitFor(() => browser.textContent!.includes("No Google Drive remote configured yet."));

    mockDrive({ create_drive_remote: undefined, list_drive_remotes: ["gdrive"] as string[] });
    buttonLabeled(browser, "Connect Google Drive…").dispatchEvent(new Event("click"));
    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "create_drive_remote"));
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "list_rclone_folder"),
    );
  });

  it("exactly one remote: auto-selected, no picker shown", async () => {
    mockDrive({ list_drive_remotes: ["gdrive"] as string[] });
    const browser = buildGoogleDriveFolderBrowser("", vi.fn(), vi.fn());
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(
        ([cmd, args]) => cmd === "list_rclone_folder" && (args as { path: string }).path === "gdrive:",
      ),
    );
    expect(browser.textContent).not.toContain("Choose a Google Drive remote");
  });

  it("multiple remotes with no matching startValue: shows a picker, picking one loads its folder", async () => {
    mockDrive({ list_drive_remotes: ["work", "personal"] as string[] });
    const browser = buildGoogleDriveFolderBrowser("", vi.fn(), vi.fn());
    await waitFor(() => browser.textContent!.includes("Choose a Google Drive remote"));

    mockDrive({ list_rclone_folder: [] as RemoteEntry[] });
    buttonLabeled(browser, "personal").dispatchEvent(new Event("click"));
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(
        ([cmd, args]) => cmd === "list_rclone_folder" && (args as { path: string }).path === "personal:",
      ),
    );
  });

  it("a startValue naming a known remote:path parses straight into that folder, no picker", async () => {
    mockDrive({ list_drive_remotes: ["work", "personal"] as string[], list_rclone_folder: [] as RemoteEntry[] });
    const browser = buildGoogleDriveFolderBrowser("work:Projects/bmug2", vi.fn(), vi.fn());
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(
        ([cmd, args]) => cmd === "list_rclone_folder" && (args as { path: string }).path === "work:Projects/bmug2",
      ),
    );
    expect(browser.textContent).not.toContain("Choose a Google Drive remote");
  });

  it(`folder navigation, "Use", and folder creation all target the selected remote`, async () => {
    mockDrive({
      list_drive_remotes: ["gdrive"] as string[],
      list_rclone_folder: [{ name: "Projects", is_folder: true }] satisfies RemoteEntry[],
    });
    const onChoose = vi.fn();
    const browser = buildGoogleDriveFolderBrowser("", onChoose, vi.fn());
    await waitFor(() => browser.querySelector(".remote-folder-list") !== null);

    mockDrive({ list_rclone_folder: [] as RemoteEntry[] });
    buttonLabeled(browser, "Projects").dispatchEvent(new Event("click"));
    await waitFor(() =>
      vi.mocked(invoke).mock.calls.some(
        ([cmd, args]) => cmd === "list_rclone_folder" && (args as { path: string }).path === "gdrive:Projects",
      ),
    );

    buttonLabeled(browser, 'Use "gdrive:Projects"').dispatchEvent(new Event("click"));
    expect(onChoose).toHaveBeenCalledWith("gdrive:Projects");

    mockDrive({ create_rclone_folder: undefined, list_rclone_folder: [] as RemoteEntry[] });
    browser.querySelector<HTMLInputElement>('input[placeholder="New folder name"]')!.value = "Archive";
    buttonLabeled(browser, "Create").dispatchEvent(new Event("click"));
    await waitFor(() => vi.mocked(invoke).mock.calls.some(([cmd]) => cmd === "create_rclone_folder"));
    const [, args] = vi.mocked(invoke).mock.calls.find(([cmd]) => cmd === "create_rclone_folder")!;
    expect(args).toEqual({ path: "gdrive:Projects/Archive" });
  });

  it("a listing failure shows an inline error and Cancel", async () => {
    mockDrive({ list_drive_remotes: ["gdrive"] as string[], list_rclone_folder: new Error("rpc timeout") });
    const onCancel = vi.fn();
    const browser = buildGoogleDriveFolderBrowser("", vi.fn(), onCancel);
    await waitFor(() => browser.querySelector(".settings-check-error") !== null);
    expect(browser.textContent).toContain("rpc timeout");
    buttonLabeled(browser, "Cancel").dispatchEvent(new Event("click"));
    expect(onCancel).toHaveBeenCalledOnce();
  });
});
