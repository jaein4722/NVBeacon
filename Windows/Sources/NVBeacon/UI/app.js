"use strict";

// Flyout page. Mirrors the macOS popover (Sources/NVBeacon/StatusMenuView.swift).
// Swift sends domain data and decisions; this page owns presentation state only:
// collapsed servers and host sections (persisted), expanded GPUs, scroll and focus.
const host = window.chrome && window.chrome.webview;
const send = (message) => host && host.postMessage(JSON.stringify(message));

const view = {
  state: null,
  collapsedServers: loadSet("collapsedServers"),
  collapsedHosts: loadSet("collapsedHosts"),
  expandedGPUs: new Set(),
  justToggled: null,
  reportedHeight: 0,
};

function loadSet(key) {
  try { return new Set(JSON.parse(localStorage.getItem(key) || "[]")); } catch { return new Set(); }
}
function saveSet(key, set) {
  try { localStorage.setItem(key, JSON.stringify([...set])); } catch { /* storage unavailable */ }
}

// ---------- DOM helpers ----------

function h(tag, className, ...children) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const child of children) {
    if (child == null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}
function icon(name, className) {
  const wrapper = h("span", className);
  wrapper.innerHTML = ICONS[name];
  const svg = wrapper.firstElementChild;
  svg.setAttribute("aria-hidden", "true");
  if (className) svg.setAttribute("class", className);
  return svg;
}
function label(iconName, text, className) {
  return h("span", "label " + (className || ""), icon(iconName), h("span", "truncate", text));
}
function iconButton(iconName, title, onClick, key) {
  const button = h("button", "icon-button", icon(iconName));
  button.title = title;
  button.setAttribute("aria-label", title);
  button.dataset.key = key;
  button.addEventListener("click", onClick);
  return button;
}
function spinner() {
  const node = h("span", "spinner");
  node.setAttribute("role", "progressbar");
  return node;
}
// Always takes the spinner's width, so the buttons next to it never move when a
// refresh starts or ends (a click could otherwise land on a different button).
function spinnerSlot(active) {
  return h("span", "spinner-slot", active ? spinner() : null);
}

// ---------- Formatting ----------

function relative(ms) {
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (seconds < 60) return seconds + "s";
  return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s";
}
function memoryTint(ratio) {
  if (ratio >= 0.95) return "var(--red)";
  if (ratio >= 0.85) return "var(--orange)";
  return "var(--memory)";
}

// ---------- Components ----------

function summaryPill(title, value) {
  return h("div", "pill", h("span", "caption2 secondary", title), h("span", "pill-value", value));
}

// "Updated 12s"; once the data is older than 2 × refresh interval + 15 s it reads
// "Last update 3m ago" (macOS 0.9). The ticker below keeps both parts current.
function updatedPillParts(updatedAt) {
  const stale = Date.now() - updatedAt > (view.state?.staleAfterMs ?? Infinity);
  if (!stale) return [t("Updated"), relative(updatedAt)];
  return [t("Last update"), t("%@ ago", relative(updatedAt))];
}
function updatedPill(updatedAt) {
  const [title, value] = updatedPillParts(updatedAt);
  const pill = summaryPill(title, value);
  pill.dataset.updated = String(updatedAt);
  pill.title = new Date(updatedAt).toLocaleTimeString();
  return pill;
}

function pills(average, busy, total, processes, updatedAt) {
  const row = h("div", "pills",
    summaryPill(t("Avg"), average + "%"),
    summaryPill(t("Busy"), busy + "/" + total),
    summaryPill(t("Proc"), String(processes)));
  if (updatedAt) row.append(updatedPill(updatedAt));
  return row;
}

function metricBar(title, valueText, ratio, tint, tooltip) {
  const clamped = Math.min(Math.max(ratio || 0, 0), 1);
  const track = h("div", "track");
  if (clamped > 0) {
    const fill = h("div", "fill");
    fill.style.width = (clamped * 100).toFixed(2) + "%";
    fill.style.background = "linear-gradient(90deg, color-mix(in srgb, " + tint + " 72%, transparent), " + tint + ")";
    track.append(fill);
  }
  const node = h("div", "metric",
    h("div", "metric-head", h("span", "metric-title", title), h("span", "metric-value", valueText)),
    track);
  if (tooltip) node.title = tooltip;
  return node;
}

function headerStrip(state) {
  const fleet = state.fleet;
  const servers = state.servers;
  let title;
  const pollable = state.pollableServerCount;
  if (!servers.length) title = t("No server configured");
  else if (servers.length === 1) title = servers[0].name;
  else title = t("%@/%@ servers", pollable, servers.length);

  const top = h("div", "row baseline", label("serverRack", title, "headline"), h("span", "spacer"),
    spinnerSlot(fleet.isRefreshing));
  if (state.recordsGPUHistory) {
    top.append(iconButton("chart", t("Open GPU history"), () => send({ type: "openHistory" }), "open-history"));
  }
  // Popover ⇄ window. In window mode "keep on top" lives in the title bar.
  if (state.displayMode === "window") {
    top.append(iconButton("popover", t("Show as Popover"), () => send({ type: "setDisplayMode", mode: "popover" }), "to-popover"));
  } else {
    top.append(iconButton("openWindow", t("Show as Window"), () => send({ type: "setDisplayMode", mode: "window" }), "to-window"));
  }
  if (servers.length) {
    top.append(iconButton("refresh", t("Refresh now and restart polling if needed"),
      () => send({ type: "refresh" }), "refresh-all"));
  }
  top.append(iconButton("gear", t("Settings…"), () => send({ type: "settings" }), "open-settings"));

  const strip = h("div", "card header", top);
  if (fleet.gpuCount > 0) {
    strip.append(pills(fleet.averageUtilization, fleet.busyCount, fleet.gpuCount, fleet.processCount, fleet.latestUpdate));
  } else {
    const text = !servers.length
      ? t("Open Settings with the gear button to add a server.")
      : pollable === 0
        ? t("No enabled server is ready for polling.")
        : t("Waiting for the first polling result.");
    strip.append(h("span", "caption secondary", text));
  }
  if (state.displayMode !== "window") {
    strip.append(h("span", "caption2 secondary", t("Right-click the tray icon for more, including Quit.")));
  }
  if (servers.length === 1 && servers[0].myUser) strip.append(myProcessesLabel(servers[0].myUser));
  const processes = fleet.watchedProcessCount, idle = fleet.watchedIdleCount;
  if (processes + idle > 0) {
    const parts = [];
    if (processes) parts.push(t("%@ process exit", processes));
    if (idle) parts.push(t("%@ GPU idle", idle));
    strip.append(h("span", "watching", icon("bellFill"), t("Watching %@", parts.join(" · "))));
  }
  return strip;
}

function hostInformation(server) {
  const hostData = server.host;
  const expanded = !view.collapsedHosts.has(server.id);
  const toggle = h("button", "host-toggle",
    label("desktop", t("Host Information")),
    icon("chevronRight", "chevron"));
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.dataset.key = "host:" + server.id;
  toggle.addEventListener("click", () => {
    expanded ? view.collapsedHosts.add(server.id) : view.collapsedHosts.delete(server.id);
    saveSet("collapsedHosts", view.collapsedHosts);
    view.justToggled = "host:" + server.id;
    render();
  });
  const box = h("div", "host", toggle);
  if (!expanded) return box;

  const body = h("div", "host-body" + (view.justToggled === "host:" + server.id ? " appear" : ""));
  if (hostData.cpuPercent != null) {
    body.append(metricBar("CPU", hostData.cpuPercent + "%", hostData.cpuPercent / 100, "var(--orange)"));
  } else {
    body.append(h("span", "caption2 secondary", hostData.cpuMeasuring ? t("CPU: Measuring…") : t("CPU: Unavailable")));
  }
  body.append(h("div", "divider"));

  const memory = hostData.memory;
  if (memory) {
    const memoryGroup = h("div", "host-body");
    memoryGroup.style.paddingTop = "0";
    memoryGroup.style.gap = "6px";
    const notice = memory.ratio >= 0.95 ? t(" · Very high usage") : memory.ratio >= 0.85 ? t(" · High usage") : "";
    memoryGroup.append(metricBar("RAM", memory.usedPercent + "% · " + memory.usedText + " / " + memory.totalText, memory.ratio,
      memoryTint(memory.ratio), t("Available: %@", memory.availableText) + notice));
    if (memory.swapTotalKiB == null) {
      memoryGroup.append(h("span", "caption2 secondary", t("Swap: Unavailable")));
    } else if (memory.swapTotalKiB > 0) {
      memoryGroup.append(metricBar("Swap", memory.swapUsedText + " / " + memory.swapTotalText, memory.swapRatio, memoryTint(memory.swapRatio)));
    }
    body.append(memoryGroup);
  } else {
    body.append(h("span", "caption2 secondary", t("RAM / Swap: Unavailable")));
  }
  body.append(h("div", "divider"));

  const network = hostData.network;
  if (network) {
    const head = h("div", "network-head",
      label("network", t("Network"), "caption2 semibold secondary"),
      h("span", "spacer"));
    const down = h("span", "rate", icon("arrowDown"), network.downText);
    down.firstChild.style.color = "var(--memory)";
    const up = h("span", "rate", icon("arrowUp"), network.upText);
    up.firstChild.style.color = "var(--util)";
    head.append(down, up);
    const lines = [network.interfaces.length
      ? t("Interfaces") + ": " + network.interfaces.join(", ")
      : t("The server did not report any network interface.")];
    lines.push(t("Total since boot") + ": " + network.totalText);
    if (!network.hasRates) lines.push(t("The transfer rate is measured from the next refresh on."));
    const group = h("div", "", head, h("div", "caption2 secondary mono truncate", t("Total since boot") + " " + network.totalText));
    group.style.display = "flex";
    group.style.flexDirection = "column";
    group.style.gap = "4px";
    group.title = lines.join("\n");
    body.append(group);
  } else {
    body.append(h("span", "caption2 secondary", t("Network: Unavailable")));
  }
  box.append(body);
  return box;
}

function mineBadge() {
  return h("span", "mine-badge", t("Mine"));
}

function myProcessesLabel(user) {
  return h("span", "my-processes", icon("person"), t("My processes: %@", user));
}

function processRow(server, gpu, process) {
  const nameLine = h("span", "row", h("span", "caption semibold truncate", process.name), process.isMine ? mineBadge() : null);
  nameLine.style.gap = "6px";
  // macOS's "Notify / Watching" capsule: alert when this process exits.
  const watch = h("button", "watch-button" + (process.isWatched ? " on" : ""),
    icon(process.isWatched ? "bellFill" : "bellSmall"), process.isWatched ? t("Watching") : t("Notify"));
  watch.title = process.isWatched ? t("Disable process exit alert") : t("Enable process exit alert");
  watch.setAttribute("aria-pressed", String(!!process.isWatched));
  watch.dataset.key = "watch:" + server.id + ":" + gpu.index + ":" + process.pid;
  watch.addEventListener("click", () => send({ type: "toggleExitWatch", serverId: server.id, gpu: gpu.index, pid: process.pid }));
  const main = h("div", "process-main",
    h("span", "process-user truncate", process.user),
    h("div", "process-name", nameLine, h("span", "caption2 secondary mono", "PID " + process.pid)),
    h("span", "spacer"),
    h("span", "caption2 secondary mono", process.memoryText),
    watch);
  const row = h("div", "process" + (process.isMine ? " mine" : ""), main);
  if (process.command) {
    const command = h("div", "process-command caption2 secondary truncate", process.command);
    command.title = process.command;
    row.append(command);
  }
  return row;
}

function gpuRow(server, gpu) {
  const key = server.id + ":" + gpu.index;
  const expanded = view.expandedGPUs.has(key);
  const head = h("div", "row baseline",
    h("span", "headline", "GPU " + gpu.index),
    h("span", "caption secondary truncate gpu-name", gpu.name),
    h("span", "spacer"),
    h("span", "gpu-stats", gpu.temperature + " · " + gpu.processes.length + "p · " + gpu.utilization + "%"),
    gpu.hasMine ? mineBadge() : null,
    icon("chevronCircle", "chevron-circle"));
  const bars = h("div", "metrics",
    metricBar("Util", gpu.utilization + "%", gpu.utilization / 100, "var(--util)"),
    metricBar("Memory", gpu.memoryPercent + "% · " + gpu.memoryUsedMB + "/" + gpu.memoryTotalMB + "MB",
      gpu.memoryTotalMB ? gpu.memoryUsedMB / gpu.memoryTotalMB : 0, "var(--memory)"));
  const toggle = h("button", "gpu-toggle", head, bars);
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.dataset.key = "gpu:" + key;
  toggle.addEventListener("click", () => {
    if (expanded) {
      view.expandedGPUs.delete(key);
    } else {
      view.expandedGPUs.add(key);
      // Like macOS: expanding fetches user names and full command lines.
      if (gpu.processes.length) send({ type: "loadProcessDetails", serverId: server.id, gpu: gpu.index });
    }
    view.justToggled = "gpu:" + key;
    render();
  });

  // macOS layout: the idle-alert star sits left of the row, outside the expand button.
  const star = h("button", "star-button" + (gpu.isWatchingIdle ? " on" : ""), icon(gpu.isWatchingIdle ? "starFill" : "star"));
  star.title = gpu.isWatchingIdle ? t("Disable GPU idle alert") : t("Enable GPU idle alert");
  star.setAttribute("aria-label", star.title);
  star.setAttribute("aria-pressed", String(!!gpu.isWatchingIdle));
  star.dataset.key = "star:" + key;
  star.addEventListener("click", () => send({ type: "toggleIdleWatch", serverId: server.id, gpu: gpu.index }));

  const card = h("div", "gpu" + (expanded ? " expanded" : "") + (gpu.hasMine ? " mine" : ""), h("div", "gpu-line", star, toggle));
  if (gpu.isWatchingIdle) {
    const armed = h("span", "armed", icon("starFill"), t("Idle notification armed"));
    card.append(h("div", "armed-row", armed));
  }
  if (expanded) {
    const list = h("div", "processes" + (view.justToggled === "gpu:" + key ? " appear" : ""), h("div", "divider"));
    if ((server.loadingDetailGPUs || []).includes(gpu.index)) {
      const loading = h("div", "row", spinner(), h("span", "caption secondary", t("Loading process details...")));
      loading.style.gap = "6px";
      list.append(loading);
    }
    if (!gpu.processes.length) {
      list.append(h("span", "caption secondary", t("There are no active compute processes reported on this GPU.")));
    }
    for (const process of gpu.processes) list.append(processRow(server, gpu, process));
    card.append(list);
  }
  return card;
}

function serverSection(server) {
  const expanded = !view.collapsedServers.has(server.id);
  const toggle = h("button", "server-toggle" + (expanded ? " expanded" : ""),
    icon("chevronRight", "chevron"),
    label("serverRack", server.name, "subheadline semibold"));
  toggle.title = expanded ? t("Collapse this server") : t("Expand this server");
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.dataset.key = "server:" + server.id;
  toggle.addEventListener("click", () => {
    expanded ? view.collapsedServers.add(server.id) : view.collapsedServers.delete(server.id);
    saveSet("collapsedServers", view.collapsedServers);
    view.justToggled = "server:" + server.id;
    render();
  });

  const head = h("div", "row baseline", toggle);
  if (!server.isEnabled) head.append(h("span", "badge", t("Disabled")));
  head.append(h("span", "spacer"));
  if (!expanded) {
    if (server.busyCount != null) {
      head.append(h("span", "caption2 secondary mono", "GPU " + server.busyCount + "/" + server.gpus.length + " · " + server.averageUtilization + "%"));
    }
    if (server.error) {
      const warning = icon("warning", "warning-icon");
      const holder = h("span", "", warning);
      holder.title = server.error;
      head.append(holder);
    }
  }
  const pollable = server.isEnabled && !server.inactiveReason;
  if (pollable) {
    head.append(spinnerSlot(server.isRefreshing));
    head.append(iconButton("refresh", t("Refresh this server now"),
      () => send({ type: "refreshServer", id: server.id }), "refresh:" + server.id));
  }

  const section = h("section", "card server" + (server.isEnabled ? "" : " disabled"), head);
  if (!expanded) return section;

  const details = h("div", "details" + (view.justToggled === "server:" + server.id ? " appear" : ""));
  if (!server.isEnabled) {
    details.append(h("div", "message secondary", t("This server is disabled in Settings.")));
  } else if (server.inactiveReason === "password") {
    details.append(h("div", "message orange", t("Save the SSH password for this server in Settings. Polling is paused until a password is saved.")));
  } else if (server.inactiveReason === "passwordRejected") {
    details.append(h("div", "message orange", t("The server rejected the saved password, so polling stopped to avoid locking the account. Save the password again in Settings to resume.")));
    if (server.error) details.append(h("div", "message secondary", server.error));
  } else if (server.inactiveReason === "sshTooOld") {
    details.append(h("div", "message orange", server.error || ""));
  } else if (server.inactiveReason === "target") {
    details.append(h("div", "message secondary", t("Enter an SSH target for this server in Settings.")));
  } else if (server.updatedAt) {
    details.append(pills(server.averageUtilization, server.busyCount, server.gpus.length, server.processCount, server.updatedAt));
    if (server.host) details.append(hostInformation(server));
    for (const gpu of server.gpus) details.append(gpuRow(server, gpu));
    if (server.error) details.append(h("div", "message orange", server.error));
    if (server.detailError) {
      details.append(h("div", "message orange", t("Failed to load process details: %@", server.detailError)));
    }
    if (server.myUser && view.state.servers.length > 1) details.append(myProcessesLabel(server.myUser));
  } else {
    details.append(h("div", "message" + (server.error ? " orange" : " secondary"),
      server.error || t("Waiting for the first polling result.")));
  }
  section.append(details);
  return section;
}

// ---------- Window mode title bar ----------

// The system caption is removed in window mode; this bar replaces it. The bar
// itself drags the window (app-region: drag); its buttons opt out.
function captionButton(iconName, title, onClick, className) {
  const button = h("button", "caption-button " + (className || ""), icon(iconName));
  button.title = title;
  button.setAttribute("aria-label", title);
  button.dataset.key = "caption:" + iconName;
  button.addEventListener("click", onClick);
  return button;
}

function renderTitleBar(state) {
  let bar = document.getElementById("titlebar");
  if (state.displayMode !== "window") {
    if (bar) bar.remove();
    document.body.classList.remove("window-mode");
    return;
  }
  document.body.classList.add("window-mode");
  if (!bar) {
    bar = h("header", "titlebar");
    bar.id = "titlebar";
    document.body.prepend(bar);
  }
  const focusedKey = document.activeElement?.dataset?.key;
  const pinned = !!state.alwaysOnTop;
  const pin = captionButton(pinned ? "pinFill" : "pin",
    pinned ? t("Stop keeping the window on top") : t("Keep the window on top"),
    () => send({ type: "togglePin" }), pinned ? "active" : "");
  pin.setAttribute("aria-pressed", String(pinned));
  bar.replaceChildren(
    h("span", "titlebar-title", icon("serverRack"), "NVBeacon"),
    h("span", "spacer"),
    pin,
    captionButton("minimize", t("Minimize"), () => send({ type: "minimizeWindow" })),
    captionButton("close", t("Close"), () => send({ type: "closeWindow" }), "close"));
  if (focusedKey && focusedKey.startsWith("caption:")) bar.querySelector('[data-key="' + CSS.escape(focusedKey) + '"]')?.focus();
}

// ---------- Rendering ----------

function render() {
  const state = view.state;
  if (!state) return;
  document.documentElement.lang = state.language;
  document.documentElement.dataset.theme = state.theme || "light";
  renderTitleBar(state);
  const root = document.getElementById("root");
  const content = document.getElementById("content");
  const scroll = root.scrollTop;
  const focusedKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;

  // Drop expanded GPUs that no longer exist, as the macOS view does.
  const known = new Set(state.servers.flatMap((s) => s.gpus.map((g) => s.id + ":" + g.index)));
  for (const key of view.expandedGPUs) if (!known.has(key)) view.expandedGPUs.delete(key);

  const nodes = [headerStrip(state)];
  if (!state.servers.length) {
    nodes.push(h("div", "subheadline secondary empty", t("No GPU data is available yet.")));
  }
  for (const server of state.servers) nodes.push(serverSection(server));
  if (state.notice) nodes.push(h("div", "notice", icon("info"), state.notice));
  content.replaceChildren(...nodes);
  view.justToggled = null;

  root.scrollTop = scroll;
  if (focusedKey) {
    const again = content.querySelector('[data-key="' + CSS.escape(focusedKey) + '"]');
    if (again) again.focus({ preventScroll: true });
  }
  reportHeight();
}

function reportHeight() {
  const height = Math.ceil(document.getElementById("content").getBoundingClientRect().height);
  if (Math.abs(height - view.reportedHeight) >= 1) {
    view.reportedHeight = height;
    send({ type: "size", height });
  }
}

// The "Updated" pills tick every second without a full re-render.
setInterval(() => {
  for (const pill of document.querySelectorAll("[data-updated]")) {
    const [title, value] = updatedPillParts(Number(pill.dataset.updated));
    pill.firstChild.textContent = title;
    pill.lastChild.textContent = value;
  }
}, 1000);

document.addEventListener("keydown", (event) => { if (event.key === "Escape") send({ type: "close" }); });
document.addEventListener("contextmenu", (event) => event.preventDefault());

if (host) {
  host.addEventListener("message", (event) => {
    const message = event.data;
    if (message && message.type === "state") {
      view.state = message;
      render();
      send({ type: "ack", sentAt: message.sentAt });
    }
  });
}
send({ type: "ready", width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio });
