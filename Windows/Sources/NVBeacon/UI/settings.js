"use strict";

// Settings page. Mirrors the macOS Settings window (Sources/NVBeacon/SettingsView.swift):
// five tabs of grouped forms, auto-applied 350 ms after the last change.
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

const t = (english, korean) => (ui.data && ui.data.language === "ko" ? korean : english);

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
  return keyed(input, key);
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
  minus.setAttribute("aria-label", t("Decrease", "감소"));
  plus.setAttribute("aria-label", t("Increase", "증가"));
  return h("span", "stepper", minus, input, plus, h("span", "suffix", suffix));
}

// ---------- Draft editing ----------

function changed(options = {}) {
  clearTimeout(ui.applyTimer);
  ui.applyPending = true;
  ui.applyTimer = setTimeout(() => {
    ui.applyPending = false;
    send({ type: "apply", settings: ui.draft });
  }, 350);
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
function updateServer(field, value, rerender) {
  const server = selectedServer();
  if (!server) return;
  server[field] = value;
  changed({ rerender });
}
function displayName(server) {
  return (server.name || "").trim() || (server.sshTarget || "").trim() || t("New Server", "새 서버");
}
// Password rows (macOS "Password Session" / "SSH Password"). The password goes straight
// to Swift, which stores it in Windows Credential Manager; it is never part of the draft.
function passwordRows(server) {
  const saved = (ui.data.savedPasswords || []).includes(server.id);
  const status = h("span", saved ? "status-enabled" : "status-warning", saved ? t("Saved", "저장됨") : t("Not saved", "저장 안 됨"));
  const field = textField("server-password", ui.passwordDraft, saved ? t("Enter a new password", "새 비밀번호 입력") : t("Required", "필수"), "w-240",
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
  const saveButton = button(t("Save Password", "비밀번호 저장"), savePassword, { disabled: !ui.passwordDraft, key: "password-save" });
  const forget = button(t("Forget Saved Password", "저장된 비밀번호 삭제"), () => send({ type: "forgetPassword", serverId: server.id }),
    { className: "destructive", disabled: !saved, key: "password-forget" });
  return [
    row(t("Saved password", "저장된 비밀번호"), [status, forget]),
    row(t("SSH password", "SSH 비밀번호"), [field, saveButton]),
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
  { id: "general", icon: "gear", label: () => t("General", "일반") },
  { id: "servers", icon: "serverRack", label: () => t("Servers", "서버") },
  { id: "monitoring", icon: "chart", label: () => t("Monitoring", "모니터링") },
  { id: "notifications", icon: "bell", label: () => t("Notifications", "알림") },
  { id: "display", icon: "display", label: () => t("Display", "표시") },
  { id: "advanced", icon: "sliders", label: () => t("Advanced", "고급") },
  { id: "about", icon: "infoLarge", label: () => t("About", "정보") },
];

const BUSY_MODES = () => [
  { value: "activeProcess", label: t("Active Process", "활성 프로세스") },
  { value: "memoryThreshold", label: t("Memory Threshold", "메모리 기준") },
  { value: "activeProcessOrMemoryThreshold", label: t("Process or Memory", "프로세스 또는 메모리") },
  { value: "utilizationThreshold", label: t("Utilization Threshold", "사용률 기준") },
];

function generalPane() {
  const d = ui.draft;
  const status = ui.data.launchAtLogin;
  const statusText = status === "enabled" ? t("On", "켜짐") : status === "otherLocation"
    ? t("Registered for another copy of NVBeacon", "다른 위치의 NVBeacon이 등록됨") : t("Off", "꺼짐");
  const startupRows = [
    toggleRow(t("Launch at login", "로그인 시 실행"), "launch-at-login", status === "enabled",
      (value) => send({ type: "setLaunchAtLogin", enabled: value })),
    row(t("Status", "상태"), [
      h("span", status === "enabled" ? "status-enabled" : status === "otherLocation" ? "status-warning" : "", statusText),
      button(t("Refresh", "새로고침"), () => send({ type: "reloadHosts" }), { key: "startup-refresh" })],
      ui.launchError || null),
  ];
  return [
    section(t("Startup", "시작"), startupRows,
      t("Uses the per-user Run key, the same list as Task Manager's Startup apps.", "사용자별 Run 키에 등록합니다. 작업 관리자의 시작 앱 목록과 같은 곳입니다.")),
    section(t("Language", "언어"), [
      row(t("Language", "언어"), select("language", d.languagePreference, [
        { value: "system", label: t("System", "시스템") },
        { value: "english", label: "English" },
        { value: "korean", label: t("Korean", "한국어") },
      ], (value) => { d.languagePreference = value; changed(); })),
    ]),
  ];
}

function serversPane() {
  const d = ui.draft;
  const servers = d.servers;
  const index = servers.findIndex((s) => s.id === ui.selectedServerId);
  const nodes = [];

  if (ui.data.sessionOverride) {
    nodes.push(h("div", "banner", svgIcon("info"), t(
      "Servers passed on the command line (or --demo) are being monitored for this session. The saved servers below are used on the next normal launch.",
      "이번 실행은 명령줄(또는 --demo)로 받은 서버를 모니터링합니다. 아래 저장된 서버는 다음 일반 실행부터 사용됩니다.")));
  }

  const picker = select("server-picker", ui.selectedServerId,
    servers.map((s) => ({ value: s.id, label: displayName(s) })),
    (value) => { ui.selectedServerId = value; ui.passwordDraft = ""; ui.testResult = null; render(); },
    { widthClass: "w-300", disabled: !servers.length });
  const moveUp = button(t("Move Server Up", "서버를 위로 이동"), () => {
    [servers[index - 1], servers[index]] = [servers[index], servers[index - 1]];
    changed({ rerender: true });
  }, { icon: "chevronUp", className: "icon", disabled: index <= 0, key: "server-up" });
  const moveDown = button(t("Move Server Down", "서버를 아래로 이동"), () => {
    [servers[index + 1], servers[index]] = [servers[index], servers[index + 1]];
    changed({ rerender: true });
  }, { icon: "chevronDown", className: "icon", disabled: index < 0 || index === servers.length - 1, key: "server-down" });
  const remove = button(t("Remove Server…", "서버 삭제…"), () => confirmRemoveServer(index),
    { icon: "trash", className: "icon destructive", disabled: index < 0, key: "server-remove" });
  nodes.push(section(t("Servers", "서버"), [row(t("Selected server", "선택된 서버"), [picker, moveUp, moveDown, remove])],
    t("The popover lists servers in this order.", "팝오버는 이 순서로 서버를 표시합니다.")));

  const hosts = ui.data.sshConfigHosts || [];
  const addRows = [row(t("New server", "새 서버"), [
    button(t("Add Server", "서버 추가"), () => {
      const server = newServer({ name: t("New Server", "새 서버") });
      servers.push(server);
      ui.selectedServerId = server.id;
      changed({ rerender: true });
    })])];
  const hostPicker = select("saved-host", ui.selectedHostAlias,
    [{ value: "", label: hosts.length ? t("Select a saved host", "저장된 호스트 선택") : t("No saved hosts", "저장된 호스트 없음") }]
      .concat(hosts.map((entry) => ({ value: entry.alias, label: entry.alias }))),
    (value) => { ui.selectedHostAlias = value; render(); }, { widthClass: "w-240", disabled: !hosts.length });
  const addHost = button(t("Add", "추가"), () => {
    // The alias is the target, so ssh applies the rest of the Host block itself (as on macOS).
    const server = newServer({ name: ui.selectedHostAlias, sshTarget: ui.selectedHostAlias });
    servers.push(server);
    ui.selectedServerId = server.id;
    ui.selectedHostAlias = "";
    changed({ rerender: true });
  }, { disabled: !ui.selectedHostAlias, key: "saved-host-add" });
  const chosen = hosts.find((entry) => entry.alias === ui.selectedHostAlias);
  let hostCaption = t("From ", "가져올 위치: ") + ui.data.sshConfigPath;
  if (chosen) {
    const parts = [chosen.user && chosen.hostName ? chosen.user + "@" + chosen.hostName : chosen.hostName || chosen.alias];
    if (chosen.port) parts.push(t("port ", "포트 ") + chosen.port);
    if (chosen.identityFile) parts.push(t("key ", "키 ") + chosen.identityFile);
    hostCaption = parts.join(" · ");
  }
  addRows.push(row(t("Saved host", "저장된 호스트"), [hostPicker, addHost,
    button(t("Reload Saved Hosts", "저장된 호스트 새로고침"), () => send({ type: "reloadHosts" }), { icon: "refresh", className: "icon", key: "hosts-reload" })],
    hostCaption));
  nodes.push(section(t("Add Server", "서버 추가"), addRows));

  const server = selectedServer();
  if (!server) {
    nodes.push(section(t("Selected Server", "선택된 서버"), [],
      t("Add a server to start monitoring remote GPUs.", "원격 GPU 모니터링을 시작하려면 서버를 추가하세요.")));
    return nodes;
  }
  const password = server.sshAuthenticationMode === "passwordBased";
  const connectionRows = [
    toggleRow(t("Enabled", "사용"), "server-enabled", server.isEnabled, (value) => updateServer("isEnabled", value)),
    row(t("Name", "이름"), textField("server-name", server.name, server.sshTarget || "GPU Server", "w-240",
      (value) => { updateServer("name", value); refreshServerPickerLabel(); })),
    row(t("SSH target", "SSH 대상"), textField("server-target", server.sshTarget, "gpu-prod or user@host", "w-320",
      (value) => { updateServer("sshTarget", value); refreshServerPickerLabel(); }), t("A host alias from the ssh config, or user@host", "ssh 설정의 호스트 별칭 또는 user@host")),
    row(t("SSH port", "SSH 포트"), textField("server-port", server.sshPort, "22", "w-120", (value) => updateServer("sshPort", value)),
      t("Optional · Default 22 or the ssh config", "선택 사항 · 기본값 22 또는 ssh 설정")),
    row(t("Authentication", "인증 방식"), select("server-auth", server.sshAuthenticationMode, [
      { value: "keyBased", label: t("Key-based", "키 기반") },
      { value: "passwordBased", label: t("Password", "비밀번호") },
    ], (value) => updateServer("sshAuthenticationMode", value, true))),
    row(t("Key file", "키 파일"), [
      textField("server-identity", server.sshIdentityFilePath, t("Optional", "선택 사항"), "w-240", (value) => updateServer("sshIdentityFilePath", value)),
      button(t("Browse…", "찾아보기…"), () => send({ type: "browseIdentity", serverId: server.id }))]),
  ];
  if (password) connectionRows.push(...passwordRows(server));
  nodes.push(section(t("Connection", "연결"), connectionRows, password
    ? t("The password is kept in Windows Credential Manager for your Windows account and answers only this server's SSH password prompt, once per connection. Programs running as your Windows user can read it, so SSH keys are safer when the server allows them. If the server rejects the password, collection stops until you save it again.",
        "비밀번호는 현재 Windows 계정의 Windows 자격 증명 관리자에 저장되고, 이 서버의 SSH 비밀번호 질문에만 연결당 한 번 사용됩니다. 같은 Windows 사용자로 실행되는 프로그램은 읽을 수 있으므로, 서버가 허용하면 SSH 키가 더 안전합니다. 서버가 비밀번호를 거부하면 다시 저장할 때까지 수집을 멈춥니다.")
    : null));

  const reuseMode = server.sshConnectionReuseMode || "reuseWhenPossible";
  const reuseHelp = h("span", "", svgIcon("question", "help"));
  reuseHelp.title = reuseMode === "reuseWhenPossible"
    ? t("NVBeacon keeps the SSH connection open and reuses it instead of logging in again for every refresh. No extra software is required on the server. If your server behaves strangely, switch to a new connection every refresh.",
      "NVBeacon은 새로고침마다 다시 로그인하지 않고 SSH 연결을 열어 둔 채 재사용합니다. 서버에 별도로 설치할 것은 없습니다. 서버 동작이 이상하면 매 새로고침마다 새 연결로 바꾸세요.")
    : t("Every refresh opens a brand-new SSH connection. This is slower, but suits unusual SSH servers.",
      "새로고침마다 완전히 새 SSH 연결을 엽니다. 더 느리지만 특이한 SSH 서버와 더 잘 맞을 수 있습니다.");
  const testResult = ui.testResult && ui.testResult.serverId === server.id ? ui.testResult : null;
  nodes.push(section(t("SSH Connection", "SSH 연결"), [
    row(t("Connection reuse", "연결 재사용"), [
      select("server-reuse", reuseMode, [
        { value: "reuseWhenPossible", label: t("Reuse connection (Recommended)", "연결 재사용 (권장)") },
        { value: "newConnectionEachRefresh", label: t("New connection every refresh", "매 새로고침마다 새 연결") },
      ], (value) => updateServer("sshConnectionReuseMode", value, true)),
      reuseHelp]),
    row(t("Connection test", "연결 테스트"), [
      testResult ? h("span", testResult.ok ? "status-enabled" : testResult.pending ? "" : "status-warning", testResult.text) : null,
      button(t("Test Connection", "연결 테스트"), () => {
        flushApply();
        ui.testResult = { serverId: server.id, pending: true, text: t("Testing…", "테스트 중…") };
        render();
        send({ type: "testConnection", serverId: server.id });
      }, { disabled: !!(testResult && testResult.pending) || !(server.sshTarget || "").trim(), key: "server-test" })],
      t("Runs the GPU query once over a new connection. Nothing is saved.", "새 연결로 GPU 조회를 한 번 실행합니다. 저장되는 것은 없습니다.")),
  ]));

  nodes.push(commandSection(t("GPU Query Command", "GPU 조회 명령"), "gpu-command", "remoteCommand", ui.data.defaults.gpuCommand,
    t("Leave empty to restore the default command.", "비워 두면 기본 명령으로 돌아갑니다.")));
  nodes.push(commandSection(t("Host Information Query Command", "호스트 정보 수집 명령"), "host-command", "hostCommand", ui.data.defaults.hostCommand,
    t("Collects CPU, RAM/Swap and network in the same refresh. Keep the section markers and collection switches when customizing. Leave empty to restore the default command.",
      "CPU·RAM/Swap·네트워크를 같은 새로고침에서 수집합니다. 수정할 때 영역 구분자와 항목별 수집 조건을 유지하세요. 비워 두면 기본 명령으로 돌아갑니다.")));
  return nodes;
}

function monitoringPane() {
  const d = ui.draft;
  const collectionRows = [
    row(t("Refresh interval", "새로고침 주기"),
      stepper("poll-interval", d.pollIntervalSeconds, 1, 300, "s", (value) => { d.pollIntervalSeconds = value; changed(); }),
      t("1–300 s · Default 10 s", "1–300초 · 기본값 10초")),
    row(t("Busy detection", "사용 중 판정"), select("busy-mode", d.busyDetectionMode, BUSY_MODES(), (value) => { d.busyDetectionMode = value; changed({ rerender: true }); })),
  ];
  if (d.busyDetectionMode === "memoryThreshold" || d.busyDetectionMode === "activeProcessOrMemoryThreshold") {
    collectionRows.push(row(t("Busy memory threshold", "사용 중 메모리 기준"),
      stepper("busy-memory", d.busyMemoryThresholdMB, 0, 10240, "MB", (value) => { d.busyMemoryThresholdMB = value; changed(); }),
      t("0–10240 MB · Default 50 MB", "0–10240MB · 기본값 50MB")));
  }
  if (d.busyDetectionMode === "utilizationThreshold") {
    collectionRows.push(row(t("Busy utilization threshold", "사용 중 사용률 기준"),
      stepper("busy-util", d.busyUtilizationThresholdPercent, 0, 100, "%", (value) => { d.busyUtilizationThresholdPercent = value; changed(); }),
      t("0–100 % · Default 10 %", "0–100% · 기본값 10%")));
  }
  collectionRows.push(toggleRow(t("Highlight my processes", "내 프로세스 강조"), "highlight-mine", d.highlightsMyProcesses,
    (value) => { d.highlightsMyProcesses = value; changed({ rerender: true }); },
    { sublabel: d.highlightsMyProcesses
      ? t("Highlights the SSH user's processes and their GPUs.", "SSH 사용자의 프로세스와 해당 GPU를 강조합니다.")
      : t("Also skips the extra owner check during collection.", "수집 중 추가 소유자 확인도 생략합니다.") }));

  const hostRows = [
    toggleRow(t("Collect host information", "호스트 정보 수집"), "host-info", d.collectsHostInfo, (value) => { d.collectsHostInfo = value; changed({ rerender: true }); }),
    toggleRow("CPU", "host-cpu", d.collectsHostCPU, (value) => { d.collectsHostCPU = value; changed(); }, { disabled: !d.collectsHostInfo }),
    toggleRow(t("Memory (RAM / Swap)", "메모리 (RAM / Swap)"), "host-memory", d.collectsHostMemory, (value) => { d.collectsHostMemory = value; changed(); }, { disabled: !d.collectsHostInfo }),
    toggleRow(t("Network", "네트워크"), "host-network", d.showsNetworkUsage, (value) => { d.showsNetworkUsage = value; changed(); }, { disabled: !d.collectsHostInfo }),
  ];
  for (const node of hostRows.slice(1)) node.classList.add("indent");

  return [
    section(t("Collection", "수집"), collectionRows),
    section(t("Host Information", "호스트 정보"), hostRows,
      t("Applies to all servers. Items that are off are not collected. Collapsing a server's host information only hides it; collection continues.",
        "모든 서버에 적용됩니다. 끈 항목은 수집하지 않습니다. 호스트 정보를 접으면 화면에서만 숨겨지고 수집은 계속됩니다.")),
    section(t("GPU History", "GPU 기록"), [
      toggleRow(t("Record GPU history", "GPU 기록 저장"), "gpu-history", d.recordsGPUHistory, (value) => {
        if (value) { confirmHistory(); render(); } else { d.recordsGPUHistory = false; changed({ rerender: true }); }
      }, { sublabel: t("Opens from the chart button in the popover.", "팝오버의 차트 버튼으로 엽니다.") }),
      row(t("Saved history", "저장된 기록"), button(t("Delete History…", "기록 삭제…"), confirmDeleteHistory,
        { className: "destructive", key: "history-delete" })),
    ], t("Keeps 24 hours of per-user GPU utilization on this PC. Adds one nvidia-smi pmon sample per server at most once a minute.",
         "이 PC에 최근 24시간의 사용자별 GPU 사용률을 저장합니다. 서버마다 최대 1분에 한 번 nvidia-smi pmon을 실행합니다.")),
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
  permissionEnabled: ["Permission enabled", "권한 허용"],
  permissionDenied: ["Permission denied", "권한 거부"],
  watchAdded: ["Process watch added", "프로세스 감시 추가"],
  watchRemoved: ["Process watch removed", "프로세스 감시 해제"],
  idleWatchAdded: ["GPU idle watch added", "GPU 유휴 감시 추가"],
  idleWatchRemoved: ["GPU idle watch removed", "GPU 유휴 감시 해제"],
  testNotificationScheduled: ["Test notification sent", "테스트 알림 전송"],
  exitNotificationScheduled: ["Process exit notification sent", "프로세스 종료 알림 전송"],
  idleNotificationScheduled: ["GPU idle notification sent", "GPU 유휴 알림 전송"],
};

function watchRow(badge, badgeClass, title, primary, secondary, id) {
  const remove = button(t("Remove", "해제"), () => send({ type: "removeWatch", id }), { key: "remove:" + id });
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
    watchRows.push(watchRow(t("GPU Idle", "GPU 유휴"), "idle", watch.title, watch.subtitle,
      t("Idle " + d.idleNotificationSeconds + " s · ≤" + d.idleMemoryThresholdMB + " MB", "유휴 " + d.idleNotificationSeconds + "초 · " + d.idleMemoryThresholdMB + "MB 이하"), watch.id));
  }
  for (const watch of n.processWatches) {
    watchRows.push(watchRow(t("Process Exit", "프로세스 종료"), "exit", watch.title,
      t("User " + watch.user + " · PID " + watch.pid + " · GPU " + watch.gpu, "사용자 " + watch.user + " · PID " + watch.pid + " · GPU " + watch.gpu),
      watch.connection, watch.id));
  }
  const historyRows = n.history.map((entry) => h("div", "info-row history-row",
    h("span", "", h("strong", "", t(...(HISTORY_TITLES[entry.kind] || [entry.kind, entry.kind]))), h("br"), entry.subtitle),
    h("span", "", new Date(entry.time).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }))));
  return [
    section(t("Permission", "권한"), [
      row(t("Status", "상태"), [h("span", "", t("Shown through the tray icon", "트레이 아이콘으로 표시")),
        button(t("Send Test Notification", "테스트 알림 보내기"), () => send({ type: "testNotification" }))]),
    ], t("Windows shows these as notifications from NVBeacon. If they do not appear, check Settings › System › Notifications and Do not disturb.",
         "Windows가 NVBeacon의 알림으로 표시합니다. 보이지 않으면 Windows 설정 › 시스템 › 알림과 방해 금지 모드를 확인하세요.")),
    section(t("GPU Idle Alert", "GPU 유휴 알림"), [
      row(t("Idle duration", "유휴 시간"),
        stepper("idle-seconds", d.idleNotificationSeconds, 1, 3600, "s", (value) => { d.idleNotificationSeconds = value; changed(); }),
        t("1–3600 s · Default 300 s", "1–3600초 · 기본값 300초")),
      row(t("Memory threshold", "메모리 기준"),
        stepper("idle-memory", d.idleMemoryThresholdMB, 0, 10240, "MB", (value) => { d.idleMemoryThresholdMB = value; changed(); }),
        t("0–10240 MB · Default 50 MB", "0–10240MB · 기본값 50MB")),
    ], t("Starred GPUs send an alert when they stay idle this long.", "별표한 GPU가 이 시간 동안 유휴 상태이면 알림을 보냅니다.")),
    section(t("Active Watches", "활성 감시"), watchRows,
      watchRows.length ? null : t("There are no watches.", "설정된 감시가 없습니다.")),
    section(t("Recent 24 Hours", "최근 24시간"), historyRows,
      historyRows.length ? null : t("Nothing in the last 24 hours.", "최근 24시간 동안 기록이 없습니다.")),
  ];
}

function displayPane() {
  const d = ui.draft;
  const trayCaptions = {
    averageAndBusy: t("Average utilization, with a bar for the share of busy GPUs.", "평균 사용률과 사용 중 GPU 비율 막대를 표시합니다."),
    averageOnly: t("Average utilization of all GPUs.", "전체 GPU의 평균 사용률을 표시합니다."),
    busyOnly: t("Number of busy GPUs.", "사용 중인 GPU 수를 표시합니다."),
    iconOnly: t("The app icon. Point at it to see the summary.", "앱 아이콘만 표시합니다. 마우스를 올리면 요약을 볼 수 있습니다."),
  };
  return [
    section(t("Tray Icon", "트레이 아이콘"), [
      // macOS "Menu bar text": the tray draws the number into its icon instead.
      row(t("Tray icon", "트레이 아이콘"), select("tray-style", d.trayIconStyle, [
        { value: "averageAndBusy", label: t("Average + Busy", "평균 + 사용 중") },
        { value: "averageOnly", label: t("Average Util", "평균 사용률") },
        { value: "busyOnly", label: t("Busy Count", "사용 중 개수") },
        { value: "iconOnly", label: t("Icon Only", "아이콘만") },
      ], (value) => { d.trayIconStyle = value; changed({ rerender: true }); }), trayCaptions[d.trayIconStyle]),
      toggleRow(t("Color by load", "사용량에 따라 색 표시"), "tray-color", d.trayIconUsesColor,
        (value) => { d.trayIconUsesColor = value; changed(); },
        { disabled: d.trayIconStyle === "iconOnly", sublabel: t("Green, amber or red badge. Off: the number in the taskbar's text color.", "초록·주황·빨강 배지로 표시합니다. 끄면 작업 표시줄 글자색으로 숫자만 표시합니다.") }),
    ], t("Point at the tray icon for a summary of every server.", "트레이 아이콘에 마우스를 올리면 모든 서버의 요약이 나옵니다.")),
    section(t("Window", "창"), [
      row(t("Display mode", "표시 방식"), select("display-mode", d.displayMode, [
        { value: "popover", label: t("Popover", "팝오버") },
        { value: "window", label: t("Window", "창") },
      ], (value) => { d.displayMode = value; changed({ rerender: true }); }),
        t("Window keeps NVBeacon open like a normal app window.", "창은 NVBeacon을 일반 앱 창처럼 계속 띄워 둡니다.")),
      toggleRow(t("Keep window on top", "항상 위에 표시"), "window-on-top", d.windowAlwaysOnTop,
        (value) => { d.windowAlwaysOnTop = value; changed(); }, { disabled: d.displayMode !== "window" }),
      row(t("Theme", "테마"), select("theme", d.appearanceMode, [
        { value: "system", label: t("System", "시스템") },
        { value: "light", label: t("Light", "라이트") },
        { value: "dark", label: t("Dark", "다크") },
      ], (value) => { d.appearanceMode = value; changed(); })),
    ]),
    section(t("Popover", "팝오버"), [
      row(t("Popover width", "팝오버 너비"),
        stepper("popover-width", d.popoverWidth, 480, 800, "pt", (value) => { d.popoverWidth = value; changed(); }, 20),
        t("480–800 pt · Default 500 pt", "480–800pt · 기본값 500pt")),
      row(t("Popover height", "팝오버 높이"), [
        select("popover-height-mode", d.popoverHeightMode, [
          { value: "automatic", label: t("Fit Content", "내용에 맞춤") },
          { value: "fixed", label: t("Fixed", "고정") },
        ], (value) => { d.popoverHeightMode = value; changed({ rerender: true }); }),
        d.popoverHeightMode === "fixed"
          ? stepper("popover-height", d.popoverHeight, 320, 1100, "pt", (value) => { d.popoverHeight = value; changed(); }, 20)
          : null,
      ], d.popoverHeightMode === "fixed"
        ? t("320–1100 pt · Default 600 pt · Content scrolls inside", "320–1100pt · 기본값 600pt · 넘치는 내용은 스크롤")
        : t("Up to the screen height", "최대 화면 높이까지")),
      toggleRow(t("Close on outside click", "바깥 클릭 시 닫기"), "close-outside", d.closesPopoverOnOutsideClick,
        (value) => { d.closesPopoverOnOutsideClick = value; changed({ rerender: true }); },
        { sublabel: d.closesPopoverOnOutsideClick
          ? t("Closes when you click outside it or switch to another app.", "바깥이나 다른 앱을 클릭하면 닫습니다.")
          : t("Stays open until you click the tray icon again.", "트레이 아이콘을 다시 클릭할 때까지 유지합니다.") }),
    ]),
  ];
}

function commandSection(title, key, field, defaultCommand, footer) {
  const server = selectedServer();
  const area = h("textarea", "text");
  area.spellcheck = false;
  area.value = server ? server[field] : "";
  area.disabled = !server;
  area.addEventListener("input", () => updateServer(field, area.value));
  keyed(area, key);
  const restore = button(t("Restore Default", "기본값으로 복원"), () => { updateServer(field, defaultCommand, true); }, {
    disabled: !server || (server && server[field] === defaultCommand), key: key + ":restore" });
  return section(title, [h("div", "row stack", area, h("div", "row-control", restore))], footer);
}

function advancedPane() {
  const d = ui.draft;
  return [
    section(t("Server Settings Backup", "서버 설정 백업"), [row(t("Servers", "서버"), [
      button(t("Export Servers…", "서버 내보내기…"), () => send({ type: "exportServers" }), { disabled: !d.servers.some((s) => (s.sshTarget || "").trim()) }),
      button(t("Import Servers…", "서버 가져오기…"), () => send({ type: "importServers" }))])],
      t("Exports host names, key file paths and remote commands. Passwords, private key contents and watches are excluded. Imports add disabled servers without replacing existing settings. The file format is shared with NVBeacon for macOS.",
        "호스트·키 파일 경로·원격 명령을 내보냅니다. 비밀번호·개인 키 내용·감시는 제외됩니다. 가져온 서버는 비활성 상태로 추가되며 기존 설정을 덮어쓰지 않습니다. 파일 형식은 macOS용 NVBeacon과 같습니다.")),
    section(t("Support", "문제 신고"), [row(t("Diagnostic information", "진단 정보"),
      button(t("Copy Diagnostic Information…", "진단 정보 복사…"), () => send({ type: "diagnostics" })))],
      t("Preview a report of the current app and collection state. No additional SSH commands are run.", "앱과 수집 상태를 미리 확인하고 복사합니다. 추가 SSH 명령은 실행하지 않습니다.")),
    section(t("Saved State", "저장 상태"), [row(t("Settings", "설정"), [
      button(t("Open settings.json", "settings.json 열기"), () => send({ type: "openSettingsFile" })),
      button(t("Reload Settings", "설정 다시 불러오기"), () => send({ type: "reload" })),
      button(t("Clear Saved Settings…", "저장된 설정 지우기…"), confirmClear, { className: "destructive" })])],
      t("Clearing removes every server, saved password, watch and notification history.", "지우면 모든 서버, 저장된 비밀번호, 감시와 알림 기록이 삭제됩니다.")),
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
  link.title = t("Open the GitHub repository", "GitHub 저장소 열기");
  const busy = Object.fromEntries(BUSY_MODES().map((mode) => [mode.value, mode.label]));
  const language = { system: t("System", "시스템"), english: "English", korean: t("Korean", "한국어") };
  const theme = { system: t("System", "시스템"), light: t("Light", "라이트"), dark: t("Dark", "다크") };
  const runtimeRows = r && r.loaded ? [
    [t("Visible GPUs", "표시 중인 GPU"), r.visibleGPUs], [t("Busy GPUs", "사용 중인 GPU"), r.busyGPUs],
    [t("Processes", "프로세스"), r.processes], [t("Average Utilization", "평균 사용률"), r.averageUtilization + "%"],
    [t("Server Errors", "서버 오류"), r.serverErrors],
  ] : [[t("GPU data has not been loaded yet.", "GPU 데이터가 아직 로드되지 않았습니다."), ""]];
  return [
    h("div", "about-head", icon, h("div", "about-name", "NVBeacon"),
      h("div", "", t("Remote NVIDIA GPU monitoring from your Windows notification area.", "Windows 알림 영역에서 원격 NVIDIA GPU를 확인하는 앱입니다.")), link),
    infoCard(t("Build Information", "빌드 정보"), [
      [t("Version", "버전"), ui.data.about.version],
      [t("Repository", "저장소"), "github.com/jaein4722/NVBeacon"],
      [t("Developer", "개발자"), "github.com/jaein4722"],
      [t("Settings File", "설정 파일"), ui.data.about.settingsFile],
    ]),
    infoCard(t("Current Configuration", "현재 설정"), [
      [t("Servers", "서버"), d.servers.length ? d.servers.filter((s) => s.isEnabled).length + "/" + d.servers.length : t("Not configured", "미설정")],
      [t("Refresh Interval", "새로고침 주기"), d.pollIntervalSeconds + "s"],
      [t("Language", "언어"), language[d.languagePreference]],
      [t("Theme", "테마"), theme[d.appearanceMode]],
      [t("Launch at Login", "로그인 시 실행"), ui.data.launchAtLogin === "enabled" ? t("On", "켜짐") : t("Off", "꺼짐")],
      [t("Busy Detection", "사용 중 판정"), busy[d.busyDetectionMode]],
    ]),
    infoCard(t("Runtime Snapshot", "현재 상태"), runtimeRows),
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
  openSheet(t("Clear all saved settings?", "저장된 설정을 모두 지울까요?"),
    h("p", "", t("This removes every server, saved password, watch and notification history, and resets all settings. It cannot be undone.",
      "모든 서버, 저장된 비밀번호, 감시와 알림 기록이 삭제되고 설정이 초기화됩니다. 되돌릴 수 없습니다.")), [
      button(t("Cancel", "취소"), closeSheet),
      button(t("Clear Saved Settings", "저장된 설정 지우기"), () => { closeSheet(); send({ type: "clearSettings" }); }, { className: "primary destructive" }),
    ]);
}

function confirmRemoveServer(index) {
  const server = ui.draft.servers[index];
  if (!server) return;
  openSheet(t("Remove " + displayName(server) + "?", displayName(server) + " 서버를 삭제할까요?"),
    h("p", "", t("Its settings and saved password are removed. It cannot be undone.", "이 서버의 설정과 저장된 비밀번호가 삭제됩니다. 되돌릴 수 없습니다.")), [
      button(t("Cancel", "취소"), closeSheet),
      button(t("Remove", "삭제"), () => {
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
  openSheet(t("Record GPU history?", "GPU 기록을 저장할까요?"),
    h("p", "", t("NVBeacon keeps 24 hours of per-user GPU utilization on this PC, about 0.3 MB per GPU. It includes the user names of everyone using the GPUs.",
      "NVBeacon이 이 PC에 최근 24시간의 사용자별 GPU 사용률을 저장합니다. GPU당 약 0.3MB이며, GPU를 쓰는 모든 사용자의 이름이 포함됩니다.")), [
      button(t("Cancel", "취소"), closeSheet),
      button(t("Record", "저장"), () => { closeSheet(); ui.draft.recordsGPUHistory = true; changed({ rerender: true }); }, { className: "primary" }),
    ]);
}

function confirmDeleteHistory() {
  openSheet(t("Delete GPU history?", "GPU 기록을 삭제할까요?"),
    h("p", "", t("All recorded GPU history on this PC is deleted. It cannot be undone.", "이 PC에 저장된 GPU 기록이 모두 삭제됩니다. 되돌릴 수 없습니다.")), [
      button(t("Cancel", "취소"), closeSheet),
      button(t("Delete History", "기록 삭제"), () => { closeSheet(); send({ type: "deleteHistory" }); }, { className: "primary destructive" }),
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
      openSheet(t("Import Servers", "서버 가져오기"), [
        h("p", "", t(message.servers.length + " servers from " + message.fileName + " will be added as disabled servers. Your " + message.existing + " existing servers are kept.",
          message.fileName + "의 서버 " + message.servers.length + "개를 비활성 상태로 추가합니다. 기존 서버 " + message.existing + "개는 유지됩니다.")),
        list,
      ], [
        button(t("Cancel", "취소"), () => { closeSheet(); send({ type: "cancelImport" }); }),
        button(t("Import", "가져오기"), () => { closeSheet(); send({ type: "confirmImport" }); }, { className: "primary" }),
      ]);
      break;
    }
    case "diagnostics":
      openSheet(t("Diagnostic Information", "진단 정보"), [
        h("p", "", t("Review the report before sharing it. Host names, users, addresses, key paths, custom commands and process details are not included.",
          "공유하기 전에 내용을 확인하세요. 호스트 이름·사용자·주소·키 경로·사용자 지정 명령·프로세스 정보는 포함되지 않습니다.")),
        h("pre", "", message.report),
      ], [
        button(t("Close", "닫기"), closeSheet),
        button(t("Copy", "복사"), () => { send({ type: "copyText", text: message.report }); closeSheet(); toast(t("Copied.", "복사했습니다.")); }, { className: "primary" }),
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
    if (!document.getElementById("modal").hidden) closeSheet(); else send({ type: "close" });
  }
});
if (host) host.addEventListener("message", (event) => receive(event.data));
send({ type: "ready", width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio });
