import { describe, it, expect, vi, afterEach } from "vitest";
import {
  isDaily,
  el,
  formatKb,
  formatSchedule,
  timeInputValue,
  parseTimeInput,
  buildScheduleEditor,
  findUntrackedProjects,
  buildUntrackedProjectsNotice,
  buildIgnoreToggles,
  buildBmuignoreEditor,
  sourceLabel,
  isMac,
  type Schedule,
  type StatusProject,
  type StatusResult,
  type BackupSource,
  type IgnoreSettings,
} from "./main";

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
