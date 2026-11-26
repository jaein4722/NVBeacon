"use strict";

// Settings page. Mirrors the macOS Settings window (Sources/NVBeacon/SettingsView.swift):
// seven tabs of grouped forms, auto-applied 350 ms after the last change. A server's
// connection fields and commands apply when the field is left or Enter is pressed,
// so a half-typed login or command never reaches a server. Every edit is also sent
// as a draft, which Swift applies if the window closes before it was applied.
// Swift owns validation, saving and every side effect; this page edits a draft.
const host = window.chrome && window.chrome.webview;
const send = (message) => host && host.postMessage(JSON.stringify(message));

const ui = {
  data: null,          // last "settings" message
  draft: null,         // editable copy of data.settings
  runtime: null,
  tab: "general",
  selectedServerId: "",
  selectedHostAlias: "",
  launchError: null,
  applyTimer: 0,
  passwordDraft: "",   // typed SSH password, sent once and never stored in the draft
};


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
function svgIcon(name, className) {
  const holder = document.createElement("span");
  holder.innerHTML = ICONS[name];
  const svg = holder.firstElementChild;
  svg.setAttribute("aria-hidden", "true");
  if (className) svg.setAttribute("class", className);
  return svg;
}
function keyed(node, key) { node.dataset.key = key; return node; }

// System, then every language file the app found (sent as settings.languages).
function languageChoices() {
  return [{ value: "system", label: t("System") }]
    .concat((ui.data.languages || []).map((language) => ({ value: language.value, label: language.name })));
}

function section(header, rows, footer) {
  const wrapper = h("section", "");
  if (header) wrapper.append(h("h3", "section-header", header));
  wrapper.append(h("div", "group", ...rows));
  if (footer) wrapper.append(h("p", "footer", footer));
  return wrapper;
}
function row(label, control, sublabel) {
  const labelNode = h("div", "row-label", h("span", "", label), sublabel ? h("small", "", sublabel) : null);
  return h("div", "row", labelNode, h("div", "row-control", ...[].concat(control)));
}
function note(text) { return h("div", "note", text); }

function toggle(key, checked, onChange, disabled) {
  const input = h("input", "");
  input.type = "checkbox";
  input.checked = !!checked;
  input.disabled = !!disabled;
  input.setAttribute("role", "switch");
  input.addEventListener("change", () => onChange(input.checked));
  keyed(input, key);
  return h("label", "switch", input, h("span", ""));
}
function toggleRow(label, key, checked, onChange, options = {}) {
  const control = toggle(key, checked, onChange, options.disabled);
  control.querySelector("input").setAttribute("aria-label", label);
  return row(label, control, options.sublabel);
}
function textField(key, value, placeholder, widthClass, onInput, options = {}) {
  const input = h("input", "text " + (widthClass || ""));
  input.type = options.type || "text";
  input.value = value || "";
  input.placeholder = placeholder || "";
  input.spellcheck = false;
  input.disabled = !!options.disabled;
  input.addEventListener("input", () => onInput(input.value));
  if (options.appliesWhenLeft) appliesWhenLeft(input);
  return keyed(input, key);
}
/// Enter or leaving the field applies its deferred edit.
function appliesWhenLeft(node) {
  node.addEventListener("change", flushApply);
  node.addEventListener("blur", flushApply);
}
function select(key, value, choices, onChange, options = {}) {
  const node = h("select", "text " + (options.widthClass || ""));
  for (const choice of choices) {
    const option = h("option", "", choice.label);
    option.value = choice.value;
    option.disabled = !!choice.disabled;
    if (choice.value === value) option.selected = true;
    node.append(option);
  }
  node.disabled = !!options.disabled;
  node.addEventListener("change", () => onChange(node.value));
  return keyed(node, key);
}
function button(label, onClick, options = {}) {
  const node = h("button", "button " + (options.className || ""), options.icon ? svgIcon(options.icon) : label);
  if (options.icon) { node.title = label; node.setAttribute("aria-label", label); }
  node.disabled = !!options.disabled;
  node.addEventListener("click", onClick);
  return keyed(node, options.key || "button:" + label);
}
function stepper(key, value, min, max, suffix, onChange, step = 1) {
  const input = h("input", "text");
  input.type = "number";
  input.min = min; input.max = max; input.step = step;
  input.value = value;
  const commit = (next) => {
    const clamped = Math.min(max, Math.max(min, Math.round(Number(next) || min)));
    input.value = clamped;
    onChange(clamped);
  };
  input.addEventListener("change", () => commit(input.value));
  keyed(input, key);
  const minus = button("−", () => commit(Number(input.value) - step), { key: key + ":minus" });
  const plus = button("+", () => commit(Number(input.value) + step), { key: key + ":plus" });
  minus.setAttribute("aria-label", t("Decrease"));
  plus.setAttribute("aria-label", t("Increase"));
  return h("span", "stepper", minus, input, plus, h("span", "suffix", suffix));
}

// ---------- Draft editing ----------

function changed(options = {}) {
  clearTimeout(ui.applyTimer);
  ui.applyPending = true;
  send({ type: "draft", settings: ui.draft });
  if (!options.deferred) {
    ui.applyTimer = setTimeout(() => {
      ui.applyPending = false;
      send({ type: "apply", settings: ui.draft });
    }, 350);
  }
  if (options.rerender) render();
}
/// Sends a pending apply now, so an action that reads saved settings sees the latest edits.
function flushApply() {
  if (!ui.applyPending) return;
  clearTimeout(ui.applyTimer);
  ui.applyPending = false;
  send({ type: "apply", settings: ui.draft });
}
function selectedServer() { return ui.draft.servers.find((s) => s.id === ui.selectedServerId) || null; }
function updateServer(field, value, rerender, deferred) {
  const server = selectedServer();
  if (!server) return;
  server[field] = value;
  changed({ rerender, deferred });
}
function displayName(server) {
  return (server.name || "").trim() || (server.sshTarget || "").trim() || t("New Server");
}
// Password rows (macOS "Password Session" / "SSH Password"). The password goes straight
// to Swift, which stores it in Windows Credential Manager; it is never part of the draft.
function passwordRows(server) {
  const saved = (ui.data.savedPasswords || []).includes(server.id);
  const status = h("span", saved ? "status-enabled" : "status-warning", saved ? t("Saved") : t("Not saved"));
  const field = textField("server-password", ui.passwordDraft, saved ? t("Enter a new password") : t("Required"), "w-240",
    (value) => { ui.passwordDraft = value; saveButton.disabled = !value; }, { type: "password" });
  field.autocomplete = "off";
  const savePassword = () => {
    if (!ui.passwordDraft) return;
    send({ type: "savePassword", serverId: server.id, password: ui.passwordDraft });
    ui.passwordDraft = "";
    field.value = "";
    saveButton.disabled = true;
  };
  field.addEventListener("keydown", (event) => { if (event.key === "Enter") savePassword(); });
  const saveButton = button(t("Save Password"), savePassword, { disabled: !ui.passwordDraft, key: "password-save" });
  const forget = button(t("Forget Saved Password"), () => send({ type: "forgetPassword", serverId: server.id }),
    { className: "destructive", disabled: !saved, key: "password-forget" });
  return [
    row(t("Password session"), [status, forget]),
    row(t("SSH password"), [field, saveButton]),
  ];
}
function newServer(fields) {
  return Object.assign({
    id: crypto.randomUUID().toUpperCase(), name: "", sshTarget: "", sshPort: "", sshIdentityFilePath: "",
    sshAuthenticationMode: "keyBased", sshConnectionReuseMode: "reuseWhenPossible", remoteCommand: ui.data.defaults.gpuCommand,
    hostCommand: ui.data.defaults.hostCommand, isEnabled: true,
  }, fields);
}

// ---------- Panes ----------
// Seven tabs shared with macOS (docs/SETTINGS.md): one kind of task per tab, per-server
// settings only in Servers, help as a caption or a section footer, dependent controls
// disabled rather than hidden, destructive actions last with a confirmation.

const TABS = [
  { id: "general", icon: "gear", label: () => t("General") },
  { id: "servers", icon: "serverRack", label: () => t("Servers") },
  { id: "monitoring", icon: "chart", label: () => t("Monitoring") },
  { id: "notifications", icon: "bell", label: () => t("Notifications") },
  { id: "display", icon: "display", label: () => t("Display") },
  { id: "advanced", icon: "sliders", label: () => t("Advanced") },
  { id: "about", icon: "infoLarge", label: () => t("About") },
];

const BUSY_MODES = () => [
  { value: "activeProcess", label: t("Active Process") },
  { value: "memoryThreshold", label: t("Memory Threshold") },
  { value: "activeProcessOrMemoryThreshold", label: t("Process or Memory") },
  { value: "utilizationThreshold", label: t("Utilization Threshold") },
];

function generalPane() {
  const d = ui.draft;
  const status = ui.data.launchAtLogin;
  const statusText = status === "enabled" ? t("On") : status === "otherLocation"
    ? t("Registered for another copy of NVBeacon") : t("Off");
  const startupRows = [
    toggleRow(t("Launch NVBeacon at login"), "launch-at-login", status === "enabled",
      (value) => send({ type: "setLaunchAtLogin", enabled: value })),
    row(t("Startup status"), [
      h("span", status === "enabled" ? "status-enabled" : status === "otherLocation" ? "status-warning" : "", statusText),
      button(t("Refresh"), () => send({ type: "reloadHosts" }), { key: "startup-refresh" })],
      ui.launchError || null),
  ];
  return [
    section(t("Startup"), startupRows,
      t("Uses the per-user Run key, the same list as Task Manager's Startup apps.")),
    section(t("App"), [
      row(t("Language"), select("language", d.languagePreference, languageChoices(),
        (value) => { d.languagePreference = value; changed(); })),
    ]),
  ];
}

function serversPane() {
  const d = ui.draft;
  const servers = d.servers;
  const index = servers.findIndex((s) => s.id === ui.selectedServerId);
  const nodes = [];

  if (ui.data.sessionOverride) {
    nodes.push(h("div", "banner", svgIcon("info"), t("Servers passed on the command line (or --demo) are being monitored for this session. The saved servers below are used on the next normal launch.")));
  }

  const picker = select("server-picker", ui.selectedServerId,
    servers.map((s) => ({ value: s.id, label: displayName(s) })),
    (value) => { ui.selectedServerId = value; ui.passwordDraft = ""; ui.testResult = null; render(); },
    { widthClass: "w-300", disabled: !servers.length });
  const moveUp = button(t("Move Server Up"), () => {
    [servers[index - 1], servers[index]] = [servers[index], servers[index - 1]];
    changed({ rerender: true });
  }, { icon: "chevronUp", className: "icon", disabled: index <= 0, key: "server-up" });
  const moveDown = button(t("Move Server Down"), () => {
    [servers[index + 1], servers[index]] = [servers[index], servers[index + 1]];
    changed({ rerender: true });
  }, { icon: "chevronDown", className: "icon", disabled: index < 0 || index === servers.length - 1, key: "server-down" });
  const remove = button(t("Remove Server…"), () => confirmRemoveServer(index),
    { icon: "trash", className: "icon destructive", disabled: index < 0, key: "server-remove" });
  nodes.push(section(t("Servers"), [row(t("Current"), [picker, moveUp, moveDown, remove])],
    t("The popover lists servers in this order.")));

  const hosts = ui.data.sshConfigHosts || [];
  const addRows = [row(t("New server"), [
    button(t("Add Server"), () => {
      const server = newServer({ name: t("New Server") });
      servers.push(server);
      ui.selectedServerId = server.id;
      changed({ rerender: true });
    })])];
  const hostPicker = select("saved-host", ui.selectedHostAlias,
    [{ value: "", label: hosts.length ? t("Select a saved host") : t("No saved hosts") }]
      .concat(hosts.map((entry) => ({ value: entry.alias, label: entry.alias }))),
    (value) => { ui.selectedHostAlias = value; render(); }, { widthClass: "w-240", disabled: !hosts.length });
  const addHost = button(t("Add"), () => {
    // The alias is the target, so ssh applies the rest of the Host block itself (as on macOS).
    const server = newServer({ name: ui.selectedHostAlias, sshTarget: ui.selectedHostAlias });
    servers.push(server);
    ui.selectedServerId = server.id;
    ui.selectedHostAlias = "";
    changed({ rerender: true });
  }, { disabled: !ui.selectedHostAlias, key: "saved-host-add" });
  const chosen = hosts.find((entry) => entry.alias === ui.selectedHostAlias);
  let hostCaption = t("From %@", ui.data.sshConfigPath);
  if (chosen) {
    const parts = [chosen.user && chosen.hostName ? chosen.user + "@" + chosen.hostName : chosen.hostName || chosen.alias];
    if (chosen.port) parts.push(t("port %@", chosen.port));
    if (chosen.identityFile) parts.push(t("key %@", chosen.identityFile));
    hostCaption = parts.join(" · ");
  }
  addRows.push(row(t("Saved host"), [hostPicker, addHost,
    button(t("Reload Saved Hosts"), () => send({ type: "reloadHosts" }), { icon: "refresh", className: "icon", key: "hosts-reload" })],
    hostCaption));
  nodes.push(section(t("Add Server"), addRows));

  const server = selectedServer();
  if (!server) {
    nodes.push(section(t("Selected Server"), [],
      t("Add a server to start monitoring remote GPUs.")));
    return nodes;
  }
  const password = server.sshAuthenticationMode === "passwordBased";
  const connectionRows = [
    toggleRow(t("Enabled"), "server-enabled", server.isEnabled, (value) => updateServer("isEnabled", value)),
    row(t("Name"), textField("server-name", server.name, server.sshTarget || "GPU Server", "w-240",
      (value) => { updateServer("name", value); refreshServerPickerLabel(); })),
    row(t("SSH target"), textField("server-target", server.sshTarget, "gpu-prod or user@host", "w-320",
      (value) => { updateServer("sshTarget", value, false, true); refreshServerPickerLabel(); }, { appliesWhenLeft: true }),
      t("A host alias from the ssh config, or user@host")),
    row(t("SSH port"), textField("server-port", server.sshPort, "22", "w-120",
      (value) => updateServer("sshPort", value, false, true), { appliesWhenLeft: true }),
      t("Optional · Default 22 or the ssh config")),
    row(t("Authentication"), select("server-auth", server.sshAuthenticationMode, [
      { value: "keyBased", label: t("Key-based") },
      { value: "passwordBased", label: t("Password-based") },
    ], (value) => updateServer("sshAuthenticationMode", value, true))),
    row(t("Key file"), [
      textField("server-identity", server.sshIdentityFilePath, t("Optional"), "w-240",
        (value) => updateServer("sshIdentityFilePath", value, false, true), { appliesWhenLeft: true }),
      button(t("Browse…"), () => send({ type: "browseIdentity", serverId: server.id }))]),
  ];
  if (password) connectionRows.push(...passwordRows(server));
  nodes.push(section(t("Connection"), connectionRows, password
    ? t("The password is kept in Windows Credential Manager for your Windows account and answers only this server's SSH password prompt, once per connection. Programs running as your Windows user can read it, so SSH keys are safer when the server allows them. If the server rejects the password, collection stops until you save it again.")
    : null));

  const reuseMode = server.sshConnectionReuseMode || "reuseWhenPossible";
  const reuseHelp = h("span", "", svgIcon("question", "help"));
  reuseHelp.title = reuseMode === "reuseWhenPossible"
    ? t("NVBeacon keeps the SSH connection open and reuses it instead of logging in again for every refresh. No extra software is required on the server. If your server behaves strangely, switch to a new connection every refresh.")
    : t("Every refresh opens a brand-new SSH connection. This is slower, but suits unusual SSH servers.");
  const testResult = ui.testResult && ui.testResult.serverId === server.id ? ui.testResult : null;
  nodes.push(section(t("SSH Connection"), [
    row(t("SSH connection"), [
      select("server-reuse", reuseMode, [
        { value: "reuseWhenPossible", label: t("Reuse connection (Recommended)") },
        { value: "newConnectionEachRefresh", label: t("New connection every refresh") },
      ], (value) => updateServer("sshConnectionReuseMode", value, true)),
      reuseHelp]),
    row(t("Connection test"), [
      testResult ? h("span", testResult.ok ? "status-enabled" : testResult.pending ? "" : "status-warning", testResult.text) : null,
      button(t("Test Connection"), () => {
        flushApply();
        ui.testResult = { serverId: server.id, pending: true, text: t("Testing…") };
        render();
        send({ type: "testConnection", serverId: server.id });
      }, { disabled: !!(testResult && testResult.pending) || !(server.sshTarget || "").trim(), key: "server-test" })],
      t("Runs the GPU query once over a new connection. Nothing is saved.")),
  ]));

  nodes.push(commandSection(t("GPU Query Command"), "gpu-command", "remoteCommand", ui.data.defaults.gpuCommand,
    t("Leave empty to restore the default command.")));
  nodes.push(commandSection(t("Host Information Query Command"), "host-command", "hostCommand", ui.data.defaults.hostCommand,
    t("Collects CPU, RAM/Swap and network in the same refresh. Keep the section markers and collection switches when customizing. Leave empty to restore the default command.")));
  return nodes;
}

