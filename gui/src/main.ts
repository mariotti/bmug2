import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { openUrl, revealItemInDir } from "@tauri-apps/plugin-opener";

// First-run flow: check for a saved install, otherwise offer to
// install a new copy or point at an existing one. Wording below is
// ported from bin/backmeup.configure.sh's own prompts/tips, not
// reinvented - keep the two in sync if either changes.

export interface DefaultPaths {
  sync_dir: string;
  backup_dir: string;
  index_dir: string;
  install_dir: string;
}

export interface InstallOutcome {
  bin_dir: string;
  log: string;
}

// Mirrors install.rs's UpdateInfo exactly - a plain struct (not a
// tagged enum like ReplicationStatus/Request), so the tuple fields
// serialize as plain 3-element arrays. latest_stable/latest_experimental
// are only present (non-null) when newer than current.
export interface UpdateInfo {
  current: [number, number, number];
  latest_stable: string | null;
  latest_experimental: string | null;
}

export interface StatusProject {
  name: string;
  last_run: string | null;
  last_change: string | null;
  snapshot_count: number;
  mirror_size_kb: number;
  history_size_kb: number | null;
  old_layout: boolean;
}

export interface StatusResult {
  sync_dir: string;
  history_dir: string;
  projects: StatusProject[];
}

export interface LocateHit {
  path: string;
  source: string;
}

export interface LocateResult {
  patterns: string[];
  indexed: boolean;
  counts: { index: number; live: number; archived_filelist: number };
  results: LocateHit[];
}

// Mirrors config.rs's untagged Schedule enum exactly: Daily serializes
// as {hour, minute}, Interval as {minutes} - no "kind" wrapper key, so
// the two are told apart structurally, same as serde does on the Rust
// side.
export interface DailySchedule {
  hour: number;
  minute: number;
}
export interface IntervalSchedule {
  minutes: number;
}
export type Schedule = DailySchedule | IntervalSchedule;

export function isDaily(schedule: Schedule): schedule is DailySchedule {
  return "hour" in schedule;
}

export interface BackupSource {
  name: string;
  path: string;
  schedule: Schedule | null;
}

// Mirrors ignore.rs's IgnoreSettings/IgnoreSettingsInput exactly -
// gitignore/bmuignore respecting is per Backup Source, stored in
// HISTORY/<project>/.bmuconfig; bmuignore_content is the raw
// <source>/.bmuignore file content, same place a real .gitignore
// lives (see docs/EXAMPLES.md).
export interface IgnoreSettings {
  gitignore: boolean;
  gitignore_exists: boolean;
  bmuignore: boolean;
  bmuignore_content: string;
}

export interface IgnoreSettingsInput {
  gitignore: boolean;
  bmuignore: boolean;
  bmuignore_content: string;
}

// Mirrors replication.rs's ReplicationStatus/ReplicationRequest tagged
// enums exactly (#[serde(tag = "backend", rename_all = "snake_case")]).
export type ReplicationStatus =
  | { backend: "off" }
  | { backend: "rclone"; remote_sync: string; remote_backups: string }
  | { backend: "proton"; remote: string }
  | { backend: "local_path"; path_sync: string; path_backups: string };

export type ReplicationRequest =
  | { backend: "rclone"; remote_sync: string; remote_backups: string }
  | { backend: "proton"; remote: string | null }
  | { backend: "local_path"; path_sync: string; path_backups: string };

export type ReplicationCapability = { ok: true } | { ok: false; message: string };

export interface RunOutput {
  log: string;
  ok: boolean;
}

export interface RunBanner {
  ok: boolean;
  message: string;
  log?: string;
}

type InstallRequest =
  | ({ mode: "new" } & DefaultPaths)
  | { mode: "existing"; bin_dir: string };

const app = document.querySelector<HTMLElement>("#app")!;

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (Node | string)[] = [],
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const c of children) e.append(c);
  return e;
}

// A small circled "?" icon with a native tooltip bridging what the GUI just
// did to the real CLI command it wraps - for someone who also uses
// the CLI, or wants to understand/replicate a GUI action by hand.
// Native `title`, same pattern already used for the folder-path and
// old-layout-badge tooltips - no new overlay/widget idiom.
export function helpIcon(description: string, cliExample?: string): HTMLElement {
  const title = cliExample ? `${description}\n\nCLI equivalent:\n${cliExample}` : description;
  return el("span", { class: "help-icon", title }, ["?"]);
}

function renderLoading() {
  app.replaceChildren(el("p", {}, ["Loading…"]));
}

export function formatKb(kb: number | null): string {
  if (kb === null) return "-";
  if (kb >= 1024) return `${(kb / 1024).toFixed(1)} MB`;
  return `${kb} KB`;
}

// Last change, snapshot count, mirror/history size: the four fields
// every per-project status view needs, whether that's a tracked
// Backup Source's own row or the untracked-projects fallback table
// below - extracted once so both render identically and stay in sync.
// `known` is undefined when a source has never produced a status
// entry at all (e.g. its first backup hasn't run yet) - every cell
// renders "-" in that case, distinct from a real recorded 0.
export function buildProjectStatsCells(known: StatusProject | undefined): HTMLElement[] {
  return [
    el("td", {}, [known?.last_change ?? "-"]),
    el("td", {}, [known ? String(known.snapshot_count) : "-"]),
    el("td", {}, [formatKb(known?.mirror_size_kb ?? null)]),
    el("td", {}, [formatKb(known?.history_size_kb ?? null)]),
  ];
}

export function formatSchedule(schedule: Schedule): string {
  if (isDaily(schedule)) {
    return `Daily at ${String(schedule.hour).padStart(2, "0")}:${String(schedule.minute).padStart(2, "0")}`;
  }
  return `Every ${schedule.minutes} minutes`;
}

export function timeInputValue(schedule: DailySchedule): string {
  return `${String(schedule.hour).padStart(2, "0")}:${String(schedule.minute).padStart(2, "0")}`;
}

