import { invoke } from "@tauri-apps/api/core";

// First-run flow: check for a saved install, otherwise offer to
// install a new copy or point at an existing one. Wording below is
// ported from bin/backmeup.configure.sh's own prompts/tips, not
// reinvented - keep the two in sync if either changes.

interface DefaultPaths {
  sync_dir: string;
  backup_dir: string;
  index_dir: string;
  install_path: string;
  install_dir: string;
}

interface InstallOutcome {
  bin_dir: string;
  log: string;
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

function renderInstalled(binDir: string) {
  app.replaceChildren(
    el("h1", {}, ["bmug2"]),
    el("p", {}, [`Installed at `, el("code", {}, [binDir]), "."]),
    el("p", {}, [
      "Status and search screens aren't built yet — use ",
      el("code", {}, ["backmeup.status.sh"]),
      " / ",
      el("code", {}, ["backmeup.locate.sh"]),
      " on the command line for now.",
    ]),
  );
}

function renderError(message: string, retry: () => void) {
  const pre = el("pre", { class: "log log-error" }, [message]);
  const backBtn = el("button", { type: "button" }, ["Back"]);
  backBtn.addEventListener("click", retry);
  app.replaceChildren(
    el("h1", {}, ["bmug2"]),
    el("p", { class: "error-heading" }, ["Setup failed:"]),
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

function buildNewForm(defaults: DefaultPaths): HTMLFormElement {
  const [syncField, syncInput] = field("SYNC directory", "sync-dir", defaults.sync_dir);
  const [backupField, backupInput] = field(
    "BackUp directory",
    "backup-dir",
    defaults.backup_dir,
  );
  const [indexField, indexInput] = field(
    "IndexDB directory",
    "index-dir",
    defaults.index_dir,
  );
  const [pathField, pathInput] = field(
    "Base install directory",
    "install-path",
    defaults.install_path,
  );
  const [dirField, dirInput] = field(
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
          "a replacement for these. The install directories below are a " +
          "different thing — where the bmug2 program itself lives, " +
          "on your regular system disk.",
      ]),
      syncField,
      backupField,
      indexField,
      pathField,
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
      install_path: pathInput.value,
      install_dir: dirInput.value,
    });
  });

  return form;
}

function buildExistingForm(): HTMLFormElement {
  const [binField, binInput] = field(
    "bmug2 bin directory (contains backmeup.sh)",
    "bin-dir",
    "",
  );
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
    renderInstalled(outcome.bin_dir);
  } catch (err) {
    renderError(String(err), renderSetup);
  }
}

async function init() {
  renderLoading();
  try {
    const existing = await invoke<string | null>("check_existing_install");
    if (existing) {
      renderInstalled(existing);
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
