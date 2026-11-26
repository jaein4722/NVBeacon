"use strict";

// Interface strings for every page. The app sends the table from Shared/Localization
// (see NVBeaconCore Translations.swift) as a "strings" message before the first state,
// and again when the language changes. Keys are the English text, or "context::English".
const strings = { table: {} };

if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener("message", (event) => {
    if (event.data && event.data.type === "strings") strings.table = event.data.strings || {};
  });
}

// t("Settings"), t("%@ ago", age): the text for a key, with %@ (or %lld, %1$@) filled in.
function t(key, ...args) {
  const text = Object.prototype.hasOwnProperty.call(strings.table, key) ? strings.table[key] : key.split("::").pop();
  return formatText(text, args);
}

// Same rules as Translations.format: a text without arguments is shown as written.
function formatText(text, args) {
  if (!args.length) return text;
  let next = 0;
  return text.replace(/%(?:(\d+)\$)?(@|lld|ld|d)|%%/g, (match, position, specifier) => {
    if (!specifier) return "%";
    const index = position ? Number(position) - 1 : next++;
    return index < args.length ? String(args[index]) : "";
  });
}