export function parseTimeInput(value: string): DailySchedule | null {
  const match = /^(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  return { hour: Number(match[1]), minute: Number(match[2]) };
}

// The exact intervals the "thesis writer" use case names (see
// docs/EXAMPLES.md) - a fixed choice rather than a free-form number
// input, since those are the granularities that make sense for most
// folder sizes. A too-short interval just means backmeup.sh's own
// per-project lock skips more overlapping firings, not corruption.
const INTERVAL_OPTIONS_MINUTES = [5, 10, 30, 60];

// Shared by both the per-source and Housekeeping schedule editors - a
// kind selector (Daily / Every N minutes) toggling between the
// existing <input type="time"> and a preset interval <select>, plus
// Save/Cancel. Returns the editor element; onSave receives whichever
// Schedule shape the user picked.
export function buildScheduleEditor(
  current: Schedule | null,
  onSave: (schedule: Schedule) => void,
  onCancel: () => void,
): HTMLElement {
  const startAsInterval = current !== null && !isDaily(current);

  const kindSelect = el("select", {}) as HTMLSelectElement;
  kindSelect.append(
    new Option("Daily at a time", "daily", !startAsInterval, !startAsInterval),
    new Option("Every N minutes", "interval", startAsInterval, startAsInterval),
  );

  const timeInput = el("input", {
    type: "time",
    value: current && isDaily(current) ? timeInputValue(current) : "02:00",
  }) as HTMLInputElement;

  const currentMinutes = current && !isDaily(current) ? current.minutes : 30;
  const intervalSelect = el("select", {}) as HTMLSelectElement;
  for (const minutes of INTERVAL_OPTIONS_MINUTES) {
    const selected = minutes === currentMinutes;
    intervalSelect.append(new Option(`${minutes} minutes`, String(minutes), selected, selected));
  }

  const updateVisibility = () => {
    const daily = kindSelect.value === "daily";
    timeInput.style.display = daily ? "" : "none";
    intervalSelect.style.display = daily ? "none" : "";
  };
  updateVisibility();
  kindSelect.addEventListener("change", updateVisibility);

  const saveBtn = el("button", { type: "button" }, ["Save"]);
  const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
  saveBtn.addEventListener("click", () => {
    if (kindSelect.value === "daily") {
      const parsed = parseTimeInput(timeInput.value);
      if (!parsed) return;
      onSave(parsed);
    } else {
      onSave({ minutes: Number(intervalSelect.value) });
    }
  });
  cancelBtn.addEventListener("click", onCancel);

  return el("span", { class: "schedule-edit" }, [
    kindSelect,
    timeInput,
    intervalSelect,
    saveBtn,
    cancelBtn,
  ]);
}

// Always-visible per-source toggles (a source's "options" line) - each
// fires immediately on change rather than needing a separate Save,
// matching how the schedule Off/On state is already just live status,
// not something you save. onToggle receives the one field that
// changed; the caller merges it with the source's other current
// settings before persisting.
export function buildIgnoreToggles(
  current: IgnoreSettings,
  onToggle: (field: "gitignore" | "bmuignore", value: boolean) => void,
): HTMLElement {
  const gitignoreCheck = el("input", { type: "checkbox" }) as HTMLInputElement;
  gitignoreCheck.checked = current.gitignore;
  gitignoreCheck.addEventListener("change", () => onToggle("gitignore", gitignoreCheck.checked));

  const bmuignoreCheck = el("input", { type: "checkbox" }) as HTMLInputElement;
  bmuignoreCheck.checked = current.bmuignore;
  bmuignoreCheck.addEventListener("change", () => onToggle("bmuignore", bmuignoreCheck.checked));

  return el("div", { class: "source-toggles" }, [
    el("label", {}, [
      gitignoreCheck,
      current.gitignore_exists
        ? " Respect .gitignore "
        : " Respect .gitignore (not present in this folder) ",
      helpIcon(
        "On by default - files your project's own .gitignore excludes never reach the mirror.",
        'echo \'BMU_GITIGNORE="no"\' > HISTORY/<project>/.bmuconfig',
      ),
    ]),
    el("label", {}, [
      bmuignoreCheck,
      " Use .bmuignore ",
      helpIcon(
        "Off by default - an extra, backup-specific exclude list on top of .gitignore.",
        'echo \'BMU_BMUIGNORE="yes"\' > HISTORY/<project>/.bmuconfig',
      ),
    ]),
  ]);
}

// A plain textarea over the raw .bmuignore file, one pattern per line -
// deliberately not a filesystem browser/picker, just an honest editor
// over what rsync's own dir-merge filter will read (see
// docs/EXAMPLES.md for the exact syntax and its one real gotcha:
// rsync's filter language doesn't treat a real .gitignore's `!`
// negation lines the way git does). Only the pattern text itself is
// edited here - respecting/consulting it at all is the toggles above.
export function buildBmuignoreEditor(
  content: string,
  onSave: (content: string) => void,
  onCancel: () => void,
): HTMLElement {
  const textarea = el("textarea", {
    rows: "6",
    placeholder: "one pattern per line, e.g. node_modules/",
  }) as HTMLTextAreaElement;
  textarea.value = content;

  const saveBtn = el("button", { type: "button" }, ["Save"]);
  const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
  saveBtn.addEventListener("click", () => onSave(textarea.value));
  cancelBtn.addEventListener("click", onCancel);

  return el("div", { class: "ignore-edit" }, [textarea, el("div", {}, [saveBtn, cancelBtn])]);
}

// bmug2 itself has no memory of "which folders to back up" -
// backmeup.sh takes a directory argument each call and doesn't
// persist it, and get_status only reports projects already backed up
// at least once (by name, scanned from SYNC), with no record of their
// original source path. This section is the GUI's own tracked list
// (list_sources/add_source/remove_source), cross-referenced against
// status.projects by name for a "last run" display when available.
// Each row's own Schedule cell installs a real per-source launchd/
// systemd-timer entry via set_source_schedule/clear_source_schedule.
// backmeup.sh itself now refuses a second overlapping run of the same
// project (a per-project lock - see docs/MANUAL.md's Troubleshooting
// entry), so two triggers hitting the *same* source just means one of
// them cleanly fails instead of corrupting a snapshot. Different
// sources' schedules landing close together is a separate thing that
// isn't auto-solved, just made visible (see the summary line below the
// table) so the user can self-stagger like a shell user would with a
// crontab.
// A project can already exist in `status.projects` (backed up for
// real, via the CLI or a bmug2 install that predates Backup Sources)
// without ever having been added here - bmug2 has no record of a
// project's original source path, so the GUI can't auto-fill it and
// has to ask once. old_layout projects are excluded: backmeup.sh
// refuses to run against them until backmeup.migrate.sh is run first
// (CLI-only, no GUI action for it), so offering to track and Run Now
// them here would just set up a source whose every run fails.
export function findUntrackedProjects(
  status: StatusResult,
  sources: BackupSource[],
): StatusProject[] {
  return status.projects.filter(
    (p) => !p.old_layout && !sources.some((s) => s.name === p.name),
  );
}

export function buildUntrackedProjectsNotice(
  untracked: StatusProject[],
  binDir: string,
): HTMLElement | null {
  if (untracked.length === 0) return null;
  const rows = untracked.map((project) => {
    const locateBtn = el("button", { type: "button" }, ["Locate folder…"]);
    locateBtn.addEventListener("click", () => void linkExistingProject(binDir, project));
    return el("tr", {}, [
      el("td", {}, [project.name]),
      el("td", {}, [project.last_run ?? "-"]),
      ...buildProjectStatsCells(project),
      el("td", {}, [locateBtn]),
    ]);
  });
  // Reuses .status-table - free the moment the old standalone status
  // section is gone, and already styled compactly, matching the
  // "small fallback, not a full duplicate table" intent: no
  // Folder/Schedule columns, since those are source-specific concepts
  // that don't exist yet for a project with no tracked source.
  const table = el("table", { class: "status-table" }, [
    el("thead", {}, [
      el("tr", {}, [
        el("th", {}, ["Project"]),
        el("th", {}, ["Last run"]),
        el("th", {}, ["Last change"]),
        el("th", {}, ["Snapshots"]),
        el("th", {}, ["Mirror"]),
        el("th", {}, ["History"]),
        el("th", {}, [""]),
      ]),
    ]),
    el("tbody", {}, rows),
  ]);
  return el("div", { class: "untracked-notice" }, [
    el("p", {}, [
      `Already backed up but not tracked here yet - point each at its source folder to get Run Now and scheduling for it:`,
    ]),
    table,
  ]);
}

export function formatVersion([major, minor, patch]: [number, number, number]): string {
  return `${major}.${minor}.${patch}`;
}

// Same box/button idiom as buildUntrackedProjectsNotice (computed-from-
// state, shown unconditionally when relevant, inline action button) -
// not buildRunBanner's shape, since this must appear on a normal page
// load with no preceding action.
export function buildUpdateAvailableNotice(info: UpdateInfo, binDir: string): HTMLElement | null {
  if (!info.latest_stable && !info.latest_experimental) return null;
  const goBtn = el("button", { type: "button" }, ["Go to Settings"]);
  goBtn.addEventListener("click", () => void renderSettings(binDir));
  const available = info.latest_stable ?? info.latest_experimental!;
  return el("div", { class: "untracked-notice update-notice" }, [
    el("p", {}, [
      `bmug2 ${available} is available (you have ${formatVersion(info.current)}). `,
      goBtn,
    ]),
  ]);
}

async function linkExistingProject(binDir: string, project: StatusProject) {
  const selected = await open({ directory: true });
  if (typeof selected !== "string") return;
  try {
    await invoke("add_source", { path: selected, name: project.name });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

// Each source renders as three lines - info, then always-on option
// toggles, then commands - plus two rows that only appear once you
// click into them (the schedule editor, the .bmuignore text editor).
// Table columns still apply to the info line (four things worth
// scanning across sources at a glance); the rest are full-width rows
// under it, same colspan-row trick already used for the expandable
// editors themselves.
function buildSourcesSection(
  sources: BackupSource[],
  status: StatusResult,
  ignoreSettings: Map<string, IgnoreSettings>,
  binDir: string,
): HTMLElement {
  const addBtn = el("button", { type: "button" }, ["+ Add folder"]);
  addBtn.addEventListener("click", () => void addSource(binDir));

  const header = el("div", { class: "sources-header" }, [
    el("h2", {}, [
      "Backup sources ",
      helpIcon(
        "The GUI's own list of folders to back up - backmeup.sh itself doesn't remember this between runs.",
        "backmeup.sh ~/Documents",
      ),
    ]),
    addBtn,
  ]);

  const untracked = findUntrackedProjects(status, sources);
  const notice = buildUntrackedProjectsNotice(untracked, binDir);

  if (sources.length === 0) {
    return el("section", {}, [
      header,
      ...(notice ? [notice] : []),
      el("p", {}, ["No backup sources yet — add a folder to get started."]),
    ]);
  }

  const rows: HTMLElement[] = [];
  sources.forEach((source, sourceIndex) => {
    // Each source spans several rows (info, options, commands, and up
    // to two more once an editor is opened) - without a shared visual
    // cue tying them together, a multi-source list reads as one flat
    // stack of near-identical lines rather than distinct groups.
    // Alternating shading per source (not per row) plus a border above
    // each group's first row makes the boundaries obvious at a glance.
    const groupClass = sourceIndex % 2 === 0 ? "source-group-even" : "source-group-odd";
    const known = status.projects.find((p) => p.name === source.name);
    const settings = ignoreSettings.get(source.path);

    const runBtn = el("button", { type: "button", class: "job-trigger-btn" }, ["Run now"]);
    const runLogEl = el("pre", { class: "log" }, []);
    const runRow = el("tr", { class: `schedule-edit-row ${groupClass}` }, [
      el("td", { colspan: "8" }, [runLogEl]),
    ]);
    runRow.style.display = "none";
    runBtn.addEventListener("click", () => void runBackupNow(binDir, source, runBtn, runRow, runLogEl));
    // Removing a source drops its schedule and ignore settings with no
    // undo - unlike "Turn off" (just clears a schedule, trivially
    // re-set), worth a second click rather than one accidental one.
    // No modal/overlay idiom exists anywhere in this app (see
    // renderSettings's own comment on that), so this is a plain
    // in-place button-state swap, not a dialog.
    const removeBtn = el("button", { type: "button", class: "remove-btn" }, ["Remove"]);
    const removeCancelBtn = el("button", { type: "button", class: "remove-cancel-btn" }, ["Cancel"]);
    removeCancelBtn.style.display = "none";
    removeBtn.addEventListener("click", () => {
      if (removeBtn.textContent === "Remove") {
        removeBtn.textContent = "Really remove?";
        removeCancelBtn.style.display = "";
        return;
      }
      void removeSource(binDir, source);
    });
    removeCancelBtn.addEventListener("click", () => {
      removeBtn.textContent = "Remove";
      removeCancelBtn.style.display = "none";
    });

    const scheduleRow = el("tr", { class: `schedule-edit-row ${groupClass}` }, []);
    scheduleRow.style.display = "none";
    const showScheduleRow = () => {
      const editor = buildScheduleEditor(
        source.schedule,
        (schedule) => void setSourceSchedule(binDir, source, schedule),
        () => {
          scheduleRow.style.display = "none";
        },
      );
      scheduleRow.replaceChildren(el("td", { colspan: "8" }, [editor]));
      scheduleRow.style.display = "";
    };
    const scheduleBtn = source.schedule
      ? el("button", { type: "button" }, ["Edit schedule"])
      : el("button", { type: "button" }, ["Set schedule"]);
    scheduleBtn.addEventListener("click", showScheduleRow);
    const commandBtns = [runBtn, scheduleBtn];
    if (source.schedule) {
      const offBtn = el("button", { type: "button", class: "remove-btn" }, ["Turn off"]);
      offBtn.addEventListener("click", () => void clearSourceSchedule(binDir, source));
      commandBtns.push(offBtn);
    }

    const bmuignoreRow = el("tr", { class: `schedule-edit-row ${groupClass}` }, []);
    bmuignoreRow.style.display = "none";
    const bmuignoreBtn = el("button", { type: "button" }, ["Edit .bmuignore"]);
    if (settings) {
      bmuignoreBtn.addEventListener("click", () => {
        const editor = buildBmuignoreEditor(
          settings.bmuignore_content,
          (content) => void saveIgnoreSettings(binDir, source, { ...settings, bmuignore_content: content }),
          () => {
            bmuignoreRow.style.display = "none";
          },
        );
        bmuignoreRow.replaceChildren(el("td", { colspan: "8" }, [editor]));
        bmuignoreRow.style.display = "";
      });
    }
    commandBtns.push(bmuignoreBtn, removeBtn, removeCancelBtn);

    const togglesRow = el("tr", { class: `schedule-edit-row ${groupClass}` }, []);
    if (settings) {
      const toggles = buildIgnoreToggles(settings, (field, value) =>
        void saveIgnoreSettings(binDir, source, { ...settings, [field]: value }),
      );
      togglesRow.replaceChildren(el("td", { colspan: "8" }, [toggles]));
    }

    // A tracked source whose underlying project still has the old
    // pre-migration layout: visible by default (not behind a toggle,
    // unlike the editor rows above) since this is a data-integrity
    // warning, not something opened on demand. Reuses the exact
    // wording the old standalone status table showed.
    const oldLayoutRow = known?.old_layout
      ? el("tr", { class: groupClass }, [
          el("td", { colspan: "8", class: "note-old-layout" }, [
            `${source.name}: old layout, run backmeup.migrate.sh ${source.name} on the command line.`,
          ]),
        ])
      : null;

    rows.push(
      el("tr", { class: `source-info-row ${groupClass}` }, [
        el("td", {}, [
          known?.old_layout
            ? el(
                "span",
                { class: "badge-old-layout", title: "Old pre-migration layout - see the note below" },
                ["⚠"],
              )
            : "",
          el("strong", {}, [source.name]),
        ]),
        el("td", {}, [el("code", { class: "source-folder-path", title: source.path }, [source.path])]),
        el("td", {}, [source.schedule ? formatSchedule(source.schedule) : "Off"]),
        el("td", {}, [known?.last_run ?? "never run yet"]),
        ...buildProjectStatsCells(known),
      ]),
      ...(oldLayoutRow ? [oldLayoutRow] : []),
      togglesRow,
      el("tr", { class: groupClass }, [
        el("td", { class: "source-commands", colspan: "8" }, commandBtns),
      ]),
      scheduleRow,
      bmuignoreRow,
      runRow,
    );
  });

  const table = el("table", { class: "sources-table" }, [
    el("thead", {}, [
      el("tr", {}, [
        el("th", {}, ["Name"]),
        el("th", {}, ["Folder"]),
        el("th", {}, [
          "Schedule ",
          helpIcon(
            "Installs a real launchd (macOS) or systemd timer (Linux) that runs this on its own.",
            "0 2 * * * ~/usr/bmu/bin/backmeup.sh ~/Documents   # crontab -e",
          ),
        ]),
        el("th", {}, ["Last run"]),
        el("th", {}, [
          "Last change ",
          helpIcon("The same numbers `bmu status` reports, per project.", "backmeup.status.sh"),
        ]),
        el("th", {}, ["Snapshots"]),
        el("th", {}, ["Mirror"]),
        el("th", {}, ["History"]),
      ]),
    ]),
    el("tbody", {}, rows),
  ]);

  const scheduled = sources.filter((s) => s.schedule);
  const summary =
    scheduled.length > 0
      ? el("p", { class: "schedule-summary" }, [
          `Already scheduled: ${scheduled
            .map((s) => `${s.name} (${formatSchedule(s.schedule!)})`)
            .join(", ")}.`,
        ])
      : "";

  return el("section", {}, [header, ...(notice ? [notice] : []), table, summary]);
}

export async function setSourceSchedule(binDir: string, source: BackupSource, schedule: Schedule) {
  try {
    await invoke("set_source_schedule", { binDir, sourcePath: source.path, schedule });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

export async function clearSourceSchedule(binDir: string, source: BackupSource) {
  try {
    await invoke("clear_source_schedule", { sourcePath: source.path });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

export async function saveIgnoreSettings(binDir: string, source: BackupSource, settings: IgnoreSettingsInput) {
  try {
    await invoke("set_ignore_settings", { binDir, sourcePath: source.path, settings });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

async function addSource(binDir: string) {
  const selected = await open({ directory: true });
  if (typeof selected !== "string") return;
  let source: BackupSource;
  try {
    source = await invoke<BackupSource>("add_source", { path: selected, name: null });
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
    return;
  }
  // A freshly added source has never been backed up - run it
  // immediately instead of leaving a new, empty-looking entry that
  // needs a separate manual Run Now click to actually start protecting
  // anything. Plain full-screen flow here, not runJob's inline per-row
  // progress - there's no existing row to attach to yet, since the
  // source was only just created and the dashboard hasn't rendered it.
  renderInstalling(`Running backup for ${source.name}…`);
  try {
    const result = await invoke<RunOutput>("run_backup_now", { binDir, sourcePath: source.path });
    void renderDashboard(binDir, {
      ok: result.ok,
      message: result.ok ? `Backup for ${source.name} completed.` : `Backup for ${source.name} failed.`,
      log: result.ok ? undefined : result.log,
    });
  } catch (err) {
    void renderDashboard(binDir, {
      ok: false,
      message: `Backup for ${source.name} failed.`,
      log: String(err),
    });
  }
}

export async function removeSource(binDir: string, source: BackupSource) {
  try {
    await invoke("remove_source", { path: source.path });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

// Shared by every "Run Now"/"Run now"-style action: keeps the
// dashboard visible instead of taking over the whole screen (the
// previous renderInstalling/renderRunningLog-based approach - a large
// or first run of any of these can take a long time, and a static
// full-screen message is indistinguishable from a hang). Disables
// every other .job-trigger-btn while this one runs - jobs stay
// serialized (only one at a time, dashboard-wide) on purpose: none of
// backmeup.replicate.sh/backmeup.updatedb.sh take a lock, so letting
// two jobs actually run concurrently risks reading a file mid-write by
// a still-running backup. True concurrency needs that locking gap
// closed first, in its own change - this only changes how a single,
// still-serialized job is *presented*. renderDashboard rebuilds every
// button fresh regardless of outcome, so nothing needs to be manually
// re-enabled/restored here either way.
export async function runJob(
  binDir: string,
  trigger: HTMLButtonElement,
  row: HTMLElement,
  logEl: HTMLElement,
  eventName: string,
  invokeJob: () => Promise<RunOutput>,
  messages: { ok: string; fail: string },
) {
  const allTriggers = Array.from(app.querySelectorAll<HTMLButtonElement>(".job-trigger-btn"));
  allTriggers.forEach((b) => (b.disabled = true));
  trigger.replaceChildren(el("span", { class: "spinner" }, []), "Running…");
  logEl.textContent = "";
  row.style.display = "";

  // Listen before invoking, so a line emitted right at the start can
  // never arrive before anything is listening for it.
  const unlisten = await listen<string>(eventName, (event) => {
    logEl.textContent += event.payload + "\n";
    logEl.scrollTop = logEl.scrollHeight;
  });
  try {
    const result = await invokeJob();
    void renderDashboard(binDir, {
      ok: result.ok,
      message: result.ok ? messages.ok : messages.fail,
      log: result.ok ? undefined : result.log,
    });
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: messages.fail, log: String(err) });
  } finally {
    void unlisten();
  }
}

async function runBackupNow(
  binDir: string,
  source: BackupSource,
  trigger: HTMLButtonElement,
  row: HTMLElement,
  logEl: HTMLElement,
) {
  await runJob(
    binDir,
    trigger,
    row,
    logEl,
    "backup-progress",
    () => invoke<RunOutput>("run_backup_now", { binDir, sourcePath: source.path }),
    { ok: `Backup for ${source.name} completed.`, fail: `Backup for ${source.name} failed.` },
  );
}

async function runHousekeepingNow(binDir: string, trigger: HTMLButtonElement, row: HTMLElement, logEl: HTMLElement) {
  await runJob(
    binDir,
    trigger,
    row,
    logEl,
    "housekeeping-progress",
    () => invoke<RunOutput>("run_housekeeping_now", { binDir }),
    { ok: "Housekeeping completed.", fail: "Housekeeping failed." },
  );
}

function buildSearchSection(binDir: string): HTMLElement {
  const [searchField, searchInput] = field(
    "Search (space-separated patterns)",
    "search-patterns",
    "",
  );
  const submit = el("button", { type: "submit" }, ["Search"]);
  const resultsBox = el("div", { class: "search-results" }, []);

  const form = el("form", { class: "search-form" }, [searchField, submit]);
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const patterns = searchInput.value.trim().split(/\s+/).filter(Boolean);
    if (patterns.length === 0) return;
    void runSearch(binDir, patterns, resultsBox);
  });

  return el("section", {}, [
    el("h2", {}, [
      "Search ",
      helpIcon(
        "Checks the locate index first, then falls back to live/archived filelists for anything too new to be indexed yet.",
        "backmeup.locate.sh report.pdf",
      ),
    ]),
    form,
    resultsBox,
  ]);
}

export async function runSearch(
  binDir: string,
  patterns: string[],
  resultsBox: HTMLElement,
) {
  resultsBox.replaceChildren(el("p", {}, ["Searching…"]));
  try {
    const result = await invoke<LocateResult>("search", { binDir, patterns });
    renderSearchResults(result, resultsBox);
  } catch (err) {
    resultsBox.replaceChildren(el("p", { class: "error-heading" }, [String(err)]));
  }
}

// "index"/"live" pass through as-is; anything else (today just
// "archived_filelist") is display-shortened to "archived" - matches
// the source-tag CSS class name (source-${hit.source}) staying the
// raw backend value, only the visible label gets the friendlier text.
export function sourceLabel(source: string): string {
  if (source === "index" || source === "live") return source;
  return "archived";
}

// One row per hit: the source tag + path, same as before, plus a
// Reveal control (revealItemInDir, @tauri-apps/plugin-opener - already
// a dependency, already permitted by opener:default in
// capabilities/*.json, cross-platform: Finder/NSWorkspace on macOS,
// Explorer on Windows, the FileManager1 D-Bus interface or the
// OpenURI portal on Linux). A plain function (not inline in .map), so
// each row gets its own error-message element to reveal a stale
// result cleanly (e.g. an archived snapshot path since pruned)
// instead of silently doing nothing.
function buildSearchResultRow(hit: LocateHit): HTMLElement {
  const revealBtn = el("button", { type: "button", class: "reveal-btn" }, ["Reveal"]);
  const errorMsg = el("span", { class: "reveal-error" }, []);
  revealBtn.addEventListener("click", () => {
    errorMsg.textContent = "";
    revealItemInDir(hit.path).catch((err) => {
      // Real bug, found by the user: a stale result (its file has
      // since moved or been deleted, e.g. a build-output dir
      // regenerated after the index was last refreshed) rejected with
      // a bare OS errno string and no context. Every reveal failure
      // reasonably means "this path isn't there anymore" - wrap it
      // once, generically, rather than guessing at OS-specific error
      // wording across platforms.
      errorMsg.textContent = ` This file is no longer there (the search index can be behind the last backup run): ${String(err)}`;
    });
  });
  return el("li", {}, [
    el("span", { class: `source-tag source-${hit.source}` }, [sourceLabel(hit.source)]),
    `${hit.path} `,
    revealBtn,
    errorMsg,
  ]);
}

// The CLI always returns the complete result set in one response (see
// backmeup.locate.sh's own "never silently truncate" contract) - an
// unselective pattern can still mean thousands of hits, too many to
// render as DOM rows at once without real jank, so pagination lives
// entirely here, slicing the array already in memory. No re-fetch
// between pages, unlike a server-side "page 2" would need.
const SEARCH_PAGE_SIZE = 100;

function renderSearchResultsPage(result: LocateResult, resultsBox: HTMLElement, page: number) {
  const children: (Node | string)[] = [];
  if (!result.indexed) {
    children.push(
      el("p", { class: "note-not-indexed" }, [
        "No locate installed — results are from live and archived filelists only.",
      ]),
    );
  }
  if (result.results.length === 0) {
    children.push(el("p", {}, ["No matches."]));
  } else {
    const totalPages = Math.ceil(result.results.length / SEARCH_PAGE_SIZE);
    const start = (page - 1) * SEARCH_PAGE_SIZE;
    const pageHits = result.results.slice(start, start + SEARCH_PAGE_SIZE);
    children.push(el("ul", { class: "search-result-list" }, pageHits.map(buildSearchResultRow)));
    if (totalPages > 1) {
      const prevBtn = el("button", { type: "button", class: "search-page-prev" }, ["Previous"]);
      const nextBtn = el("button", { type: "button", class: "search-page-next" }, ["Next"]);
      prevBtn.disabled = page <= 1;
      nextBtn.disabled = page >= totalPages;
      prevBtn.addEventListener("click", () => renderSearchResultsPage(result, resultsBox, page - 1));
      nextBtn.addEventListener("click", () => renderSearchResultsPage(result, resultsBox, page + 1));
      children.push(
        el("p", { class: "search-pagination" }, [
          prevBtn,
          ` Page ${page} of ${totalPages} (${result.results.length} total matches) `,
          nextBtn,
        ]),
      );
    }
  }
  resultsBox.replaceChildren(...children);
}

export function renderSearchResults(result: LocateResult, resultsBox: HTMLElement) {
  renderSearchResultsPage(result, resultsBox, 1);
}

export async function renderDashboard(binDir: string, banner?: RunBanner) {
  app.replaceChildren(el("h1", {}, ["bmug2"]), el("p", {}, ["Loading status…"]));
  let status: StatusResult;
  let sources: BackupSource[];
  let housekeeping: Schedule | null;
  let ignoreSettings: Map<string, IgnoreSettings>;
  let replicationStatus: ReplicationStatus;
  let replicationCapability: ReplicationCapability;
  try {
    status = await invoke<StatusResult>("get_status", { binDir });
    sources = await invoke<BackupSource[]>("list_sources");
    housekeeping = await invoke<Schedule | null>("get_housekeeping_schedule");
    // Fetched eagerly, one per source, so the always-visible option
    // toggles have real state to show on first render rather than a
    // loading flicker per row.
    const pairs = await Promise.all(
      sources.map(
        async (s): Promise<[string, IgnoreSettings]> => [
          s.path,
          await invoke<IgnoreSettings>("get_ignore_settings", { binDir, sourcePath: s.path }),
        ],
      ),
    );
    ignoreSettings = new Map(pairs);
    replicationStatus = await invoke<ReplicationStatus>("get_replication_status", { binDir });
    // Unlike every other fetch above, an old install is an *expected*,
    // non-fatal outcome here (replication settings predate this - see
    // replication.rs's own version-gate reasoning) - caught locally so
    // it disables just this one section instead of the whole dashboard.
    try {
      await invoke("get_replication_capability", { binDir });
      replicationCapability = { ok: true };
    } catch (err) {
      replicationCapability = { ok: false, message: String(err) };
    }
  } catch (err) {
    renderError(String(err), () => void renderDashboard(binDir));
    return;
  }
  // Defaults to "show the warning" (false) if the check itself fails -
  // a false "might need it" is harmless, a false "you're fine" would
  // hide a real gotcha.
  const hasFullDiskAccess = await invoke<boolean>("has_full_disk_access").catch(() => false);
  const children: (Node | string)[] = [el("h1", {}, ["bmug2"])];
  const settingsBtn = el("button", { type: "button" }, ["Settings"]);
  settingsBtn.addEventListener("click", () => void renderSettings(binDir));
  children.push(el("div", { class: "dashboard-top-bar" }, [settingsBtn]));

  if (banner) children.push(buildRunBanner(banner));
  // Reads the session cache populated once in init() - never a fresh
  // invoke here, see cachedUpdateCheck's own comment for why.
  if (cachedUpdateCheck) {
    const notice = buildUpdateAvailableNotice(cachedUpdateCheck, binDir);
    if (notice) children.push(notice);
  }
  // Global, not per-project - these lived inside the old standalone
  // status section; moved here now that per-project stats live on
  // each source's own row instead.
  const refreshBtn = el("button", { type: "button" }, ["Refresh"]);
  refreshBtn.addEventListener("click", () => void renderDashboard(binDir));
  children.push(
    el("div", { class: "dashboard-header" }, [
      el("p", {}, [el("strong", {}, ["SYNC: "]), el("code", {}, [status.sync_dir])]),
      el("p", {}, [el("strong", {}, ["HISTORY: "]), el("code", {}, [status.history_dir])]),
      refreshBtn,
    ]),
  );
  const scheduleInfoPanel = buildScheduleInfoPanel(hasFullDiskAccess);
  children.push(
    buildSourcesSection(sources, status, ignoreSettings, binDir),
    buildHousekeepingSection(housekeeping, binDir),
    buildReplicationSection(replicationStatus, replicationCapability, binDir),
    ...(scheduleInfoPanel ? [scheduleInfoPanel] : []),
    buildSearchSection(binDir),
  );
  app.replaceChildren(...children);
}

// A single optional schedule for updatedb+replicate, separate from
// per-source schedules - running these on every individual source's
// own timer would mean redundant reindexing whenever sources have
// different times (see docs/SCHEDULING.md's own crontab examples:
// several backup lines, then one updatedb line, then optionally
// replicate).
function buildHousekeepingSection(schedule: Schedule | null, binDir: string): HTMLElement {
  const header = el("h2", {}, [
    "Housekeeping ",
    helpIcon(
      "Reindexes search and pushes off-site replication, in that order - not part of any single project's own schedule.",
      "backmeup.updatedb.sh && backmeup.replicate.sh",
    ),
  ]);
  const desc = el("p", {}, [
    "Keeps search indexed and (if configured) replicates off-site. Runs independently of the schedules above.",
  ]);

  const container = el("div", { class: "housekeeping-control" }, []);
  const editRow = el("div", {}, []);
  editRow.style.display = "none";

  const showEdit = () => {
    const editor = buildScheduleEditor(
      schedule,
      (chosen) => void setHousekeepingSchedule(binDir, chosen),
      () => {
        editRow.style.display = "none";
      },
    );
    editRow.replaceChildren(editor);
    editRow.style.display = "";
  };

  const runNowBtn = el("button", { type: "button", class: "job-trigger-btn" }, ["Run now"]);
  const runLogEl = el("pre", { class: "log" }, []);
  const runRow = el("div", {}, [runLogEl]);
  runRow.style.display = "none";
  runNowBtn.addEventListener("click", () => void runHousekeepingNow(binDir, runNowBtn, runRow, runLogEl));

  if (schedule) {
    const editBtn = el("button", { type: "button" }, ["Edit"]);
    editBtn.addEventListener("click", showEdit);
    const offBtn = el("button", { type: "button", class: "remove-btn" }, ["Turn off"]);
    offBtn.addEventListener("click", () => void clearHousekeepingSchedule(binDir));
    container.replaceChildren(`${formatSchedule(schedule)} `, editBtn, offBtn, runNowBtn);
  } else {
    const setBtn = el("button", { type: "button" }, ["Set schedule"]);
    setBtn.addEventListener("click", showEdit);
    container.replaceChildren("Off ", setBtn, runNowBtn);
  }

  return el("section", {}, [header, desc, container, editRow, runRow]);
}

export async function setHousekeepingSchedule(binDir: string, schedule: Schedule) {
  try {
    await invoke("set_housekeeping_schedule", { binDir, schedule });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

export async function clearHousekeepingSchedule(binDir: string) {
  try {
    await invoke("clear_housekeeping_schedule");
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

// Mirrors buildScheduleEditor's shape exactly: a backend select
// toggling which fields are visible, explicit Save/Cancel. Proton's
// remote field is optional - left blank, it's sent as null so
// replication.rs omits the flag entirely and backmeup.configure.sh's
// own /bmug2/<hostname> default applies, the same default the
// interactive CLI prompt already uses.
export function buildReplicationEditor(
  current: ReplicationStatus,
  onSave: (request: ReplicationRequest) => void,
  onCancel: () => void,
): HTMLElement {
  const startBackend = current.backend === "off" ? "rclone" : current.backend;

  const backendSelect = el("select", {}) as HTMLSelectElement;
  backendSelect.append(
    new Option("rclone (SYNC + HISTORY)", "rclone", startBackend === "rclone", startBackend === "rclone"),
    new Option("Proton Drive (HISTORY only)", "proton", startBackend === "proton", startBackend === "proton"),
    new Option("Mounted folder (Google Drive, Dropbox, …)", "local_path", startBackend === "local_path", startBackend === "local_path"),
  );

  const remoteSyncInput = el("input", {
    type: "text",
    placeholder: "remote:bucket/path",
  }) as HTMLInputElement;
  remoteSyncInput.value = current.backend === "rclone" ? current.remote_sync : "";

  const remoteBackupsInput = el("input", {
    type: "text",
    placeholder: "remote:bucket/path-BP",
  }) as HTMLInputElement;
  remoteBackupsInput.value = current.backend === "rclone" ? current.remote_backups : "";

  // Same in-app-picker reasoning as the Proton field below, scoped to
  // Google Drive remotes specifically (see buildGoogleDriveFolderBrowser's
  // own doc comment) - rclone itself has no native OS dialog either, and
  // a generic "browse any rclone remote" picker wasn't asked for.
  const makeGdriveBrowseRow = (input: HTMLInputElement): { row: HTMLElement; panel: HTMLElement } => {
    const gdriveBrowseBtn = el("button", { type: "button", class: "browse-btn" }, ["Browse…"]);
    const gdrivePanel = el("div", {}, []);
    gdrivePanel.style.display = "none";
    gdriveBrowseBtn.addEventListener("click", () => {
      if (gdrivePanel.style.display === "none") {
        gdrivePanel.replaceChildren(
          buildGoogleDriveFolderBrowser(
            input.value,
            (chosen) => {
              input.value = chosen;
              gdrivePanel.style.display = "none";
            },
            () => {
              gdrivePanel.style.display = "none";
            },
          ),
        );
        gdrivePanel.style.display = "";
      } else {
        gdrivePanel.style.display = "none";
      }
    });
    void invoke<boolean>("rclone_available")
      .then((available) => {
        if (!available) {
          gdriveBrowseBtn.disabled = true;
          gdriveBrowseBtn.title = "rclone is not installed on this machine";
        }
      })
      .catch(() => {
        // No Tauri bridge (e.g. under test) or the command itself failed -
        // leave the button enabled; a real click will surface its own error.
      });
    return { row: el("div", { class: "field-row" }, [input, gdriveBrowseBtn]), panel: gdrivePanel };
  };
  const gdriveSync = makeGdriveBrowseRow(remoteSyncInput);
  const gdriveBackups = makeGdriveBrowseRow(remoteBackupsInput);

  const protonRemoteInput = el("input", {
    type: "text",
    placeholder: "/bmug2/<hostname> (default)",
  }) as HTMLInputElement;
  protonRemoteInput.value = current.backend === "proton" ? current.remote : "";

  // No native OS dialog for a cloud Drive's own tree - "Browse..."
  // toggles an in-app picker instead, built fresh each time it's
  // opened so it always reflects the input's current value.
  const browseBtn = el("button", { type: "button", class: "browse-btn" }, ["Browse…"]);
  const browserPanel = el("div", {}, []);
  browserPanel.style.display = "none";
  browseBtn.addEventListener("click", () => {
    if (browserPanel.style.display === "none") {
      browserPanel.replaceChildren(
        buildProtonFolderBrowser(
          protonRemoteInput.value || "/my-files",
          (chosen) => {
            protonRemoteInput.value = chosen;
            browserPanel.style.display = "none";
          },
          () => {
            browserPanel.style.display = "none";
          },
        ),
      );
      browserPanel.style.display = "";
    } else {
      browserPanel.style.display = "none";
    }
  });
  void invoke<boolean>("proton_drive_available")
    .then((available) => {
      if (!available) {
        browseBtn.disabled = true;
        browseBtn.title = "proton-drive is not installed on this machine";
      }
      // Not being signed in is no longer a reason to disable the
      // button - buildProtonFolderBrowser checks that itself and
      // offers a "Sign in..." button in-panel instead of a dead end.
    })
    .catch(() => {
      // No Tauri bridge (e.g. under test) or the command itself failed -
      // leave the button enabled; a real click will surface its own error.
    });
  const protonRemoteRow = el("div", { class: "field-row" }, [protonRemoteInput, browseBtn]);

  // Local/mounted-folder path inputs - each with a native OS folder
  // picker (same directoryField pattern used in the install form; the
  // local mount is a real directory so the native dialog is the right
  // UX, not an in-app tree picker over a remote). Pre-populated from
  // current status if available, and auto-detected from find_gdrive_mount
  // if both are still empty after the editor opens.
  const pathSyncInput = el("input", {
    type: "text",
    placeholder: "/Volumes/GoogleDrive/My Drive/bmug2/SYNC",
  }) as HTMLInputElement;
  pathSyncInput.value = current.backend === "local_path" ? current.path_sync : "";

  const pathBackupsInput = el("input", {
    type: "text",
    placeholder: "/Volumes/GoogleDrive/My Drive/bmug2/BackUp",
  }) as HTMLInputElement;
  pathBackupsInput.value = current.backend === "local_path" ? current.path_backups : "";

  const makeLocalBrowseBtn = (input: HTMLInputElement): HTMLButtonElement => {
    const btn = el("button", { type: "button", class: "browse-btn" }, ["Browse…"]) as HTMLButtonElement;
    btn.addEventListener("click", () => {
      void open({ directory: true, defaultPath: input.value || undefined }).then((selected) => {
        if (typeof selected === "string") {
          input.value = selected;
        }
      });
    });
    return btn;
  };
  const localSyncRow = el("div", { class: "field-row" }, [pathSyncInput, makeLocalBrowseBtn(pathSyncInput)]);
  const localBackupsRow = el("div", { class: "field-row" }, [pathBackupsInput, makeLocalBrowseBtn(pathBackupsInput)]);

  // Auto-detect: if both path inputs are empty when the editor opens,
  // ask the backend for the first Google Drive mount it can find and
  // pre-fill both paths with the conventional bmug2 subdirectory layout.
  // Only fires when the backend reports a path - silently a no-op if
  // nothing is found (avoids a confusing "detecting…" state for users
  // who don't have Google Drive installed).
  void invoke<string | null>("find_gdrive_mount")
    .then((mountPath) => {
      if (mountPath && !pathSyncInput.value && !pathBackupsInput.value) {
        pathSyncInput.value = `${mountPath}/bmug2/SYNC`;
        pathBackupsInput.value = `${mountPath}/bmug2/BackUp`;
      }
    })
    .catch(() => {
      // No Tauri bridge (under test) or command failed - leave blank.
    });

  const updateVisibility = () => {
    const backend = backendSelect.value;
    const rclone = backend === "rclone";
    const proton = backend === "proton";
    const local = backend === "local_path";
    gdriveSync.row.style.display = rclone ? "" : "none";
    gdriveBackups.row.style.display = rclone ? "" : "none";
    protonRemoteRow.style.display = proton ? "" : "none";
    localSyncRow.style.display = local ? "" : "none";
    localBackupsRow.style.display = local ? "" : "none";
    if (!rclone) {
      gdriveSync.panel.style.display = "none";
      gdriveBackups.panel.style.display = "none";
    }
    if (!proton) {
      browserPanel.style.display = "none";
    }
  };
  updateVisibility();
  backendSelect.addEventListener("change", updateVisibility);

  const saveBtn = el("button", { type: "button" }, ["Save"]);
  const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
  saveBtn.addEventListener("click", () => {
    const backend = backendSelect.value;
    if (backend === "rclone") {
      if (!remoteSyncInput.value || !remoteBackupsInput.value) return;
      onSave({
        backend: "rclone",
        remote_sync: remoteSyncInput.value,
        remote_backups: remoteBackupsInput.value,
      });
    } else if (backend === "local_path") {
      if (!pathSyncInput.value || !pathBackupsInput.value) return;
      onSave({
        backend: "local_path",
        path_sync: pathSyncInput.value,
        path_backups: pathBackupsInput.value,
      });
    } else {
      onSave({ backend: "proton", remote: protonRemoteInput.value || null });
    }
  });
  cancelBtn.addEventListener("click", onCancel);

  return el("span", { class: "schedule-edit schedule-edit--replication" }, [
    backendSelect,
    gdriveSync.row,
    gdriveSync.panel,
    gdriveBackups.row,
    gdriveBackups.panel,
    protonRemoteRow,
    browserPanel,
    localSyncRow,
    localBackupsRow,
    el("div", { class: "field-row" }, [saveBtn, cancelBtn]),
  ]);
}

export interface RemoteEntry {
  name: string;
  is_folder: boolean;
}

// A self-contained, stateful mini folder-browser for the Proton remote
// field - own closure-local currentPath, re-rendered in place on
// navigation (same "replaceChildren a box in-place" idiom as
// renderSearchResults/buildScheduleEditor). Not a new top-level screen:
// this is a short pick-one-and-return interaction nested inside an
// already-expanded editor row. /my-files is the only entry point - the
// bare "/" root only has other Proton-specific categories (devices,
// shared-with-me, trash, photos, ...) that are never useful backup
// destinations, so they're deliberately never exposed here.
export function buildProtonFolderBrowser(
  startPath: string,
  onChoose: (path: string) => void,
  onCancel: () => void,
): HTMLElement {
  const container = el("div", { class: "remote-browser" }, []);
  let currentPath = startPath.startsWith("/my-files") ? startPath : "/my-files";

  const render = () => {
    container.replaceChildren(el("p", {}, ["Loading…"]));
    void invoke<RemoteEntry[]>("list_proton_folder", { path: currentPath })
      .then((entries) => renderLoaded(entries))
      .catch((err) => {
        container.replaceChildren(
          el("p", { class: "settings-check-error" }, [String(err)]),
          cancelRow(),
        );
      });
  };

  const cancelRow = () => {
    const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
    cancelBtn.addEventListener("click", onCancel);
    return cancelBtn;
  };

  // Not signed in yet - offer to sign in right here instead of a dead
  // end pointing at a terminal. `proton-drive auth login` opens the
  // system browser itself and blocks until sign-in completes.
  const renderSignInForm = (error?: string) => {
    const signInBtn = el("button", { type: "button", class: "browse-btn" }, ["Sign in to Proton Drive…"]);
    signInBtn.addEventListener("click", () => {
      container.replaceChildren(
        el("p", {}, ["A browser window should open — finish signing in there. This can take a minute…"]),
      );
      void invoke("proton_drive_login")
        .then(() => render())
        .catch((err) => renderSignInForm(String(err)));
    });
    const children: HTMLElement[] = [];
    if (error) children.push(el("p", { class: "settings-check-error" }, [error]));
    children.push(el("p", {}, ["Not signed in to Proton Drive yet."]), signInBtn, cancelRow());
    container.replaceChildren(...children);
  };

  const renderLoaded = (entries: RemoteEntry[]) => {
    const segments = currentPath.split("/").filter(Boolean);
    const breadcrumb = el("p", { class: "remote-breadcrumb" }, []);
    segments.forEach((segment, i) => {
      const segPath = "/" + segments.slice(0, i + 1).join("/");
      const btn = el("button", { type: "button" }, [segment]);
      btn.addEventListener("click", () => {
        currentPath = segPath;
        render();
      });
      breadcrumb.append(btn, i < segments.length - 1 ? " / " : "");
    });

    const folders = entries.filter((e) => e.is_folder);
    const list = el(
      "ul",
      { class: "remote-folder-list" },
      folders.length === 0
        ? [el("li", {}, ["(no subfolders)"])]
        : folders.map((folder) => {
            const descendBtn = el("button", { type: "button" }, [folder.name]);
            descendBtn.addEventListener("click", () => {
              currentPath = `${currentPath.replace(/\/$/, "")}/${folder.name}`;
              render();
            });
            return el("li", {}, [descendBtn]);
          }),
    );

    const useBtn = el("button", { type: "button" }, [`Use "${currentPath}"`]);
    useBtn.addEventListener("click", () => onChoose(currentPath));

    const newFolderInput = el("input", { type: "text", placeholder: "New folder name" }) as HTMLInputElement;
    const createBtn = el("button", { type: "button", class: "browse-btn" }, ["Create"]);
    createBtn.addEventListener("click", () => {
      const name = newFolderInput.value.trim();
      if (!name) return;
      void invoke("create_proton_folder", { parent: currentPath, name })
        .then(() => render())
        .catch((err) => {
          container.replaceChildren(
            el("p", { class: "settings-check-error" }, [String(err)]),
            cancelRow(),
          );
        });
    });

    container.replaceChildren(
      breadcrumb,
      list,
      el("div", { class: "field-row" }, [newFolderInput, createBtn]),
      useBtn,
      cancelRow(),
    );
  };

  void invoke<boolean>("proton_drive_signed_in")
    .then((signedIn) => (signedIn ? render() : renderSignInForm()))
    .catch(() => render()); // let a real click surface its own error, same existing fallback philosophy
  return container;
}

// A folder browser for a Google Drive rclone remote - mirrors
// buildProtonFolderBrowser's shape and idioms, with one extra stage up
// front: rclone can have more than one Google Drive remote configured,
// so when startValue doesn't already name a known one, the user picks
// which remote to browse first. Scoped to "drive"-type remotes only -
// see rclone_browse.rs's own module doc for why this isn't a general
// "browse any rclone remote" picker.
export function buildGoogleDriveFolderBrowser(
  startValue: string,
  onChoose: (path: string) => void,
  onCancel: () => void,
): HTMLElement {
  const container = el("div", { class: "remote-browser" }, []);
  let currentRemote: string | null = null;
  let currentPath = "";

  const cancelRow = () => {
    const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
    cancelBtn.addEventListener("click", onCancel);
    return cancelBtn;
  };

  const showError = (err: unknown) => {
    container.replaceChildren(el("p", { class: "settings-check-error" }, [String(err)]), cancelRow());
  };

  const renderRemotePicker = (remotes: string[]) => {
    const list = el(
      "ul",
      { class: "remote-folder-list" },
      remotes.map((name) => {
        const pickBtn = el("button", { type: "button" }, [name]);
        pickBtn.addEventListener("click", () => {
          currentRemote = name;
          currentPath = "";
          renderFolder();
        });
        return el("li", {}, [pickBtn]);
      }),
    );
    container.replaceChildren(el("p", {}, ["Choose a Google Drive remote:"]), list, cancelRow());
  };

  const renderFolder = () => {
    const remote = currentRemote;
    if (remote === null) return;
    container.replaceChildren(el("p", {}, ["Loading…"]));
    const fullPath = currentPath ? `${remote}:${currentPath}` : `${remote}:`;
    void invoke<RemoteEntry[]>("list_rclone_folder", { path: fullPath })
      .then((entries) => renderLoaded(remote, entries))
      .catch(showError);
  };

  const renderLoaded = (remote: string, entries: RemoteEntry[]) => {
    const segments = currentPath.split("/").filter(Boolean);
    const breadcrumb = el("p", { class: "remote-breadcrumb" }, []);
    const rootBtn = el("button", { type: "button" }, [`${remote}:`]);
    rootBtn.addEventListener("click", () => {
      currentPath = "";
      renderFolder();
    });
    breadcrumb.append(rootBtn, segments.length > 0 ? " / " : "");
    segments.forEach((segment, i) => {
      const segPath = segments.slice(0, i + 1).join("/");
      const btn = el("button", { type: "button" }, [segment]);
      btn.addEventListener("click", () => {
        currentPath = segPath;
        renderFolder();
      });
      breadcrumb.append(btn, i < segments.length - 1 ? " / " : "");
    });

    const folders = entries.filter((e) => e.is_folder);
    const list = el(
      "ul",
      { class: "remote-folder-list" },
      folders.length === 0
        ? [el("li", {}, ["(no subfolders)"])]
        : folders.map((folder) => {
            const descendBtn = el("button", { type: "button" }, [folder.name]);
            descendBtn.addEventListener("click", () => {
              currentPath = currentPath ? `${currentPath}/${folder.name}` : folder.name;
              renderFolder();
            });
            return el("li", {}, [descendBtn]);
          }),
    );

    const fullPath = currentPath ? `${remote}:${currentPath}` : `${remote}:`;
    const useBtn = el("button", { type: "button" }, [`Use "${fullPath}"`]);
    useBtn.addEventListener("click", () => onChoose(fullPath));

    const newFolderInput = el("input", { type: "text", placeholder: "New folder name" }) as HTMLInputElement;
    const createBtn = el("button", { type: "button", class: "browse-btn" }, ["Create"]);
    createBtn.addEventListener("click", () => {
      const name = newFolderInput.value.trim();
      if (!name) return;
      const newPath = currentPath ? `${remote}:${currentPath}/${name}` : `${remote}:${name}`;
      void invoke("create_rclone_folder", { path: newPath })
        .then(() => renderFolder())
        .catch(showError);
    });

    container.replaceChildren(
      breadcrumb,
      list,
      el("div", { class: "field-row" }, [newFolderInput, createBtn]),
      useBtn,
      cancelRow(),
    );
  };

  // No remote configured yet - offer to add one right here instead of
  // a dead-end pointing at a terminal. Drives rclone's own
  // non-interactive setup protocol (create_drive_remote); the one step
  // that can't be automated is the real Google sign-in, which opens in
  // the system browser while this waits.
  const renderConnectForm = (error?: string) => {
    const nameInput = el("input", { type: "text", value: "gdrive" }) as HTMLInputElement;
    const connectBtn = el("button", { type: "button", class: "browse-btn" }, ["Connect Google Drive…"]);
    connectBtn.addEventListener("click", () => {
      const name = nameInput.value.trim();
      if (!name) return;
      container.replaceChildren(
        el("p", {}, [
          "A browser window should open — finish signing in with Google there. This can take a minute…",
        ]),
      );
      void invoke("create_drive_remote", { name })
        .then(() => loadRemotes())
        .catch((err) => renderConnectForm(String(err)));
    });
    const children: HTMLElement[] = [];
    if (error) children.push(el("p", { class: "settings-check-error" }, [error]));
    children.push(
      el("p", {}, ["No Google Drive remote configured yet."]),
      el("div", { class: "field-row" }, [nameInput, connectBtn]),
      cancelRow(),
    );
    container.replaceChildren(...children);
  };

  const loadRemotes = () => {
    container.replaceChildren(el("p", {}, ["Loading…"]));
    void invoke<string[]>("list_drive_remotes")
      .then((remotes) => {
        if (remotes.length === 0) {
          renderConnectForm();
          return;
        }
        const colonIndex = startValue.indexOf(":");
        const startRemote = colonIndex >= 0 ? startValue.slice(0, colonIndex) : "";
        if (startRemote && remotes.includes(startRemote)) {
          currentRemote = startRemote;
          currentPath = startValue.slice(colonIndex + 1).replace(/^\/+|\/+$/g, "");
          renderFolder();
        } else if (remotes.length === 1) {
          currentRemote = remotes[0];
          currentPath = "";
          renderFolder();
        } else {
          renderRemotePicker(remotes);
        }
      })
      .catch(showError);
  };

  loadRemotes();
  return container;
}

// Mirrors buildHousekeepingSection's structure - another global,
// opt-in capability, not per-source. See docs/DESTINATIONS.md for the
// two backends' own tradeoffs (rclone mirrors SYNC+HISTORY to any
// remote; Proton Drive is HISTORY only, natively end-to-end encrypted).
export function buildReplicationSection(
  status: ReplicationStatus,
  capability: ReplicationCapability,
  binDir: string,
): HTMLElement {
  const header = el("h2", {}, [
    "Off-site replication ",
    helpIcon(
      "A separate copy step on top of the local mirror - rclone mirrors SYNC+HISTORY, native Proton Drive uploads HISTORY only.",
      "backmeup.configure.sh --replicate-backend=rclone --replicate-remote-sync=remote:bucket/sync --replicate-remote-backups=remote:bucket/sync-BP",
    ),
  ]);
  const desc = el("p", {}, [
    "Copies SYNC/HISTORY to an off-site destination - rclone (any remote) or native Proton Drive (HISTORY only). See docs/DESTINATIONS.md.",
  ]);

  if (!capability.ok) {
    return el("section", {}, [
      header,
      desc,
      el("div", { class: "schedule-info" }, [el("p", {}, [capability.message])]),
    ]);
  }

  const container = el("div", { class: "housekeeping-control" }, []);
  const editRow = el("div", {}, []);
  editRow.style.display = "none";

  const showEdit = () => {
    const editor = buildReplicationEditor(
      status,
      (request) => void setReplication(binDir, request),
      () => {
        editRow.style.display = "none";
      },
    );
    editRow.replaceChildren(editor);
    editRow.style.display = "";
  };

  if (status.backend === "off") {
    const setBtn = el("button", { type: "button" }, ["Set up replication"]);
    setBtn.addEventListener("click", showEdit);
    container.replaceChildren("Off ", setBtn);
  } else {
    let label: string;
    if (status.backend === "rclone") {
      label = `rclone -> ${status.remote_sync} / ${status.remote_backups}`;
    } else if (status.backend === "proton") {
      label = `Proton Drive (HISTORY only) -> ${status.remote}`;
    } else {
      label = `Mounted folder -> ${status.path_sync} / ${status.path_backups}`;
    }
    const editBtn = el("button", { type: "button" }, ["Edit"]);
    editBtn.addEventListener("click", showEdit);
    const offBtn = el("button", { type: "button", class: "remove-btn" }, ["Turn off"]);
    offBtn.addEventListener("click", () => void clearReplication(binDir));
    container.replaceChildren(`${label} `, editBtn, offBtn);
  }

  return el("section", {}, [header, desc, container, editRow]);
}

export async function setReplication(binDir: string, request: ReplicationRequest) {
  try {
    await invoke("set_replication", { binDir, request });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

export async function clearReplication(binDir: string) {
  try {
    await invoke("clear_replication", { binDir });
    void renderDashboard(binDir);
  } catch (err) {
    void renderDashboard(binDir, { ok: false, message: String(err) });
  }
}

// A schedule is real background OS state the GUI installs - two
// platform-specific gotchas worth surfacing right where schedules are
// created, both already documented in docs/SCHEDULING.md/MANUAL.md's
// Troubleshooting section: macOS's Full Disk Access (TCC) can
// silently block a scheduled run from reading ~/Documents-style
// folders even though it works fine run by hand; Linux stops a user
// timer when you log out unless lingering is enabled. Neither is
// something the GUI can safely do on the user's behalf - opening the
// Privacy pane is just navigation, not a settings change, and
// enabling linger is a real session-policy change that stays a
// manual, explicit step.
//
// hasFullDiskAccess (macOS only - see has_full_disk_access in
// schedule.rs) lets this skip the warning entirely once it's moot,
// rather than nagging a user who already granted it.
export function buildScheduleInfoPanel(hasFullDiskAccess: boolean): HTMLElement | null {
  if (isMac()) {
    if (hasFullDiskAccess) return null;
    const openBtn = el("button", { type: "button" }, ["Open Full Disk Access settings"]);
    openBtn.addEventListener("click", () => {
      void openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles");
    });
    return el("div", { class: "schedule-info" }, [
      el("p", {}, [
        "Scheduled runs may need Full Disk Access to read folders like ~/Documents, " +
          "even though the same backup works fine when run by hand or via Run Now.",
      ]),
      openBtn,
    ]);
  }
  return el("div", { class: "schedule-info" }, [
    el("p", {}, [
      "A schedule stops running once you log out unless lingering is enabled for " +
        "your account. Run this once in a terminal to keep it running while logged out:",
    ]),
    el("code", {}, ["loginctl enable-linger $USER"]),
  ]);
}

export function isMac(): boolean {
  return navigator.platform.toLowerCase().includes("mac");
}

export function buildRunBanner(banner: RunBanner): HTMLElement {
  const cls = banner.ok ? "run-banner run-banner-ok" : "run-banner run-banner-error";
  const children: (Node | string)[] = [el("p", {}, [banner.message])];
  if (banner.log) children.push(el("pre", { class: "log log-error" }, [banner.log]));
  return el("div", { class: cls }, children);
}

function renderError(message: string, retry: () => void) {
  const pre = el("pre", { class: "log log-error" }, [message]);
  const backBtn = el("button", { type: "button" }, ["Back"]);
  backBtn.addEventListener("click", retry);
  app.replaceChildren(
    el("h1", {}, ["bmug2"]),
    el("p", { class: "error-heading" }, ["Error:"]),
    pre,
    backBtn,
  );
}

function renderInstalling(message: string) {
  app.replaceChildren(el("h1", {}, ["bmug2"]), el("p", {}, [message]));
}

// The first "navigate to a second screen and back" affordance in this
// app - every other top-level render fully replaces #app's children
// the same way (renderDashboard/renderSetup's own shape), so this does
// too rather than introducing a modal/overlay idiom this app has none
// of. Always does its own FRESH check_for_update call (never reads
// cachedUpdateCheck) since opening Settings is itself a deliberate
// "tell me the current state" action - and updates that same shared
// cache so a return to the dashboard reflects it too.
export async function renderSettings(binDir: string) {
  app.replaceChildren(el("h1", {}, ["Settings"]), el("p", {}, ["Checking for updates…"]));

  let info: UpdateInfo | null = null;
  let checkError: string | null = null;
  try {
    info = await invoke<UpdateInfo>("check_for_update", { binDir });
    cachedUpdateCheck = info;
  } catch (err) {
    checkError = String(err);
  }

  const backBtn = el("button", { type: "button", class: "settings-back-btn" }, ["← Back to dashboard"]);
  backBtn.addEventListener("click", () => void renderDashboard(binDir));

  const versionBox = el("div", { class: "settings-version" }, []);
  if (info) {
    versionBox.append(
      el("p", {}, [el("strong", {}, ["Installed: "]), formatVersion(info.current)]),
    );
    const installHelpIcon = helpIcon(
      "Re-downloads the release and re-runs install.sh over your existing SYNC/HISTORY - nothing is relocated or re-transferred.",
      "./install.sh --sync-dir=... --backup-dir=... --index-dir=... --install-dir=...",
    );
    if (info.latest_stable) {
      const installBtn = el("button", { type: "button" }, ["Install"]);
      installBtn.addEventListener("click", () => showUpdateConfirm(binDir, info!.latest_stable!));
      versionBox.append(
        el("p", {}, [
          el("strong", {}, ["Latest stable: "]),
          `${info.latest_stable} `,
          installBtn,
          " ",
          installHelpIcon,
        ]),
      );
    }
    if (info.latest_experimental) {
      const installBtn = el("button", { type: "button" }, ["Install"]);
      installBtn.addEventListener("click", () => showUpdateConfirm(binDir, info!.latest_experimental!));
      versionBox.append(
        el("p", {}, [
          el("strong", {}, ["Latest experimental: "]),
          `${info.latest_experimental} `,
          installBtn,
          " ",
          installHelpIcon,
        ]),
      );
    }
    if (!info.latest_stable && !info.latest_experimental) {
      versionBox.append(el("p", { class: "settings-uptodate" }, ["You're up to date."]));
    }
  } else {
    versionBox.append(
      el("p", { class: "settings-check-error" }, [`Couldn't check for updates: ${checkError}`]),
    );
  }

  app.replaceChildren(el("h1", {}, ["Settings"]), backBtn, versionBox);
}

// Explicit, separate confirmation step before any apply_update call -
// clicking "Install" never installs by itself.
function showUpdateConfirm(binDir: string, version: string) {
  const confirmBtn = el("button", { type: "button" }, ["Yes, install the update"]);
  const cancelBtn = el("button", { type: "button" }, ["Cancel"]);
  cancelBtn.addEventListener("click", () => void renderSettings(binDir));
  confirmBtn.addEventListener("click", () => void performUpdate(binDir));

  app.replaceChildren(
    el("h1", {}, ["Settings"]),
    el("div", { class: "settings-confirm" }, [
      el("p", {}, [
        `This will download bmug2 ${version} and re-run install.sh ` +
          "in place over your existing install. Your SYNC/HISTORY data and settings are not touched.",
      ]),
      confirmBtn,
      cancelBtn,
    ]),
  );
}

async function performUpdate(binDir: string) {
  renderInstalling("Updating…");
  try {
    const outcome = await invoke<InstallOutcome>("apply_update", { binDir });
    void renderDashboard(outcome.bin_dir, {
      ok: true,
      message: "Updated successfully.",
      log: outcome.log,
    });
  } catch (err) {
    renderError(String(err), () => void renderSettings(binDir));
  }
}

export async function renderSetup() {
  let defaults: DefaultPaths;
  try {
    defaults = await invoke<DefaultPaths>("get_default_paths");
  } catch (err) {
    renderError(String(err), renderSetup);
    return;
  }

  let mode: "new" | "existing" = "new";

  const rerender = () => build();

  function build() {
    const newTab = el("button", { type: "button", class: "tab" }, [
      "Install a new copy",
    ]);
    const existingTab = el("button", { type: "button", class: "tab" }, [
      "Use an existing install",
    ]);
    newTab.classList.toggle("active", mode === "new");
    existingTab.classList.toggle("active", mode === "existing");
    newTab.addEventListener("click", () => {
      mode = "new";
      rerender();
    });
    existingTab.addEventListener("click", () => {
      mode = "existing";
      rerender();
    });

    const form =
      mode === "new" ? buildNewForm(defaults) : buildExistingForm();

    app.replaceChildren(
      el("h1", {}, ["bmug2"]),
      el("div", { class: "tabs" }, [newTab, existingTab]),
      form,
    );
  }

  build();
}

interface FieldHelp {
  description: string;
  cliExample?: string;
}

function field(
  label: string,
  id: string,
  value: string,
  help?: FieldHelp,
): [HTMLDivElement, HTMLInputElement] {
  const input = el("input", { type: "text", id, value });
  const labelChildren: (Node | string)[] = [label];
  if (help) labelChildren.push(" ", helpIcon(help.description, help.cliExample));
  const wrapper = el("div", { class: "field" }, [
    el("label", { for: id }, labelChildren),
    input,
  ]);
  return [wrapper, input];
}

// Same as field(), plus a native folder-picker button (no client-side
// path validation here either - picking a folder just fills the same
// text input backmeup.configure.sh's own validation ultimately checks;
// typing/pasting a path directly still works exactly as before.
function directoryField(
  label: string,
  id: string,
  value: string,
  help?: FieldHelp,
): [HTMLDivElement, HTMLInputElement] {
  const input = el("input", { type: "text", id, value });
  const browseBtn = el("button", { type: "button", class: "browse-btn" }, [
    "Browse…",
  ]);
  browseBtn.addEventListener("click", () => {
    void open({ directory: true, defaultPath: input.value || undefined }).then(
      (selected) => {
        if (typeof selected === "string") {
          input.value = selected;
          // Plain .value assignment never fires a native "input" event
          // on its own - dispatching one makes a Browse-driven change
          // indistinguishable from typing for any listener (e.g.
          // buildNewForm's IndexDB auto-follow, which needs to detach
          // the moment the user picks their own folder, not just when
          // they type into it directly).
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }
      },
    );
  });
  const row = el("div", { class: "field-row" }, [input, browseBtn]);
  const labelChildren: (Node | string)[] = [label];
  if (help) labelChildren.push(" ", helpIcon(help.description, help.cliExample));
  const wrapper = el("div", { class: "field" }, [
    el("label", { for: id }, labelChildren),
    row,
  ]);
  return [wrapper, input];
}

function buildNewForm(defaults: DefaultPaths): HTMLFormElement {
  const [syncField, syncInput] = directoryField("SYNC directory", "sync-dir", defaults.sync_dir, {
    description: "The live mirror - exactly what's currently in your source folder. Keep it fast and local.",
    cliExample: "backmeup.configure.sh --sync-dir=/path/to/sync",
  });
  const [backupField, backupInput] = directoryField(
    "BackUp directory",
    "backup-dir",
    defaults.backup_dir,
    {
      description: "Old and deleted file versions, kept as timestamped snapshots - not a full copy, just the changes.",
      cliExample: "backmeup.configure.sh --backup-dir=/path/to/sync-BP",
    },
  );
  const [indexField, indexInput] = directoryField(
    "IndexDB directory",
    "index-dir",
    defaults.index_dir,
    {
      description:
        "The search index backmeup.locate.sh uses - follows SYNC automatically. Only edit it directly if you want the index somewhere else, e.g. SYNC is on a slower/external drive and you'd rather keep the index fast and local.",
      cliExample: "backmeup.configure.sh --index-dir=/path/to/sync/.locate.dir",
    },
  );
  // Keeps IndexDB's suggested value in lockstep with SYNC for the
  // common case (everything local - most users never need to think
  // about this field at all) without losing the real, documented
  // reason it's independently configurable in the CLI: SYNC living on
  // a slower/external drive, where you'd want the index kept local
  // instead of nested inside it. A plain .value assignment (this
  // follow logic's own update, same as the Browse button's) never
  // fires "input" on its own - only real user typing/Browse-selection
  // does (see directoryField's own dispatchEvent) - so this can't
  // mistake its own update for a manual edit and detach itself.
  let indexFollowsSync = true;
  syncInput.addEventListener("input", () => {
    if (indexFollowsSync) indexInput.value = `${syncInput.value}/.locate.dir`;
  });
  indexInput.addEventListener("input", () => {
    indexFollowsSync = false;
  });
  const [dirField, dirInput] = directoryField(
    "BMU install directory",
    "install-dir",
    defaults.install_dir,
    {
      description: "Where the bmug2 program itself lives, on your regular system disk - separate from your data above.",
      cliExample: "backmeup.configure.sh --install-dir=/path/to/usr/bmu",
    },
  );

  const submit = el("button", { type: "submit" }, ["Install"]);

  const form = el(
    "form",
    {},
    [
      el("p", {}, [
        "SYNC (the live mirror), BackUp (old and deleted versions), and " +
          "IndexDB (the search index) are your data — keep them safe " +
          "from casual deletion. SYNC and IndexDB in particular should " +
          "stay fast and local; an off-site copy is a separate step, not " +
          "a replacement for these. The install directory below is a " +
          "different thing — where the bmug2 program itself lives, " +
          "on your regular system disk.",
      ]),
      syncField,
      backupField,
      indexField,
      dirField,
      submit,
    ],
  );

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    void runInstall({
      mode: "new",
      sync_dir: syncInput.value,
      backup_dir: backupInput.value,
      index_dir: indexInput.value,
      install_dir: dirInput.value,
    });
  });

  return form;
}

function buildSuggestionsBox(onPick: (path: string) => void): HTMLElement {
  const box = el("div", { class: "suggestions" }, [
    el("p", { class: "suggestions-status" }, ["Looking for existing installs…"]),
  ]);
  void invoke<string[]>("find_existing_installs")
    .then((paths) => {
      if (paths.length === 0) {
        box.replaceChildren();
        return;
      }
      box.replaceChildren(
        el("p", { class: "suggestions-label" }, ["Found on this machine:"]),
        el(
          "ul",
          { class: "suggestions-list" },
          paths.map((path) => {
            const btn = el("button", { type: "button", class: "suggestion-btn" }, [
              path,
            ]);
            btn.addEventListener("click", () => onPick(path));
            return el("li", {}, [btn]);
          }),
        ),
      );
    })
    .catch(() => {
      // best-effort only - the manual input/browse button still work
      box.replaceChildren();
    });
  return box;
}

function buildExistingForm(): HTMLFormElement {
  const [binField, binInput] = directoryField(
    "bmug2 bin directory (contains backmeup.sh)",
    "bin-dir",
    "",
    {
      description:
        "The bin/ folder from an already-configured install elsewhere - the one containing backmeup.sh and a backmeup.setup.sh generated by backmeup.configure.sh.",
    },
  );
  const suggestions = buildSuggestionsBox((path) => {
    binInput.value = path;
    binInput.dispatchEvent(new Event("input", { bubbles: true }));
  });
  const submit = el("button", { type: "submit" }, ["Use this install"]);
  const form = el("form", {}, [
    el("p", {}, [
      "Point at an install directory's ",
      el("code", {}, ["bin/"]),
      " — the one containing ",
      el("code", {}, ["backmeup.sh"]),
      " and a ",
      el("code", {}, ["backmeup.setup.sh"]),
      " generated by ",
      el("code", {}, ["backmeup.configure.sh"]),
      ".",
    ]),
    suggestions,
    binField,
    submit,
  ]);
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    void runInstall({ mode: "existing", bin_dir: binInput.value });
  });
  return form;
}

async function runInstall(request: InstallRequest) {
  renderInstalling(
    request.mode === "new" ? "Installing…" : "Checking…",
  );
  try {
    const outcome = await invoke<InstallOutcome>("install_bmug2", { request });
    void renderDashboard(outcome.bin_dir);
  } catch (err) {
    renderError(String(err), renderSetup);
  }
}

// Checked once per app session (not on every renderDashboard call -
// most mutating actions re-render the dashboard on success, and
// re-checking GitHub on every one of those would be wasteful and
// needlessly close to its unauthenticated rate limit). Settings'
// own screen always does its own fresh check instead of reading this,
// and updates it too, so a return to the dashboard reflects that.
let cachedUpdateCheck: UpdateInfo | null = null;

export async function init() {
  renderLoading();
  try {
    const existing = await invoke<string | null>("check_existing_install");
    if (existing) {
      try {
        cachedUpdateCheck = await invoke<UpdateInfo>("check_for_update", { binDir: existing });
      } catch {
        // offline, rate-limited, etc. - never blocks reaching the dashboard
      }
      void renderDashboard(existing);
      return;
    }
  } catch (err) {
    renderError(String(err), renderSetup);
    return;
  }
  await renderSetup();
}

window.addEventListener("DOMContentLoaded", () => {
  void init();
});