function monitoringPane() {
  const d = ui.draft;
  const collectionRows = [
    row(t("Refresh interval"),
      stepper("poll-interval", d.pollIntervalSeconds, 1, 300, "s", (value) => { d.pollIntervalSeconds = value; changed(); }),
      t("1–300 s · Default 10 s")),
    row(t("Busy GPU detection"), select("busy-mode", d.busyDetectionMode, BUSY_MODES(), (value) => { d.busyDetectionMode = value; changed({ rerender: true }); })),
  ];
  if (d.busyDetectionMode === "memoryThreshold" || d.busyDetectionMode === "activeProcessOrMemoryThreshold") {
    collectionRows.push(row(t("Memory threshold"),
      stepper("busy-memory", d.busyMemoryThresholdMB, 0, 10240, "MB", (value) => { d.busyMemoryThresholdMB = value; changed(); }),
      t("0–10,240 MB · Default 50 MB")));
  }
  if (d.busyDetectionMode === "utilizationThreshold") {
    collectionRows.push(row(t("Utilization threshold"),
      stepper("busy-util", d.busyUtilizationThresholdPercent, 0, 100, "%", (value) => { d.busyUtilizationThresholdPercent = value; changed(); }),
      t("0–100% · Default 10%")));
  }
  collectionRows.push(toggleRow(t("Highlight my processes"), "highlight-mine", d.highlightsMyProcesses,
    (value) => { d.highlightsMyProcesses = value; changed({ rerender: true }); },
    { sublabel: d.highlightsMyProcesses
      ? t("Highlights the SSH user's processes and their GPUs.")
      : t("Also skips the extra owner check during collection.") }));

  const hostRows = [
    toggleRow(t("Collect host information"), "host-info", d.collectsHostInfo, (value) => { d.collectsHostInfo = value; changed({ rerender: true }); }),
    toggleRow("CPU", "host-cpu", d.collectsHostCPU, (value) => { d.collectsHostCPU = value; changed(); }, { disabled: !d.collectsHostInfo }),
    toggleRow(t("Memory (RAM / Swap)"), "host-memory", d.collectsHostMemory, (value) => { d.collectsHostMemory = value; changed(); }, { disabled: !d.collectsHostInfo }),
    toggleRow(t("Network"), "host-network", d.showsNetworkUsage, (value) => { d.showsNetworkUsage = value; changed(); }, { disabled: !d.collectsHostInfo }),
  ];
  for (const node of hostRows.slice(1)) node.classList.add("indent");

  return [
    section(t("Collection"), collectionRows),
    section(t("Host Information"), hostRows,
      t("Applies to all servers. Items that are off are not collected. Collapsing a server's host information only hides it; collection continues.")),
    section(t("GPU History"), [
      toggleRow(t("Record GPU history"), "gpu-history", d.recordsGPUHistory, (value) => {
        if (value) { confirmHistory(); render(); } else { d.recordsGPUHistory = false; changed({ rerender: true }); }
      }, { sublabel: t("Opens from the chart button in the popover.") }),
      row(t("Saved history"), button(t("Delete History…"), confirmDeleteHistory,
        { className: "destructive", key: "history-delete" })),
    ], t("Keeps 24 hours of per-user GPU utilization on this PC. Adds one nvidia-smi pmon sample per server at most once a minute.")),
  ];
}

function refreshServerPickerLabel() {
  const picker = document.querySelector('[data-key="server-picker"]');
  const server = selectedServer();
  if (picker && server) {
    const option = [...picker.options].find((o) => o.value === server.id);
    if (option) option.textContent = displayName(server);
  }
}

const HISTORY_TITLES = {
  permissionEnabled: "Permission enabled",
  permissionDenied: "Permission denied",
  watchAdded: "Process watch enabled",
  watchRemoved: "Process watch removed",
  idleWatchAdded: "GPU idle watch enabled",
  idleWatchRemoved: "GPU idle watch removed",
  testNotificationScheduled: "Test notification sent",
  exitNotificationScheduled: "Process exit notification sent",
  idleNotificationScheduled: "GPU idle notification sent",
};

function watchRow(badge, badgeClass, title, primary, secondary, id) {
  const remove = button(t("Disable"), () => send({ type: "removeWatch", id }), { key: "remove:" + id });
  return h("div", "row watch-row",
    h("div", "row-label",
      h("span", "", h("span", "watch-badge " + badgeClass, badge), " ", h("strong", "", title)),
      h("small", "", primary), secondary ? h("small", "", secondary) : null),
    h("div", "row-control", remove));
}

function notificationsPane() {
  const d = ui.draft;
  const n = ui.data.notifications || { processWatches: [], idleWatches: [], history: [] };
  const watchRows = [];
  for (const watch of n.idleWatches) {
    watchRows.push(watchRow(t("GPU Idle"), "idle", watch.title, watch.subtitle,
      t("Idle %@ s · ≤%@ MB", d.idleNotificationSeconds, d.idleMemoryThresholdMB), watch.id));
  }
  for (const watch of n.processWatches) {
    watchRows.push(watchRow(t("Process Exit"), "exit", watch.title,
      t("User %@ · PID %@ · GPU %@", watch.user, watch.pid, watch.gpu),
      watch.connection, watch.id));
  }
  const historyRows = n.history.map((entry) => h("div", "info-row history-row",
    h("span", "", h("strong", "", t(HISTORY_TITLES[entry.kind] || entry.kind)), h("br"), entry.subtitle),
    h("span", "", new Date(entry.time).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }))));
  return [
    section(t("Permission"), [
      row(t("Status"), [h("span", "", t("Shown through the tray icon")),
        button(t("Send Test Notification"), () => send({ type: "testNotification" }))]),
    ], t("Windows shows these as notifications from NVBeacon. If they do not appear, check Settings › System › Notifications and Do not disturb.")),
    section(t("GPU Idle Alert"), [
      row(t("Idle duration"),
        stepper("idle-seconds", d.idleNotificationSeconds, 1, 3600, "s", (value) => { d.idleNotificationSeconds = value; changed(); }),
        t("1–3,600 s · Default 300 s")),
      row(t("Memory threshold"),
        stepper("idle-memory", d.idleMemoryThresholdMB, 0, 10240, "MB", (value) => { d.idleMemoryThresholdMB = value; changed(); }),
        t("0–10,240 MB · Default 50 MB")),
    ], t("Starred GPUs send an alert when they stay idle this long.")),
    section(t("Active Watches"), watchRows,
      watchRows.length ? null : t("There are no watches.")),
    section(t("Recent 24 Hours"), historyRows,
      historyRows.length ? null : t("Nothing in the last 24 hours.")),
  ];
}

function displayPane() {
  const d = ui.draft;
  const trayCaptions = {
    averageAndBusy: t("Average utilization, with a bar for the share of busy GPUs."),
    averageOnly: t("Average utilization of all GPUs."),
    busyOnly: t("Number of busy GPUs."),
    iconOnly: t("The app icon. Point at it to see the summary."),
  };
  return [
    section(t("Tray Icon"), [
      // macOS "Menu bar text": the tray draws the number into its icon instead.
      row(t("Tray icon"), select("tray-style", d.trayIconStyle, [
        { value: "averageAndBusy", label: t("Average + Busy") },
        { value: "averageOnly", label: t("Average Util") },
        { value: "busyOnly", label: t("Busy Count") },
        { value: "iconOnly", label: t("Icon Only") },
      ], (value) => { d.trayIconStyle = value; changed({ rerender: true }); }), trayCaptions[d.trayIconStyle]),
      toggleRow(t("Color by load"), "tray-color", d.trayIconUsesColor,
        (value) => { d.trayIconUsesColor = value; changed(); },
        { disabled: d.trayIconStyle === "iconOnly", sublabel: t("Green, amber or red badge. Off: the number in the taskbar's text color.") }),
    ], t("Point at the tray icon for a summary of every server.")),
    section(t("Window"), [
      row(t("Display mode"), select("display-mode", d.displayMode, [
        { value: "popover", label: t("Popover") },
        { value: "window", label: t("Window") },
      ], (value) => { d.displayMode = value; changed({ rerender: true }); }),
        t("Window keeps NVBeacon open like a normal app window.")),
      // Only for the window, as on macOS.
      ...(d.displayMode === "window" ? [toggleRow(t("Keep window on top"), "window-on-top", d.windowAlwaysOnTop,
        (value) => { d.windowAlwaysOnTop = value; changed(); })] : []),
      row(t("Theme"), select("theme", d.appearanceMode, [
        { value: "system", label: t("System") },
        { value: "light", label: t("Light") },
        { value: "dark", label: t("Dark") },
      ], (value) => { d.appearanceMode = value; changed(); })),
    ]),
    section(t("Popover"), [
      row(t("Width"),
        stepper("popover-width", d.popoverWidth, 480, 800, "pt", (value) => { d.popoverWidth = value; changed(); }, 20),
        t("480–800 pt · Default 500 pt")),
      row(t("Height"),
        select("popover-height-mode", d.popoverHeightMode, [
          { value: "automatic", label: t("Fit Content") },
          { value: "fixed", label: t("Fixed") },
        ], (value) => { d.popoverHeightMode = value; changed({ rerender: true }); }),
        d.popoverHeightMode === "fixed" ? null : t("Up to the screen height")),
      ...(d.popoverHeightMode === "fixed" ? [row(t("Fixed height"),
        stepper("popover-height", d.popoverHeight, 320, 1100, "pt", (value) => { d.popoverHeight = value; changed(); }, 20),
        t("320–1100 pt · Default 600 pt · Content scrolls inside"))] : []),
      toggleRow(t("Close on outside click"), "close-outside", d.closesPopoverOnOutsideClick,
        (value) => { d.closesPopoverOnOutsideClick = value; changed({ rerender: true }); },
        { sublabel: d.closesPopoverOnOutsideClick
          ? t("Closes when you click outside it or switch to another app.")
          : t("Stays open until you click the tray icon again.") }),
    ]),
  ];
}

function commandSection(title, key, field, defaultCommand, footer) {
  const server = selectedServer();
  const area = h("textarea", "text");
  area.spellcheck = false;
  area.value = server ? server[field] : "";
  area.disabled = !server;
  area.addEventListener("input", () => updateServer(field, area.value, false, true));
  appliesWhenLeft(area);
  keyed(area, key);
  const restore = button(t("Restore Default"), () => { updateServer(field, defaultCommand, true); }, {
    disabled: !server || (server && server[field] === defaultCommand), key: key + ":restore" });
  return section(title, [h("div", "row stack", area, h("div", "row-control", restore))], footer);
}

function advancedPane() {
  const d = ui.draft;
  return [
    section(t("Server Backup"), [row(t("Servers"), [
      button(t("Export Servers…"), () => send({ type: "exportServers" }), { disabled: !d.servers.some((s) => (s.sshTarget || "").trim()) }),
      button(t("Import Servers…"), () => send({ type: "importServers" }))])],
      t("Exports host names, key file paths and remote commands. Passwords, private key contents and watches are excluded. Imports add disabled servers without replacing existing settings. The file format is shared with NVBeacon for macOS.")),
    section(t("Support"), [row(t("Diagnostic information"),
      button(t("Copy Diagnostic Information…"), () => send({ type: "diagnostics" })))],
      t("Preview a report of the current app and collection state. No additional SSH commands are run.")),
    section(t("Saved Settings"), [row(t("Settings"), [
      button(t("Open settings.json"), () => send({ type: "openSettingsFile" })),
      button(t("Reload Current Settings"), () => {
        // Reading the file replaces edits that were not applied yet.
        clearTimeout(ui.applyTimer);
        ui.applyPending = false;
        send({ type: "reload" });
      }),
      button(t("Clear Saved Settings…"), confirmClear, { className: "destructive" })])],
      t("Clearing removes every server, saved password, watch and notification history.")),
  ];
}

