"use strict";

// GPU History window. Mirrors macOS GPUHistoryWindowView / GPUHistoryView.
// Swift prepares the plot (GPUHistoryRenderData); this page draws it as SVG and
// owns only the pickers, the hovered time and the chart geometry.
const host = window.chrome && window.chrome.webview;
const send = (message) => host && host.postMessage(JSON.stringify(message));
const SVG = "http://www.w3.org/2000/svg";
const TOTAL = "GPU total";
// macOS palette: blue, orange, green, purple, pink, cyan, indigo, mint, teal, brown.
const PALETTE = ["#0a84ff", "#ff9f0a", "#30d158", "#bf5af2", "#ff375f", "#64d2ff", "#5e5ce6", "#63e6e2", "#40c8e0", "#ac8e68"];

const ui = { servers: [], language: "en", recording: true, serverId: null, gpu: null, hours: 1, data: null, selected: null };
try { ui.serverId = localStorage.getItem("historyServer"); } catch { /* storage unavailable */ }

function h(tag, className, ...children) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const child of children) if (child != null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return node;
}
function s(tag, attributes) {
  const node = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attributes || {})) node.setAttribute(key, value);
  return node;
}

function colorFor(user) {
  const domain = (ui.data && ui.data.colorUsers) || [];
  const index = domain.indexOf(user);
  if (index < 0) return PALETTE[0];
  if (index < PALETTE.length) return PALETTE[index];
  const extra = domain.length - PALETTE.length;
  return "hsl(" + Math.round(360 * (index - PALETTE.length) / Math.max(extra, 1)) + " 68% 58%)";
}

const timeOnly = (ms) => new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const dateTime = (ms) => new Date(ms).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

function query() {
  if (!ui.serverId || ui.gpu == null) return;
  send({ type: "query", serverId: ui.serverId, gpu: ui.gpu, hours: ui.hours });
}

function server() { return ui.servers.find((entry) => entry.id === ui.serverId); }

// ---------- Controls ----------

function controls() {
  const nodes = [];
  if (ui.servers.length > 1) {
    const picker = h("select", "server-picker");
    picker.setAttribute("aria-label", t("Server"));
    for (const entry of ui.servers) {
      const option = h("option", "", entry.name);
      option.value = entry.id;
      option.selected = entry.id === ui.serverId;
      picker.append(option);
    }
    picker.addEventListener("change", () => {
      ui.serverId = picker.value;
      try { localStorage.setItem("historyServer", ui.serverId); } catch { /* ignore */ }
      ui.gpu = server()?.gpus[0] ?? null;
      ui.data = null;
      render();
      query();
    });
    nodes.push(picker);
  }
  if (!ui.recording) {
    const status = h("div", "status");
    status.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6.4 5.5v5M9.6 5.5v5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
    status.append(t("Recording is off. Turn on Record GPU history in Settings › Appearance."));
    nodes.push(status);
  }
  const gpus = server()?.gpus || [];
  const gpuPicker = h("select", "gpu-picker");
  gpuPicker.setAttribute("aria-label", "GPU");
  for (const index of gpus) {
    const option = h("option", "", "GPU " + index);
    option.value = index;
    option.selected = index === ui.gpu;
    gpuPicker.append(option);
  }
  gpuPicker.addEventListener("change", () => { ui.gpu = Number(gpuPicker.value); ui.data = null; render(); query(); });
  const segmented = h("div", "segmented");
  segmented.setAttribute("role", "group");
  segmented.setAttribute("aria-label", t("Time range"));
  for (const hours of [1, 5, 12, 24]) {
    const button = h("button", "", hours + "h");
    button.setAttribute("aria-pressed", String(hours === ui.hours));
    button.addEventListener("click", () => { ui.hours = hours; ui.selected = null; query(); render(); });
    segmented.append(button);
  }
  nodes.push(h("div", "controls", gpuPicker, segmented));
  return nodes;
}

// ---------- Chart ----------

function chart(data) {
  const container = h("div", "chart");
  container.setAttribute("role", "img");
  container.setAttribute("aria-label", t("GPU utilization history by user"));
  const width = Math.max(200, document.getElementById("root").clientWidth - 32);
  const height = 230, left = 46, bottom = 22, top = 6, right = 6;
  const plotW = width - left - right, plotH = height - top - bottom;
  const x = (ms) => left + ((ms - data.start) / (data.end - data.start)) * plotW;
  const y = (value) => top + plotH - (value / data.maximumY) * plotH;
  const svg = s("svg", { viewBox: "0 0 " + width + " " + height, preserveAspectRatio: "none" });

  // Y axis: 25 % steps up to the maximum (≥ 100), like the macOS axis marks.
  for (let value = 0; value <= data.maximumY + 0.001; value += data.maximumY > 200 ? 50 : 25) {
    svg.append(s("line", { class: "grid", x1: left, x2: width - right, y1: y(value), y2: y(value) }));
    const label = s("text", { class: "axis", x: left - 6, y: y(value) + 4, "text-anchor": "end" });
    label.textContent = Math.round(value) + "%";
    svg.append(label);
  }
  data.ticks.forEach((tick, index) => {
    const anchor = index === 0 ? "start" : index === data.ticks.length - 1 ? "end" : "middle";
    const label = s("text", { class: "axis", x: x(tick), y: height - 4, "text-anchor": anchor });
    label.textContent = timeOnly(tick);
    svg.append(label);
  });

  const clip = s("clipPath", { id: "plot" });
  clip.append(s("rect", { x: left, y: top, width: plotW, height: plotH }));
  svg.append(clip);
  const plot = s("g", { "clip-path": "url(#plot)" });

  // Stacked per-user areas and their top lines, split at gaps (segments).
  const groups = new Map();
  for (const area of data.areas) {
    const key = area.user + ":" + area.segment;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(area);
  }
  for (const [, areas] of groups) {
    areas.sort((a, b) => a.time - b.time);
    const color = colorFor(areas[0].user);
    const upper = areas.map((a) => x(a.time) + "," + y(a.upper));
    const lower = areas.slice().reverse().map((a) => x(a.time) + "," + y(a.lower));
    plot.append(s("polygon", { points: upper.concat(lower).join(" "), fill: color, "fill-opacity": "0.28" }));
    plot.append(s("polyline", { class: "user-line", points: upper.join(" "), stroke: color }));
  }
  const totals = new Map();
  for (const point of data.total) {
    if (!totals.has(point.segment)) totals.set(point.segment, []);
    totals.get(point.segment).push(point);
  }
  for (const [, points] of totals) {
    points.sort((a, b) => a.time - b.time);
    plot.append(s("polyline", { class: "total", points: points.map((p) => x(p.time) + "," + y(p.value)).join(" ") }));
  }
  svg.append(plot);

  if (ui.selected != null && data.readings[ui.selected]) {
    const cx = x(data.readings[ui.selected].time);
    svg.append(s("line", { class: "cursor", x1: cx, x2: cx, y1: top, y2: top + plotH }));
  }
  container.append(svg);

  // Hover picks the nearest reading; leaving shows the latest again (macOS cursor overlay).
  const pick = (event) => {
    const rect = svg.getBoundingClientRect();
    const px = ((event.clientX - rect.left) / rect.width) * width;
    if (px < left || px > width - right || !data.readings.length) { setSelected(null); return; }
    const time = data.start + ((px - left) / plotW) * (data.end - data.start);
    let lowerIndex = 0, upperIndex = data.readings.length;
    while (lowerIndex < upperIndex) {
      const middle = (lowerIndex + upperIndex) >> 1;
      if (data.readings[middle].time < time) lowerIndex = middle + 1; else upperIndex = middle;
    }
    let index = lowerIndex;
    if (index === data.readings.length) index -= 1;
    else if (index > 0 && time - data.readings[index - 1].time <= data.readings[index].time - time) index -= 1;
    setSelected(index);
  };
  container.addEventListener("pointermove", pick);
  container.addEventListener("pointerdown", pick);
  container.addEventListener("pointerleave", () => setSelected(null));
  return container;
}

function setSelected(index) {
  if (index === ui.selected) return;
  ui.selected = index;
  render();
}

function legend(data) {
  const reading = ui.selected != null ? data.readings[ui.selected] : data.readings[data.readings.length - 1];
  if (!reading) return [];
  const avg = h("span", "", t("%@m avg", data.rollupMinutes));
  avg.title = t("Interval averages. Short per-user sampling gaps are connected visually, but read as unavailable. Offline and longer gaps stay open.");
  const row = (user, value) => {
    const swatch = h("span", "swatch");
    swatch.style.background = user === TOTAL ? "var(--total)" : colorFor(user);
    const name = h("span", "metric-name", user === TOTAL ? t("GPU total") : user);
    name.title = user;
    const formatted = value == null ? t("measurement::Unavailable") : value.toFixed(1) + "%";
    return h("div", "metric", swatch, name, h("span", "metric-value" + (value == null ? " unavailable" : ""), formatted));
  };
  const box = h("div", "legend", row(TOTAL, reading.total));
  for (const user of data.users) box.append(row(user, reading.users ? (reading.users[user] ?? 0) : null));
  return [h("div", "header", h("span", "", dateTime(reading.time)), avg), box];
}

function render() {
  const root = document.getElementById("root");
  document.documentElement.lang = ui.language;
  if (!ui.servers.length) {
    root.replaceChildren(h("div", "secondary", t("Configure a server to begin recording GPU history.")));
    return;
  }
  const nodes = controls();
  const data = ui.data;
  if (data && (data.total.length || data.areas.length)) {
    nodes.push(...legend(data), chart(data));
    if (!data.users.length || !data.lastReadingHasUsers) {
      nodes.push(h("div", "footnote", t("Per-user SM sampling unavailable or GPU idle. The gray line is measured GPU utilization.")));
    }
  } else if (data) {
    nodes.push(h("div", "empty", t("Waiting for the first history sample.")));
  }
  const focusedTag = document.activeElement && document.activeElement.className;
  root.replaceChildren(...nodes);
  if (focusedTag) root.querySelector("." + CSS.escape(String(focusedTag).split(" ")[0]))?.focus({ preventScroll: true });
}

window.addEventListener("resize", () => { if (ui.data) render(); });
document.addEventListener("keydown", (event) => { if (event.key === "Escape") send({ type: "close" }); });

if (host) {
  host.addEventListener("message", (event) => {
    const message = event.data;
    if (message.type === "servers") {
      ui.servers = message.servers;
      ui.language = message.language;
      ui.recording = message.recording;
      document.documentElement.dataset.theme = message.theme;
      if (!server()) ui.serverId = ui.servers[0]?.id ?? null;
      const gpus = server()?.gpus || [];
      if (!gpus.includes(ui.gpu)) ui.gpu = gpus[0] ?? null;
      render();
      query();
    } else if (message.type === "history" && message.serverId === ui.serverId && message.gpu === ui.gpu && message.hours === ui.hours) {
      ui.data = message.data;
      if (ui.selected != null && !ui.data.readings[ui.selected]) ui.selected = null;
      render();
    }
  });
}
send({ type: "ready", width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio });
