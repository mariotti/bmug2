// main.ts captures `#app` once at module load (`const app = document.querySelector("#app")!`).
// Runs before main.ts is imported (vitest setupFiles execute ahead of each test file's own
// module graph), so that capture finds a real node instead of null.
document.body.innerHTML = '<div id="app"></div>';