function infoCard(title, rows) {
  return section(title, rows.map(([label, value]) => h("div", "info-row", h("span", "", label), h("span", "", value))));
}

function aboutPane() {
  const d = ui.draft;
  const r = ui.runtime;
  const icon = h("div", "about-icon", svgIcon("gpu"));
  const link = button("github.com/jaein4722/NVBeacon", () => send({ type: "openURL", url: "https://github.com/jaein4722/NVBeacon" }), { className: "link" });
  link.classList.remove("button");
  link.title = t("Open the GitHub repository");
  const busy = Object.fromEntries(BUSY_MODES().map((mode) => [mode.value, mode.label]));
  const theme = { system: t("System"), light: t("Light"), dark: t("Dark") };
  const runtimeRows = r && r.loaded ? [
    [t("Visible GPUs"), r.visibleGPUs], [t("Busy GPUs"), r.busyGPUs],
    [t("Processes"), r.processes], [t("Average Utilization"), r.averageUtilization + "%"],
    [t("Server Errors"), r.serverErrors],
  ] : [[t("GPU data has not been loaded yet."), ""]];
  return [
    h("div", "about-head", icon, h("div", "about-name", "NVBeacon"),
      h("div", "", t("Remote NVIDIA GPU monitoring from your Windows notification area.")), link),
    infoCard(t("Build Information"), [
      [t("Version"), ui.data.about.version],
      [t("Repository"), "github.com/jaein4722/NVBeacon"],
      [t("Developer"), "github.com/jaein4722"],
      [t("Settings File"), ui.data.about.settingsFile],
    ]),
    section(t("Open Source Licenses"), [
      row(t("Libraries installed with NVBeacon"),
        button(t("Open Licenses"), () => send({ type: "openLicenses" }))),
    ]),
    infoCard(t("Current Configuration"), [
      [t("Servers"), d.servers.length ? d.servers.filter((s) => s.isEnabled).length + "/" + d.servers.length : t("Not configured")],
      [t("Refresh Interval"), d.pollIntervalSeconds + "s"],
      [t("Language"), (languageChoices().find((choice) => choice.value === d.languagePreference) || {}).label],
      [t("Theme"), theme[d.appearanceMode]],
      [t("Launch at Login"), ui.data.launchAtLogin === "enabled" ? t("On") : t("Off")],
      [t("Busy Detection"), busy[d.busyDetectionMode]],
    ]),
    infoCard(t("Runtime Snapshot"), runtimeRows),
  ];
}

// ---------- Modals ----------

function openSheet(title, body, actions) {
  const modal = document.getElementById("modal");
  const sheet = h("div", "sheet", h("h2", "", title), ...[].concat(body), h("div", "sheet-actions", ...actions));
  sheet.setAttribute("role", "dialog");
  sheet.setAttribute("aria-modal", "true");
  modal.replaceChildren(sheet);
  modal.hidden = false;
  (sheet.querySelector(".primary") || sheet.querySelector("button")).focus();
}
function closeSheet() { document.getElementById("modal").hidden = true; }

function confirmClear() {
  openSheet(t("Clear all saved settings?"),
    h("p", "", t("This removes every server, saved password, watch and notification history, and resets all settings. It cannot be undone.")), [
      button(t("Cancel"), closeSheet),
      button(t("Clear Saved Settings"), () => { closeSheet(); send({ type: "clearSettings" }); }, { className: "primary destructive" }),
    ]);
}

function confirmRemoveServer(index) {
  const server = ui.draft.servers[index];
  if (!server) return;
  openSheet(t("Remove %@?", displayName(server)),
    h("p", "", t("Its settings and saved password are removed. It cannot be undone.")), [
      button(t("Cancel"), closeSheet),
      button(t("Remove"), () => {
        closeSheet();
        const servers = ui.draft.servers;
        servers.splice(index, 1);
        ui.selectedServerId = servers[Math.min(index, servers.length - 1)]?.id || "";
        changed({ rerender: true });
      }, { className: "primary destructive" }),
    ]);
}

