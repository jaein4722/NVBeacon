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

const t = (english, korean) => (view.state && view.state.language === "ko" ? korean : english);

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

function summaryPill(title, value, updatedAt) {
  const valueNode = h("span", "pill-value", value);
  if (updatedAt) {
    valueNode.dataset.updated = String(updatedAt);
    valueNode.title = new Date(updatedAt).toLocaleTimeString();
  }
  return h("div", "pill", h("span", "caption2 secondary", title), valueNode);
}

function pills(average, busy, total, processes, updatedAt) {
  const row = h("div", "pills",
    summaryPill(t("Avg", "평균"), average + "%"),
    summaryPill(t("Busy", "사용중"), busy + "/" + total),
    summaryPill(t("Proc", "프로세스"), String(processes)));
  if (updatedAt) row.append(summaryPill(t("Updated", "업데이트"), relative(updatedAt), updatedAt));
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
  if (!servers.length) title = t("No server configured", "서버 미설정");
  else if (servers.length === 1) title = servers[0].name;
  else title = t(servers.length + "/" + servers.length + " servers", servers.length + "/" + servers.length + " 서버");

  const top = h("div", "row baseline", label("serverRack", title, "headline"), h("span", "spacer"));
  if (servers.length) {
    top.append(iconButton("refresh", t("Refresh now and restart polling if needed", "필요하면 polling을 다시 시작하면서 새로고침"),
      () => send({ type: "refresh" }), "refresh-all"));
  }
  if (fleet.isRefreshing) top.append(spinner());

  const strip = h("div", "card header", top);
  if (fleet.gpuCount > 0) {
    strip.append(pills(fleet.averageUtilization, fleet.busyCount, fleet.gpuCount, fleet.processCount, fleet.latestUpdate));
  } else {
    const text = !servers.length
      ? t("Right-click the tray icon and edit servers.txt to add a server.", "트레이 아이콘을 우클릭해 servers.txt에 서버를 추가하세요.")
      : t("Waiting for the first polling result.", "첫 polling 결과를 기다리는 중입니다.");
    strip.append(h("span", "caption secondary", text));
  }
  strip.append(h("span", "caption2 secondary", t("Right-click the tray icon for settings and quit.", "설정과 종료는 트레이 아이콘 우클릭으로 열 수 있습니다.")));
  return strip;
}

function hostInformation(server) {
  const hostData = server.host;
  const expanded = !view.collapsedHosts.has(server.id);
  const toggle = h("button", "host-toggle",
    label("desktop", t("Host Information", "호스트 정보")),
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
    body.append(h("span", "caption2 secondary", hostData.cpuMeasuring ? t("CPU: Measuring…", "CPU: 측정 중…") : t("CPU: Unavailable", "CPU: 확인 불가")));
  }
  body.append(h("div", "divider"));

  const memory = hostData.memory;
  if (memory) {
    const memoryGroup = h("div", "host-body");
    memoryGroup.style.paddingTop = "0";
    memoryGroup.style.gap = "6px";
    const notice = memory.ratio >= 0.95 ? t(" · Very high usage", " · 매우 높은 사용량") : memory.ratio >= 0.85 ? t(" · High usage", " · 높은 사용량") : "";
    memoryGroup.append(metricBar("RAM", memory.usedPercent + "% · " + memory.usedText + " / " + memory.totalText, memory.ratio,
      memoryTint(memory.ratio), t("Available: ", "사용 가능: ") + memory.availableText + notice));
    if (memory.swapTotalKiB == null) {
      memoryGroup.append(h("span", "caption2 secondary", t("Swap: Unavailable", "Swap: 확인 불가")));
    } else if (memory.swapTotalKiB > 0) {
      memoryGroup.append(metricBar("Swap", memory.swapUsedText + " / " + memory.swapTotalText, memory.swapRatio, memoryTint(memory.swapRatio)));
    }
    body.append(memoryGroup);
  } else {
    body.append(h("span", "caption2 secondary", t("RAM / Swap: Unavailable", "RAM / Swap: 확인 불가")));
  }
  body.append(h("div", "divider"));

  const network = hostData.network;
  if (network) {
    const head = h("div", "network-head",
      label("network", t("Network", "네트워크"), "caption2 semibold secondary"),
      h("span", "spacer"));
    const down = h("span", "rate", icon("arrowDown"), network.downText);
    down.firstChild.style.color = "var(--memory)";
    const up = h("span", "rate", icon("arrowUp"), network.upText);
    up.firstChild.style.color = "var(--util)";
    head.append(down, up);
    const lines = [network.interfaces.length
      ? t("Interfaces", "인터페이스") + ": " + network.interfaces.join(", ")
      : t("The server did not report any network interface.", "서버에서 네트워크 인터페이스 정보를 가져오지 못했습니다.")];
    lines.push(t("Total since boot", "부팅 후 누적") + ": " + network.totalText);
    if (!network.hasRates) lines.push(t("The transfer rate is measured from the next refresh on.", "전송 속도는 다음 새로고침부터 표시됩니다."));
    const group = h("div", "", head, h("div", "caption2 secondary mono truncate", t("Total since boot", "부팅 후 누적") + " " + network.totalText));
    group.style.display = "flex";
    group.style.flexDirection = "column";
    group.style.gap = "4px";
    group.title = lines.join("\n");
    body.append(group);
  } else {
    body.append(h("span", "caption2 secondary", t("Network: Unavailable", "네트워크: 확인 불가")));
  }
  box.append(body);
  return box;
}

