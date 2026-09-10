import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";

// First-run flow: check for a saved install, otherwise offer to
// install a new copy or point at an existing one. Wording below is
// ported from bin/backmeup.configure.sh's own prompts/tips, not
// reinvented - keep the two in sync if either changes.

interface DefaultPaths {
  sync_dir: string;
  backup_dir: string;
  index_dir: string;
  install_dir: string;
}

interface InstallOutcome {
  bin_dir: string;
  log: string;
}

interface StatusProject {
  name: string;
  last_run: string | null;
  last_change: string | null;
  snapshot_count: number;
  mirror_size_kb: number;
  history_size_kb: number | null;
  old_layout: boolean;
}

interface StatusResult {
  sync_dir: string;
  history_dir: string;
  projects: StatusProject[];
}

interface LocateHit {
  path: string;
  source: string;
}

interface LocateResult {
  patterns: string[];
  indexed: boolean;
  counts: { index: number; live: number; archived_filelist: number };
  results: LocateHit[];
}

type InstallRequest =
  | ({ mode: "new" } & DefaultPaths)
  | { mode: "existing"; bin_dir: string };

const app = document.querySelector<HTMLElement>("#app")!;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (Node | string)[] = [],
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const c of children) e.append(c);
  return e;
}

function renderLoading() {
  app.replaceChildren(el("p", {}, ["Loading…"]));
}

function formatKb(kb: number | null): string {
  if (kb === null) return "-";
  if (kb >= 1024) return `${(kb / 1024).toFixed(1)} MB`;
  return `${kb} KB`;
}

function buildStatusSection(status: StatusResult, binDir: string): HTMLElement {
  const refreshBtn = el("button", { type: "button" }, ["Refresh"]);
  refreshBtn.addEventListener("click", () => void renderDashboard(binDir));

  const header = el("div", { class: "dashboard-header" }, [
    el("p", {}, [
      el("strong", {}, ["SYNC: "]),
      el("code", {}, [status.sync_dir]),
    ]),
    el("p", {}, [
      el("strong", {}, ["HISTORY: "]),
      el("code", {}, [status.history_dir]),
    ]),
    refreshBtn,
  ]);

  if (status.projects.length === 0) {
    return el("section", {}, [
      header,
      el("p", {}, [`(no projects found in ${status.sync_dir})`]),
    ]);
  }

  const rows = status.projects.map((p) =>
    el("tr", {}, [
      el("td", {}, [
        p.old_layout ? el("span", { class: "badge-old-layout" }, ["⚠"]) : "",
        p.name,
      ]),
      el("td", {}, [p.last_run ?? "-"]),
      el("td", {}, [p.last_change ?? "-"]),
      el("td", {}, [String(p.snapshot_count)]),
      el("td", {}, [formatKb(p.mirror_size_kb)]),
      el("td", {}, [formatKb(p.history_size_kb)]),
    ]),
  );

  const oldLayoutNotes = status.projects
    .filter((p) => p.old_layout)
    .map((p) =>
      el("p", { class: "note-old-layout" }, [
        `${p.name}: old layout, run backmeup.migrate.sh ${p.name} on the command line.`,
      ]),
    );

  const table = el("table", { class: "status-table" }, [
    el("thead", {}, [
      el("tr", {}, [
        el("th", {}, ["Project"]),
        el("th", {}, ["Last run"]),
        el("th", {}, ["Last change"]),
        el("th", {}, ["Snapshots"]),
        el("th", {}, ["Mirror"]),
        el("th", {}, ["History"]),
      ]),
    ]),
    el("tbody", {}, rows),
  ]);

  return el("section", {}, [header, table, ...oldLayoutNotes]);
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
    el("h2", {}, ["Search"]),
    form,
    resultsBox,
  ]);
}

async function runSearch(
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
function sourceLabel(source: string): string {
  if (source === "index" || source === "live") return source;
  return "archived";
}

function renderSearchResults(result: LocateResult, resultsBox: HTMLElement) {
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
    children.push(
      el(
        "ul",
        { class: "search-result-list" },
        result.results.map((hit) =>
          el("li", {}, [
            el("span", { class: `source-tag source-${hit.source}` }, [
              sourceLabel(hit.source),
            ]),
            hit.path,
          ]),
        ),
      ),
    );
  }
  resultsBox.replaceChildren(...children);
}

async function renderDashboard(binDir: string) {
  app.replaceChildren(el("h1", {}, ["bmug2"]), el("p", {}, ["Loading status…"]));
  let status: StatusResult;
  try {
    status = await invoke<StatusResult>("get_status", { binDir });
  } catch (err) {
    renderError(String(err), () => void renderDashboard(binDir));
    return;
  }
  app.replaceChildren(
    el("h1", {}, ["bmug2"]),
    buildStatusSection(status, binDir),
    buildSearchSection(binDir),
  );
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

async function renderSetup() {
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

function field(
  label: string,
  id: string,
  value: string,
): [HTMLDivElement, HTMLInputElement] {
  const input = el("input", { type: "text", id, value });
  const wrapper = el("div", { class: "field" }, [
    el("label", { for: id }, [label]),
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
        }
      },
    );
  });
  const row = el("div", { class: "field-row" }, [input, browseBtn]);
  const wrapper = el("div", { class: "field" }, [
    el("label", { for: id }, [label]),
    row,
  ]);
  return [wrapper, input];
}

function buildNewForm(defaults: DefaultPaths): HTMLFormElement {
  const [syncField, syncInput] = directoryField("SYNC directory", "sync-dir", defaults.sync_dir);
  const [backupField, backupInput] = directoryField(
    "BackUp directory",
    "backup-dir",
    defaults.backup_dir,
  );
  const [indexField, indexInput] = directoryField(
    "IndexDB directory",
    "index-dir",
    defaults.index_dir,
  );
  const [dirField, dirInput] = directoryField(
    "BMU install directory",
    "install-dir",
    defaults.install_dir,
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
  );
  const suggestions = buildSuggestionsBox((path) => {
    binInput.value = path;
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

async function init() {
  renderLoading();
  try {
    const existing = await invoke<string | null>("check_existing_install");
    if (existing) {
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
