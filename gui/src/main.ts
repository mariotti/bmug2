import { invoke } from "@tauri-apps/api/core";

// Skeleton only: proves the Rust bridge is reachable. The next phase
// replaces this with real calls into the installed bmug2 core (a
// first-run setup screen, then a status dashboard and search box -
// see docs/MANUAL.md's --json output modes and non-interactive
// backmeup.configure.sh flags this UI will drive).
window.addEventListener("DOMContentLoaded", async () => {
  const el = document.querySelector<HTMLElement>("#bridge-status");
  if (!el) return;
  try {
    el.textContent = await invoke<string>("bridge_check");
  } catch (err) {
    el.textContent = `Bridge check failed: ${err}`;
  }
});