function processRow(process) {
  const main = h("div", "process-main",
    h("span", "process-user truncate", process.user),
    h("div", "process-name",
      h("span", "caption semibold truncate", process.name),
      h("span", "caption2 secondary mono", "PID " + process.pid)),
    h("span", "spacer"),
    h("span", "caption2 secondary mono", process.memoryText));
  const row = h("div", "process", main);
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
    icon("chevronCircle", "chevron-circle"));
  const bars = h("div", "metrics",
    metricBar("Util", gpu.utilization + "%", gpu.utilization / 100, "var(--util)"),
    metricBar("Memory", gpu.memoryPercent + "% · " + gpu.memoryUsedMB + "/" + gpu.memoryTotalMB + "MB",
      gpu.memoryTotalMB ? gpu.memoryUsedMB / gpu.memoryTotalMB : 0, "var(--memory)"));
  const toggle = h("button", "gpu-toggle", head, bars);
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.dataset.key = "gpu:" + key;
  toggle.addEventListener("click", () => {
    expanded ? view.expandedGPUs.delete(key) : view.expandedGPUs.add(key);
    view.justToggled = "gpu:" + key;
    render();
  });

  const card = h("div", "gpu" + (expanded ? " expanded" : ""), toggle);
  if (expanded) {
    const list = h("div", "processes" + (view.justToggled === "gpu:" + key ? " appear" : ""), h("div", "divider"));
    if (!gpu.processes.length) {
      list.append(h("span", "caption secondary", t("There are no active compute processes reported on this GPU.", "이 GPU에서 보고된 active compute process가 없습니다.")));
    }
    for (const process of gpu.processes) list.append(processRow(process));
    card.append(list);
  }
  return card;
}

function serverSection(server) {
  const expanded = !view.collapsedServers.has(server.id);
  const toggle = h("button", "server-toggle" + (expanded ? " expanded" : ""),
    icon("chevronRight", "chevron"),
    label("serverRack", server.name, "subheadline semibold"));
  toggle.title = expanded ? t("Collapse this server", "이 서버 접기") : t("Expand this server", "이 서버 펼치기");
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.dataset.key = "server:" + server.id;
  toggle.addEventListener("click", () => {
    expanded ? view.collapsedServers.add(server.id) : view.collapsedServers.delete(server.id);
    saveSet("collapsedServers", view.collapsedServers);
    view.justToggled = "server:" + server.id;
    render();
  });

  const head = h("div", "row baseline", toggle, h("span", "spacer"));
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
  head.append(iconButton("refresh", t("Refresh this server now", "이 서버를 지금 새로고침"),
    () => send({ type: "refreshServer", id: server.id }), "refresh:" + server.id));
  if (server.isRefreshing) head.append(spinner());

  const section = h("section", "card server", head);
  if (!expanded) return section;

  const details = h("div", "details" + (view.justToggled === "server:" + server.id ? " appear" : ""));
  if (server.updatedAt) {
    details.append(pills(server.averageUtilization, server.busyCount, server.gpus.length, server.processCount, server.updatedAt));
    if (server.host) details.append(hostInformation(server));
    for (const gpu of server.gpus) details.append(gpuRow(server, gpu));
    if (server.error) details.append(h("div", "message orange", server.error));
  } else {
    details.append(h("div", "message" + (server.error ? " orange" : " secondary"),
      server.error || t("Waiting for the first polling result.", "첫 polling 결과를 기다리는 중입니다.")));
  }
  section.append(details);
  return section;
}

// ---------- Rendering ----------

function render() {
  const state = view.state;
  if (!state) return;
  document.documentElement.lang = state.language;
  const root = document.getElementById("root");
  const content = document.getElementById("content");
  const scroll = root.scrollTop;
  const focusedKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;

  // Drop expanded GPUs that no longer exist, as the macOS view does.
  const known = new Set(state.servers.flatMap((s) => s.gpus.map((g) => s.id + ":" + g.index)));
  for (const key of view.expandedGPUs) if (!known.has(key)) view.expandedGPUs.delete(key);

  const nodes = [headerStrip(state)];
  if (!state.servers.length) {
    nodes.push(h("div", "subheadline secondary empty", t("No GPU data is available yet.", "표시할 GPU 데이터가 아직 없습니다.")));
  }
  for (const server of state.servers) nodes.push(serverSection(server));
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
  for (const node of document.querySelectorAll("[data-updated]")) node.textContent = relative(Number(node.dataset.updated));
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
