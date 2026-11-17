// Small progressive enhancements. The page works without this file.
(function () {
  document.documentElement.classList.add("js");

  // Copy buttons next to shell commands.
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    var label = button.textContent;
    button.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(button.dataset.copy).then(function () {
        button.textContent = button.dataset.done || label;
        setTimeout(function () { button.textContent = label; }, 1600);
      });
    });
  });

  // Looping clips do not autoplay for visitors who prefer reduced motion.
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.querySelectorAll("video[autoplay]").forEach(function (video) {
      video.removeAttribute("autoplay");
      video.pause();
      video.controls = true;
    });
  }

  // Point Mac download links at the latest DMG from the Sparkle appcast.
  // Links keep their GitHub Releases fallback if this fails.
  var links = document.querySelectorAll("[data-dmg-link]");
  if (!links.length || !window.fetch || !window.DOMParser) return;

  var appcast = "https://raw.githubusercontent.com/jaein4722/NVBeacon/appcast/appcast.xml";
  var allowedPrefix = "https://github.com/jaein4722/NVBeacon/releases/download/";
  var sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";

  fetch(appcast, { cache: "no-cache" })
    .then(function (response) { return response.ok ? response.text() : Promise.reject(); })
    .then(function (text) {
      var item = new DOMParser().parseFromString(text, "application/xml").querySelector("item");
      var enclosure = item && item.querySelector("enclosure");
      var url = enclosure && enclosure.getAttribute("url");
      if (!url || url.indexOf(allowedPrefix) !== 0 || !/\.dmg$/.test(url)) return;

      links.forEach(function (link) { link.href = url; });

      var version = item.getElementsByTagNameNS(sparkle, "shortVersionString")[0];
      if (!version || !/^[0-9][0-9A-Za-z.\-]*$/.test(version.textContent.trim())) return;
      document.querySelectorAll("[data-latest-version]").forEach(function (node) {
        node.textContent = node.dataset.latestVersion.replace("{v}", version.textContent.trim());
        node.hidden = false;
      });
    })
    .catch(function () {});
})();
