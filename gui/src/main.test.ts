import { describe, it, expect, vi, afterEach } from "vitest";
import { listen } from "@tauri-apps/api/event";
import {
  isDaily,
  el,
  formatKb,
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
  type Schedule,
  type StatusProject,
  type StatusResult,
  type BackupSource,
  type IgnoreSettings,
  type ReplicationStatus,
  type RunOutput,
  type RunBanner,
} from "./main";

// runJob awaits listen() before doing anything else observable from a test
// (see its own "listen before invoking" comment in main.ts), so it needs a
// resolved stand-in here regardless of which test exercises it.
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));

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
    const items = notice!.querySelectorAll("li");
    expect(items).toHaveLength(2);
    expect(items[0].textContent).toContain("docs");
    expect(items[1].textContent).toContain("photos");
    expect(notice!.querySelector("button")).not.toBeNull();
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