// Turning GPU history on asks first (macOS 0.9): it stores data, including other users' names.
function confirmHistory() {
  openSheet(t("Record GPU history?"),
    h("p", "", t("NVBeacon keeps 24 hours of per-user GPU utilization on this PC, about 0.3 MB per GPU. It includes the user names of everyone using the GPUs.")), [
      button(t("Cancel"), closeSheet),
      button(t("Record"), () => { closeSheet(); ui.draft.recordsGPUHistory = true; changed({ rerender: true }); }, { className: "primary" }),
    ]);
}

function confirmDeleteHistory() {
  openSheet(t("Delete GPU history?"),
    h("p", "", t("All recorded GPU history on this PC is deleted. It cannot be undone.")), [
      button(t("Cancel"), closeSheet),
      button(t("Delete History"), () => { closeSheet(); send({ type: "deleteHistory" }); }, { className: "primary destructive" }),
    ]);
}

function toast(text, isError) {
  const node = h("div", "toast" + (isError ? " error" : ""), text);
  node.setAttribute("role", "status");
  document.body.append(node);
  setTimeout(() => node.remove(), 3200);
}

// ---------- Rendering ----------

function renderTabs() {
  const tabs = document.getElementById("tabs");
  tabs.replaceChildren(...TABS.map((tab) => {
    const node = h("button", "tab", svgIcon(tab.icon), h("span", "", tab.label()));
    node.setAttribute("role", "tab");
    node.setAttribute("aria-selected", String(ui.tab === tab.id));
    node.dataset.key = "tab:" + tab.id;
    node.addEventListener("click", () => { ui.tab = tab.id; render(); document.getElementById("pane").scrollTop = 0; });
    return node;
  }));
}

function render() {
  if (!ui.data) return;
  document.documentElement.dataset.theme = ui.data.theme;
  document.documentElement.lang = ui.data.language;
  if (!ui.draft.servers.some((s) => s.id === ui.selectedServerId)) ui.selectedServerId = ui.draft.servers[0]?.id || "";
  const focusedKey = document.activeElement?.dataset?.key;
  const pane = document.getElementById("pane");
  const scroll = pane.scrollTop;
  renderTabs();
  const builders = { general: generalPane, servers: serversPane, monitoring: monitoringPane, notifications: notificationsPane,
    display: displayPane, advanced: advancedPane, about: aboutPane };
  if (!builders[ui.tab]) ui.tab = "general";
  pane.replaceChildren(h("div", "form", ...builders[ui.tab]()));
  pane.scrollTop = scroll;
  if (focusedKey) document.querySelector('[data-key="' + CSS.escape(focusedKey) + '"]')?.focus({ preventScroll: true });
}

// ---------- Messages from Swift ----------

function receive(message) {
  switch (message.type) {
    case "settings":
      ui.data = message;
      // Keep edits that have not been sent yet (an alert or watch change can push
      // fresh data while the user is typing).
      if (!ui.applyPending || !ui.draft) ui.draft = JSON.parse(JSON.stringify(message.settings));
      render();
      break;
    case "runtime":
      ui.runtime = message;
      if (ui.tab === "about") render();
      break;
    case "identityPicked": {
      const server = ui.draft.servers.find((s) => s.id === message.serverId);
      if (server) { server.sshIdentityFilePath = message.path; changed({ rerender: true }); }
      break;
    }
    case "launchAtLogin":
      ui.data.launchAtLogin = message.status;
      ui.launchError = message.error || null;
      render();
      break;
    case "importPreview": {
      const list = h("ul", "", ...message.servers.map((s) => h("li", "", s.name + (s.name !== s.target ? " — " + s.target : ""))));
      openSheet(t("Import Servers"), [
        h("p", "", t("%@ servers from %@ will be added as disabled servers. Your %@ existing servers are kept.", message.servers.length, message.fileName, message.existing)),
        list,
      ], [
        button(t("Cancel"), () => { closeSheet(); send({ type: "cancelImport" }); }),
        button(t("Import"), () => { closeSheet(); send({ type: "confirmImport" }); }, { className: "primary" }),
      ]);
      break;
    }
    case "diagnostics":
      openSheet(t("Diagnostic Information"), [
        h("p", "", t("Review the report before sharing it. Host names, users, addresses, key paths, custom commands and process details are not included.")),
        h("pre", "", message.report),
      ], [
        button(t("Close"), closeSheet),
        button(t("Copy"), () => { send({ type: "copyText", text: message.report }); closeSheet(); toast(t("Copied.")); }, { className: "primary" }),
      ]);
      break;
    case "testResult":
      ui.testResult = { serverId: message.serverId, ok: message.ok, text: message.text };
      if (ui.tab === "servers") render();
      break;
    case "notice":
      toast(message.text);
      break;
    case "error":
      toast(message.text, true);
      break;
  }
}

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (!document.getElementById("modal").hidden) closeSheet();
    else { flushApply(); send({ type: "close" }); }
  }
});
if (host) host.addEventListener("message", (event) => receive(event.data));
send({ type: "ready", width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio });
