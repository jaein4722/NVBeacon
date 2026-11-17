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

  // Slide sections up as they scroll into view (styles.css hides them only
  // when motion is allowed). Children of a "stagger" group follow one another.
  var reveals = document.querySelectorAll("[data-reveal]");
  reveals.forEach(function (group) {
    if (group.getAttribute("data-reveal") !== "stagger") return;
    Array.prototype.forEach.call(group.children, function (child, index) {
      child.style.setProperty("--i", Math.min(index, 6));
    });
  });
  if ("IntersectionObserver" in window) {
    var revealer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-in");
        revealer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0 });
    reveals.forEach(function (node) { revealer.observe(node); });
  } else {
    reveals.forEach(function (node) { node.classList.add("is-in"); });
  }

  // Demo videos: the hero clip autoplays; the others load and play only while
  // half visible, and every clip pauses off screen. A button pauses and resumes.
  // Visitors who prefer reduced motion get still posters and native controls.
  var videos = document.querySelectorAll(".video-frame video");
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) {
    videos.forEach(function (video) {
      video.removeAttribute("autoplay");
      video.pause();
      video.preload = "metadata";
      video.controls = true;
    });
  } else if (videos.length) {
    var ko = document.documentElement.lang === "ko";
    var labels = ko ? ["영상 일시 정지", "영상 재생"] : ["Pause video", "Play video"];
    var icons = ['<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="3.5" y="2.5" width="3" height="11" rx="1"/><rect x="9.5" y="2.5" width="3" height="11" rx="1"/></svg>',
                 '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 2.8v10.4a.8.8 0 0 0 1.2.7l8.3-5.2a.8.8 0 0 0 0-1.4L5.7 2.1a.8.8 0 0 0-1.2.7z"/></svg>'];

    var play = function (video) {
      var result = video.play();
      if (result && result.catch) result.catch(function () {});
    };
    var sync = function (video) {
      var playing = !video.paused;
      video._toggle.innerHTML = icons[playing ? 0 : 1];
      video._toggle.setAttribute("aria-label", labels[playing ? 0 : 1]);
    };

    videos.forEach(function (video) {
      // The HTML ships native controls for visitors without JavaScript;
      // the custom pause button replaces them here.
      video.controls = false;
      var button = document.createElement("button");
      button.type = "button";
      button.className = "video-toggle";
      video._toggle = button;
      video.parentNode.appendChild(button);
      button.addEventListener("click", function () {
        video._userPaused = !video.paused;
        if (video.paused) play(video); else video.pause();
      });
      video.addEventListener("play", function () { sync(video); });
      video.addEventListener("pause", function () { sync(video); });
      sync(video);
    });

    if ("IntersectionObserver" in window) {
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          var video = entry.target;
          // The hero clip starts as soon as a fifth of it shows; the others at half.
          var needed = video.hasAttribute("autoplay") ? 0.2 : 0.5;
          if (entry.isIntersecting && entry.intersectionRatio >= needed) {
            if (!video._userPaused) play(video);
          } else if (!video.paused) {
            video.pause();
          }
        });
      }, { threshold: [0, 0.2, 0.5] });
      videos.forEach(function (video) { observer.observe(video); });
    } else {
      videos.forEach(function (video) { if (video.hasAttribute("data-autoplay")) play(video); });
    }
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
