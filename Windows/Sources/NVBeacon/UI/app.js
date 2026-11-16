"use strict";

// Presentation only. Swift owns collection, parsing, alert rules and settings;
// this page owns view state such as collapsed servers and expanded process lists.
const view = { collapsed: new Set(), expanded: new Set(), lastState: null };
const host = window.chrome && window.chrome.webview;

function send(message) {
  if (host) host.postMessage(JSON.stringify(message));
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const gb = (mb) => (mb / 1024).toFixed(1);
const level = (percent) => (percent >= 70 ? "hot" : percent >= 30 ? "warn" : "");

function time(ms) {
  return ms ? new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "";
}

function meter(label, ratio, value, extraClass) {
  const row = el("div", "meter");
  row.append(el("span", "meter-label", label));
  const track = el("div", "track");
  const fill = el("div", "fill " + extraClass);
  fill.style.width = Math.max(0, Math.min(100, ratio * 100)).toFixed(1) + "%";
  track.append(fill);
  row.append(track, el("span", "meter-value", value));
  return row;
}

function gpuCard(server, gpu) {
  const card = el("div", "gpu");
  const top = el("div", "gpu-top");
  const name = el("div", "gpu-name", "GPU " + gpu.index);
  name.append(el("small", "", gpu.name.replace(/^NVIDIA /, "")));
  top.append(name, el("span", "gpu-temp", gpu.temperature == null ? "" : gpu.temperature + "°C"));
  card.append(top);
  card.append(meter("GPU", gpu.utilization / 100, gpu.utilization + "%", level(gpu.utilization)));
  const memoryRatio = gpu.memoryTotalMB ? gpu.memoryUsedMB / gpu.memoryTotalMB : 0;
  card.append(meter("VRAM", memoryRatio, gb(gpu.memoryUsedMB) + " / " + gb(gpu.memoryTotalMB) + " GB", "memory"));

  if (gpu.processes.length) {
    const key = server.id + "#" + gpu.index;
    const open = view.expanded.has(key);
    const toggle = el("button", "processes-toggle",
      (open ? "▾ " : "▸ ") + gpu.processes.length + (gpu.processes.length === 1 ? " process" : " processes"));
    toggle.setAttribute("aria-expanded", String(open));
    toggle.addEventListener("click", () => {
      open ? view.expanded.delete(key) : view.expanded.add(key);
      render(view.lastState);
    });
    card.append(toggle);
    if (open) {
      const list = el("div", "processes");
      for (const process of gpu.processes) {
        const row = el("div", "process");
        const command = el("span", "process-command", process.command);
        command.title = process.command;
        row.append(command, el("span", "process-meta", process.user + " · " + process.memoryMB + " MB · " + process.pid));
        list.append(row);
      }
      card.append(list);
    }
  }
  return card;
}

function serverSection(server) {
  const section = el("section", "server" + (view.collapsed.has(server.id) ? " collapsed" : ""));
  const header = el("button", "server-header");
  header.setAttribute("aria-expanded", String(!view.collapsed.has(server.id)));
  header.innerHTML = '<svg class="chevron" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 4.5 6 8l3.5-3.5"/></svg>';
  const nameCell = el("span", "server-name");
  const status = server.error ? (server.stale ? "stale" : "error") : server.updatedAt ? "" : "pending";
  nameCell.append(el("span", "status-dot " + status), document.createTextNode(server.target));
  let meta = "";
  if (server.averageUtilization != null) {
    meta = server.averageUtilization + "% · " + gb(server.memoryUsedMB) + "/" + gb(server.memoryTotalMB) + " GB";
  } else if (!server.error) {
    meta = "Connecting…";
  }
  header.append(nameCell, el("span", "server-meta", meta));
  header.addEventListener("click", () => {
    view.collapsed.has(server.id) ? view.collapsed.delete(server.id) : view.collapsed.add(server.id);
    render(view.lastState);
  });
  section.append(header);

  const body = el("div", "server-body");
  if (server.error) body.append(el("div", "error", server.error));
  for (const gpu of server.gpus) body.append(gpuCard(server, gpu));
  if (server.cpuPercent != null || server.ramPercent != null) {
    const hostRow = el("div", "host");
    if (server.cpuPercent != null) {
      const cpu = el("span", "", "CPU ");
      cpu.append(el("strong", "", server.cpuPercent + "%"));
      hostRow.append(cpu);
    }
    if (server.ramPercent != null) {
      const ram = el("span", "", "RAM ");
      ram.append(el("strong", "", server.ramPercent + "%"), document.createTextNode(" · " + server.ramText));
      hostRow.append(ram);
    }
    body.append(hostRow);
  }
  section.append(body);
  return section;
}

function render(state) {
  if (!state) return;
  view.lastState = state;
  const container = document.getElementById("servers");
  const scroll = container.scrollTop;
  container.replaceChildren();
  if (!state.servers.length) {
    container.append(document.getElementById("empty").content.cloneNode(true));
  }
  for (const server of state.servers) container.append(serverSection(server));
  container.scrollTop = scroll;

  const latest = Math.max(0, ...state.servers.map((s) => s.updatedAt || 0));
  const errors = state.servers.filter((s) => s.error).length;
  const gpus = state.servers.reduce((n, s) => n + s.gpus.length, 0);
  document.getElementById("summary").textContent =
    state.servers.length + (state.servers.length === 1 ? " server" : " servers") + " · " + gpus + " GPUs" +
    (errors ? " · " + errors + " with errors" : "") + (latest ? " · " + time(latest) : "");
}

document.getElementById("refresh").addEventListener("click", (event) => {
  const button = event.currentTarget;
  button.classList.remove("spinning");
  void button.offsetWidth;
  button.classList.add("spinning");
  send({ type: "refresh" });
});
document.getElementById("menu").addEventListener("click", () => send({ type: "menu" }));
document.getElementById("edit").addEventListener("click", () => send({ type: "editServers" }));
document.getElementById("quit").addEventListener("click", () => send({ type: "quit" }));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") send({ type: "close" });
});
document.addEventListener("contextmenu", (event) => event.preventDefault());

if (host) {
  host.addEventListener("message", (event) => {
    const message = event.data;
    if (message && message.type === "state") {
      render(message);
      send({ type: "ack", sentAt: message.sentAt });
    }
  });
}
send({ type: "ready", width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio });
