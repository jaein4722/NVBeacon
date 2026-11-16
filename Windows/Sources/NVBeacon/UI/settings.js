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
function newServer(fields) {
  return Object.assign({
    id: crypto.randomUUID().toUpperCase(), name: "", sshTarget: "", sshPort: "", sshIdentityFilePath: "",
    sshAuthenticationMode: "keyBased", remoteCommand: ui.data.defaults.gpuCommand,
    hostCommand: ui.data.defaults.hostCommand, isEnabled: true,
  }, fields);
}

// ---------- Panes ----------

const TABS = [
  { id: "general", icon: "gear", label: () => t("General", "일반") },
  { id: "notifications", icon: "bell", label: () => t("Notifications", "알림") },
  { id: "appearance", icon: "display", label: () => t("Appearance", "표시") },
  { id: "advanced", icon: "sliders", label: () => t("Advanced", "고급") },
  { id: "about", icon: "infoLarge", label: () => t("About", "정보") },
];

function generalPane() {
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
    (value) => { ui.selectedServerId = value; render(); },
    { widthClass: "w-300", disabled: !servers.length });
  const moveUp = button(t("Move selected server up", "선택된 서버를 위로 이동"), () => {
    [servers[index - 1], servers[index]] = [servers[index], servers[index - 1]];
    changed({ rerender: true });
  }, { icon: "chevronUp", className: "icon", disabled: index <= 0, key: "server-up" });
  const moveDown = button(t("Move selected server down", "선택된 서버를 아래로 이동"), () => {
    [servers[index + 1], servers[index]] = [servers[index], servers[index + 1]];
    changed({ rerender: true });
  }, { icon: "chevronDown", className: "icon", disabled: index < 0 || index === servers.length - 1, key: "server-down" });
  const remove = button(t("Remove selected server", "선택된 서버 삭제"), () => {
    servers.splice(index, 1);
    ui.selectedServerId = servers[Math.min(index, servers.length - 1)]?.id || "";
    changed({ rerender: true });
  }, { icon: "trash", className: "icon destructive", disabled: index < 0, key: "server-remove" });
  nodes.push(section(t("Servers", "서버"), [row(t("Current", "현재"), [picker, moveUp, moveDown, remove])],
    t("The popover uses this server order.", "팝오버는 이 서버 순서를 사용합니다.")));

  const hosts = ui.data.sshConfigHosts || [];
  const addRows = [h("div", "row", h("div", "row-control",
    button(t("New Server", "새 서버"), () => {
      const server = newServer({ name: t("New Server", "새 서버") });
      servers.push(server);
      ui.selectedServerId = server.id;
      changed({ rerender: true });
    }),
    hosts.length ? button(t("Reload Saved Hosts", "저장된 호스트 새로고침"), () => send({ type: "reloadHosts" })) : null))];
  if (hosts.length) {
    const hostPicker = select("saved-host", ui.selectedHostAlias,
      [{ value: "", label: t("Select a saved host", "저장된 호스트 선택") }].concat(hosts.map((hostEntry) => ({ value: hostEntry.alias, label: hostEntry.alias }))),
      (value) => { ui.selectedHostAlias = value; render(); }, { widthClass: "w-240" });
    const add = button(t("Add Saved Host", "저장된 호스트 추가"), () => {
      // The alias is the target, so ssh applies the rest of the Host block itself (as on macOS).
      const server = newServer({ name: ui.selectedHostAlias, sshTarget: ui.selectedHostAlias });
      servers.push(server);
      ui.selectedServerId = server.id;
      ui.selectedHostAlias = "";
      changed({ rerender: true });
    }, { disabled: !ui.selectedHostAlias });
    addRows.push(row(t("Saved Host", "저장된 호스트"), [hostPicker, add]));
    const chosen = hosts.find((entry) => entry.alias === ui.selectedHostAlias);
    if (chosen) {
      const parts = [chosen.user && chosen.hostName ? chosen.user + "@" + chosen.hostName : chosen.hostName || chosen.alias];
      if (chosen.port) parts.push(t("port ", "포트 ") + chosen.port);
      if (chosen.identityFile) parts.push(t("key ", "키 ") + chosen.identityFile);
      addRows.push(note(parts.join(" · ")));
    }
  } else {
    addRows.push(note(t("No saved hosts were found in ", "저장된 호스트를 찾지 못했습니다: ") + ui.data.sshConfigPath));
  }
  nodes.push(section(t("Add Server", "서버 추가"), addRows));

  const server = selectedServer();
  let serverRows;
  if (server) {
    const authChoices = [
      { value: "keyBased", label: t("Key-based", "키 기반") },
      { value: "passwordBased", label: t("Password-based", "비밀번호"), disabled: server.sshAuthenticationMode !== "passwordBased" },
    ];
    serverRows = [
      toggleRow(t("Enabled", "활성화"), "server-enabled", server.isEnabled, (value) => updateServer("isEnabled", value)),
      row(t("Name", "이름"), textField("server-name", server.name, server.sshTarget || "GPU Server", "w-240",
        (value) => { updateServer("name", value); refreshServerPickerLabel(); })),
      row(t("SSH Target", "SSH 대상"), textField("server-target", server.sshTarget, "gpu-prod or user@host", "w-320",
        (value) => { updateServer("sshTarget", value); refreshServerPickerLabel(); })),
      row("SSH Port", textField("server-port", server.sshPort, t("Optional", "선택 사항"), "w-120", (value) => updateServer("sshPort", value))),
      row(t("Auth Method", "인증 방식"), select("server-auth", server.sshAuthenticationMode, authChoices,
        (value) => updateServer("sshAuthenticationMode", value, true))),
    ];
    if (server.sshAuthenticationMode === "passwordBased") {
      serverRows.push(note(t("Password-based authentication is not available on Windows yet. This server is not polled until you switch it to key-based authentication or ssh-agent.",
        "Windows에서는 아직 비밀번호 인증을 지원하지 않습니다. 키 기반 인증이나 ssh-agent로 바꾸기 전까지 이 서버는 수집하지 않습니다.")));
    }
    serverRows.push(row(t("Identity File", "Identity 파일"), [
      textField("server-identity", server.sshIdentityFilePath, t("Optional", "선택 사항"), "w-240", (value) => updateServer("sshIdentityFilePath", value)),
      button(t("Browse…", "찾아보기…"), () => send({ type: "browseIdentity", serverId: server.id })),
    ]));
  } else {
    serverRows = [note(t("Add a server to start monitoring remote GPUs.", "원격 GPU 모니터링을 시작하려면 서버를 추가하세요."))];
  }
  nodes.push(section(t("Selected Server", "선택된 서버"), serverRows));

  const busyChoices = [
    { value: "activeProcess", label: t("Active Process", "활성 프로세스") },
    { value: "memoryThreshold", label: t("Memory Threshold", "메모리 임계치") },
    { value: "activeProcessOrMemoryThreshold", label: t("Process or Memory", "프로세스 또는 메모리") },
    { value: "utilizationThreshold", label: t("Utilization Threshold", "사용률 임계치") },
  ];
  const help = svgIcon("question", "help");
  const helpHolder = h("span", "", help);
  helpHolder.title = t("Windows OpenSSH does not support connection reuse (ControlMaster), so NVBeacon opens a new SSH connection for every refresh. A longer refresh interval reduces the load on busy servers.",
    "Windows OpenSSH는 연결 재사용(ControlMaster)을 지원하지 않아 새로고침마다 새 SSH 연결을 엽니다. 서버 부하가 걱정되면 새로고침 주기를 늘리세요.");
  const pollingRows = [
    row(t("Refresh Interval", "새로고침 주기"), stepper("poll-interval", d.pollIntervalSeconds, 1, 300, "s", (value) => { d.pollIntervalSeconds = value; changed(); })),
    row(t("SSH Connection", "SSH 연결"), [h("span", "", t("New connection each refresh", "새로고침마다 새 연결")), helpHolder]),
    row(t("Busy Detection", "Busy 판정"), select("busy-mode", d.busyDetectionMode, busyChoices, (value) => { d.busyDetectionMode = value; changed({ rerender: true }); })),
  ];
  if (d.busyDetectionMode === "memoryThreshold" || d.busyDetectionMode === "activeProcessOrMemoryThreshold") {
    pollingRows.push(row(t("Busy Memory Threshold", "Busy 메모리 임계치"),
      stepper("busy-memory", d.busyMemoryThresholdMB, 0, 10240, "MB", (value) => { d.busyMemoryThresholdMB = value; changed(); })));
  }
  if (d.busyDetectionMode === "utilizationThreshold") {
    pollingRows.push(row(t("Busy Util Threshold", "Busy 사용률 임계치"),
      stepper("busy-util", d.busyUtilizationThresholdPercent, 0, 100, "%", (value) => { d.busyUtilizationThresholdPercent = value; changed(); })));
  }
  nodes.push(section(t("Polling", "폴링"), pollingRows));

  const hostRows = [toggleRow(t("Collect host information", "호스트 정보 수집"), "host-info", d.collectsHostInfo, (value) => { d.collectsHostInfo = value; changed({ rerender: true }); })];
  if (d.collectsHostInfo) {
    hostRows.push(
      toggleRow("CPU", "host-cpu", d.collectsHostCPU, (value) => { d.collectsHostCPU = value; changed(); }),
      toggleRow(t("Memory (RAM / Swap)", "메모리 (RAM / Swap)"), "host-memory", d.collectsHostMemory, (value) => { d.collectsHostMemory = value; changed(); }),
      toggleRow(t("Network", "네트워크"), "host-network", d.showsNetworkUsage, (value) => { d.showsNetworkUsage = value; changed(); }));
    for (const node of hostRows.slice(1)) node.classList.add("indent");
  }
  nodes.push(section(t("Host Information", "호스트 정보"), hostRows,
    t("These settings apply to all servers. Disabled items are not collected. Collapsing a server's host information only hides it; collection continues.",
      "모든 서버에 적용됩니다. 끈 항목은 수집하지 않습니다. 호스트 정보를 접으면 화면에서만 숨겨지고 수집은 계속됩니다.")));

  const status = ui.data.launchAtLogin;
  const statusText = status === "enabled" ? t("Enabled", "켜짐") : status === "otherLocation"
    ? t("Registered for another copy of NVBeacon", "다른 위치의 NVBeacon이 등록됨") : t("Disabled", "꺼짐");
  const startupRows = [
    toggleRow(t("Launch NVBeacon at login", "로그인 시 NVBeacon 자동 시작"), "launch-at-login", status === "enabled",
      (value) => send({ type: "setLaunchAtLogin", enabled: value })),
    row(t("Startup Status", "시작 상태"), h("span", status === "enabled" ? "status-enabled" : status === "otherLocation" ? "status-warning" : "", statusText)),
  ];
  if (ui.launchError) startupRows.push(note(ui.launchError));
  startupRows.push(h("div", "row", h("div", "row-control", button(t("Refresh Startup Status", "시작 상태 새로고침"), () => send({ type: "reloadHosts" })))));
  nodes.push(section(t("Startup", "시작"), startupRows,
    t("Uses the per-user Run key, the same place Task Manager's Startup apps list reads.", "사용자별 Run 키에 등록합니다. 작업 관리자의 시작 앱 목록에도 표시됩니다.")));

  nodes.push(section(t("Updates", "업데이트"), [
    toggleRow(t("Automatically check for updates", "자동으로 업데이트 확인"), "updates-check", false, () => {}, { disabled: true }),
    toggleRow(t("Automatically download updates", "업데이트 자동 다운로드"), "updates-download", false, () => {}, { disabled: true }),
  ], t("Automatic updates are not available in the Windows preview yet.", "Windows 미리보기에서는 아직 자동 업데이트를 지원하지 않습니다.")));
  return nodes;
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
  watchAdded: ["Process watch enabled", "프로세스 watch 등록"],
  watchRemoved: ["Process watch removed", "프로세스 watch 해제"],
  idleWatchAdded: ["GPU idle watch enabled", "GPU idle watch 등록"],
  idleWatchRemoved: ["GPU idle watch removed", "GPU idle watch 해제"],
  testNotificationScheduled: ["Test notification sent", "테스트 알림 전송"],
  exitNotificationScheduled: ["Process exit notification sent", "프로세스 종료 알림 전송"],
  idleNotificationScheduled: ["GPU idle notification sent", "GPU idle 알림 전송"],
};

function watchRow(badge, badgeClass, title, primary, secondary, id) {
  const remove = button(t("Disable", "해제"), () => send({ type: "removeWatch", id }), { key: "remove:" + id });
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
  if (!n.processWatches.length && !n.idleWatches.length) {
    watchRows.push(note(t("There are no configured notification watches.", "현재 설정된 notification watch가 없습니다.")));
  }
  for (const watch of n.idleWatches) {
    watchRows.push(watchRow(t("GPU Idle", "GPU Idle"), "idle", watch.title, watch.subtitle,
      t("Idle " + d.idleNotificationSeconds + "s · <=" + d.idleMemoryThresholdMB + "MB", "Idle " + d.idleNotificationSeconds + "초 · <=" + d.idleMemoryThresholdMB + "MB"), watch.id));
  }
  for (const watch of n.processWatches) {
    watchRows.push(watchRow(t("Process Exit", "프로세스 종료"), "exit", watch.title,
      t("User " + watch.user + " · PID " + watch.pid + " · GPU " + watch.gpu, "사용자 " + watch.user + " · PID " + watch.pid + " · GPU " + watch.gpu),
      watch.connection, watch.id));
  }
  const historyRows = n.history.length
    ? n.history.map((entry) => h("div", "info-row history-row",
        h("span", "", h("strong", "", t(...(HISTORY_TITLES[entry.kind] || [entry.kind, entry.kind]))), h("br"), entry.subtitle),
        h("span", "", new Date(entry.time).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }))))
    : [note(t("There is no notification history in the last 24 hours.", "최근 24시간 내 notification 설정 내역이 없습니다."))];
  return [
    section(t("Permission", "권한"), [
      row(t("Status", "상태"), h("span", "", t("Shown through the tray icon", "트레이 아이콘으로 표시"))),
      h("div", "row", h("div", "row-control", button(t("Send Test Notification", "테스트 알림 보내기"), () => send({ type: "testNotification" })))),
    ], t("Windows shows these as notifications from NVBeacon. If they do not appear, check Settings › System › Notifications and Do not disturb.",
         "Windows가 NVBeacon의 알림으로 표시합니다. 보이지 않으면 Windows 설정 › 시스템 › 알림과 방해 금지 모드를 확인하세요.")),
    section(t("GPU Idle Alert", "GPU Idle 알림"), [
      row(t("Idle Duration", "Idle 시간"), stepper("idle-seconds", d.idleNotificationSeconds, 1, 3600, "s", (value) => { d.idleNotificationSeconds = value; changed(); })),
      row(t("Memory Threshold", "메모리 임계치"), stepper("idle-memory", d.idleMemoryThresholdMB, 0, 10240, "MB", (value) => { d.idleMemoryThresholdMB = value; changed(); })),
    ], t("Starred GPUs send an alert when they stay idle.", "별표된 GPU가 오랫동안 쉬고 있으면 알림을 보냅니다.")),
    section(t("Active Watches", "활성 Watch"), watchRows),
    section(t("Recent 24 Hours", "최근 24시간"), historyRows),
  ];
}

function appearancePane() {
  const d = ui.draft;
  return [
    section(t("Popover", "팝오버"), [
      row(t("Language", "언어"), select("language", d.languagePreference, [
        { value: "system", label: t("System", "시스템") },
        { value: "english", label: "English" },
        { value: "korean", label: t("Korean", "한국어") },
      ], (value) => { d.languagePreference = value; changed(); })),
      row(t("Theme", "테마"), select("theme", d.appearanceMode, [
        { value: "system", label: t("System", "시스템") },
        { value: "light", label: t("Light", "라이트") },
        { value: "dark", label: t("Dark", "다크") },
      ], (value) => { d.appearanceMode = value; changed(); })),
      row(t("Display Mode", "표시 방식"), select("display-mode", d.displayMode, [
        { value: "popover", label: t("Popover", "팝오버") },
        { value: "window", label: t("Window", "창") },
      ], (value) => { d.displayMode = value; changed({ rerender: true }); }),
        t("Window keeps NVBeacon open like a normal app window.", "창은 NVBeacon을 일반 앱 창처럼 계속 띄워 둡니다.")),
      toggleRow(t("Keep window on top", "창을 항상 위에 표시"), "window-on-top", d.windowAlwaysOnTop,
        (value) => { d.windowAlwaysOnTop = value; changed(); }, { disabled: d.displayMode !== "window" }),
      row(t("Popover Width", "팝오버 너비"),
        stepper("popover-width", d.popoverWidth, 480, 800, "pt", (value) => { d.popoverWidth = value; changed(); }, 20),
        t("480–800 pt · Default 500 pt", "480–800pt · 기본값 500pt")),
      row(t("Popover Height", "팝오버 높이"), [
        select("popover-height-mode", d.popoverHeightMode, [
          { value: "automatic", label: t("Automatic", "자동") },
          { value: "fixed", label: t("Fixed", "고정") },
        ], (value) => { d.popoverHeightMode = value; changed({ rerender: true }); }),
        d.popoverHeightMode === "fixed"
          ? stepper("popover-height", d.popoverHeight, 320, 1100, "pt", (value) => { d.popoverHeight = value; changed(); }, 20)
          : null,
      ], d.popoverHeightMode === "fixed"
        ? t("320–1100 pt · Content scrolls inside", "320–1100pt · 넘치는 내용은 스크롤")
        : t("Fits the content, up to the screen height", "내용에 맞춤 · 최대 화면 높이까지")),
      toggleRow(t("Close popover on outside click", "바깥 클릭 시 팝오버 닫기"), "close-outside", d.closesPopoverOnOutsideClick,
        (value) => { d.closesPopoverOnOutsideClick = value; changed({ rerender: true }); }),
      note(d.closesPopoverOnOutsideClick
        ? t("Automatically close the popover when you click outside it or switch to another app.", "팝오버 바깥 영역이나 다른 앱을 클릭하면 팝오버를 자동으로 닫습니다.")
        : t("Keep the popover open until you explicitly toggle it again.", "팝오버를 직접 다시 클릭할 때까지 유지합니다.")),
      toggleRow(t("Highlight my processes", "내 프로세스 강조"), "highlight-mine", d.highlightsMyProcesses,
        (value) => { d.highlightsMyProcesses = value; changed({ rerender: true }); }),
      note(d.highlightsMyProcesses
        ? t("Detect the SSH user's processes and highlight matching GPUs and process rows.", "SSH 사용자 프로세스를 감지해 해당 GPU와 프로세스 행을 강조합니다.")
        : t("Turn off per-user process highlighting and skip the extra ownership checks during polling.", "사용자별 프로세스 강조를 끄고 polling 중 추가 ownership 확인도 생략합니다.")),
      toggleRow(t("Record GPU history", "GPU 기록 저장"), "gpu-history", false, () => {}, { disabled: true }),
      note(t("Not available in the Windows preview yet.", "Windows 미리보기에서는 아직 지원하지 않습니다.")),
    ], t("The tray icon cannot show text on Windows, so it draws one utilization bar per GPU; hover it for a summary.",
         "Windows 트레이 아이콘은 글자를 표시할 수 없어 GPU마다 사용률 막대를 그립니다. 마우스를 올리면 요약이 나옵니다.")),
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
    commandSection(t("GPU Query Command", "GPU 조회 명령"), "gpu-command", "remoteCommand", ui.data.defaults.gpuCommand,
      t("Applies to the selected server. Leave empty to restore the default command.", "선택된 서버에 적용됩니다. 비워두면 기본 명령으로 돌아갑니다.")),
    commandSection(t("Host Information Query Command", "호스트 정보 수집 명령"), "host-command", "hostCommand", ui.data.defaults.hostCommand,
      t("Collects CPU, RAM/Swap, and network for the selected server in the same SSH refresh. Keep the section markers and collection switches when customizing. Leave empty to restore the default command.",
        "선택된 서버의 CPU·RAM/Swap·네트워크를 같은 SSH 새로고침에서 수집합니다. 수정할 때 영역 구분자와 항목별 수집 조건을 유지하세요. 비워두면 기본 명령으로 돌아갑니다.")),
    section(t("Server Settings Backup", "서버 설정 백업"), [h("div", "row", h("div", "row-control",
      button(t("Export Servers…", "서버 내보내기…"), () => send({ type: "exportServers" }), { disabled: !d.servers.some((s) => (s.sshTarget || "").trim()) }),
      button(t("Import Servers…", "서버 가져오기…"), () => send({ type: "importServers" }))))],
      t("Exports host names, key-file paths and remote commands. Passwords, private-key contents and notification watches are excluded. Imports add disabled servers without replacing existing settings. The file format is shared with NVBeacon for macOS.",
        "호스트·키 파일 경로·원격 명령을 내보냅니다. 비밀번호·개인 키 내용·알림 감시는 제외됩니다. 가져온 서버는 비활성 상태로 추가되며 기존 설정을 덮어쓰지 않습니다. 파일 형식은 macOS용 NVBeacon과 같습니다.")),
    section(t("Support", "문제 신고"), [h("div", "row", h("div", "row-control",
      button(t("Copy Diagnostic Information…", "진단 정보 복사…"), () => send({ type: "diagnostics" }))))],
      t("Preview a report of the current app and collection state. No additional SSH commands are run.", "앱과 수집 상태를 미리 확인하고 복사합니다. 추가 SSH 명령은 실행하지 않습니다.")),
    section(t("Saved State", "저장 상태"), [h("div", "row", h("div", "row-control",
      button(t("Reload Current Settings", "현재 설정 다시 불러오기"), () => send({ type: "reload" })),
      button(t("Open settings.json", "settings.json 열기"), () => send({ type: "openSettingsFile" })),
      button(t("Clear Saved Settings…", "저장된 설정 지우기…"), confirmClear, { className: "destructive" })))],
      t("Clears saved app settings.", "저장된 앱 설정을 지웁니다.")),
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
  const busy = { activeProcess: t("Active Process", "활성 프로세스"), memoryThreshold: t("Memory Threshold", "메모리 임계치"),
    activeProcessOrMemoryThreshold: t("Process or Memory", "프로세스 또는 메모리"), utilizationThreshold: t("Utilization Threshold", "사용률 임계치") };
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
      [t("Busy Detection", "Busy 판정"), busy[d.busyDetectionMode]],
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
    h("p", "", t("This removes every server and resets all settings. It cannot be undone.", "모든 서버가 삭제되고 설정이 초기화됩니다. 되돌릴 수 없습니다.")), [
      button(t("Cancel", "취소"), closeSheet),
      button(t("Clear Saved Settings", "저장된 설정 지우기"), () => { closeSheet(); send({ type: "clearSettings" }); }, { className: "primary" }),
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
  const builders = { general: generalPane, notifications: notificationsPane, appearance: appearancePane, advanced: advancedPane, about: aboutPane };
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
