/* MacHelper landing page: theme toggle, tabs, copy buttons, small live touches. No dependencies. */
(function () {
  "use strict";

  var root = document.documentElement;
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- Theme toggle: auto → light → dark → auto ---------- */
  var toggle = document.querySelector(".theme-toggle");
  var labels = {
    auto: "Theme: automatic. Switch to light.",
    light: "Theme: light. Switch to dark.",
    dark: "Theme: dark. Switch to automatic."
  };
  function currentMode() {
    var t = root.getAttribute("data-theme");
    return t === "light" || t === "dark" ? t : "auto";
  }
  function applyMode(mode) {
    if (mode === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", mode);
    try {
      if (mode === "auto") localStorage.removeItem("mh-theme");
      else localStorage.setItem("mh-theme", mode);
    } catch (e) {}
    if (toggle) {
      toggle.setAttribute("data-mode", mode);
      toggle.setAttribute("aria-label", labels[mode]);
      toggle.title = labels[mode].split(".")[0];
    }
  }
  if (toggle) {
    applyMode(currentMode());
    toggle.addEventListener("click", function () {
      var next = { auto: "light", light: "dark", dark: "auto" }[currentMode()];
      applyMode(next);
    });
  }

  /* ---------- Sticky nav hairline ---------- */
  var nav = document.querySelector(".nav");
  function onScroll() {
    if (nav) nav.classList.toggle("scrolled", window.scrollY > 8);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- Accessible tabs (features and terminal) ---------- */
  document.querySelectorAll('[role="tablist"]').forEach(function (list) {
    var tabs = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        var panel = document.getElementById(t.getAttribute("aria-controls"));
        if (panel) panel.hidden = !on;
      });
      if (focus) tab.focus();
      if (tab.scrollIntoView && list.scrollWidth > list.clientWidth) {
        tab.scrollIntoView({ block: "nearest", inline: "nearest", behavior: reduceMotion ? "auto" : "smooth" });
      }
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () { select(tab, false); });
      tab.addEventListener("keydown", function (e) {
        var n = null;
        if (e.key === "ArrowRight") n = tabs[(i + 1) % tabs.length];
        else if (e.key === "ArrowLeft") n = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === "Home") n = tabs[0];
        else if (e.key === "End") n = tabs[tabs.length - 1];
        if (n) { e.preventDefault(); select(n, true); }
      });
    });
  });

  /* ---------- Copy to clipboard ---------- */
  var status = document.querySelector("[data-copy-status]");
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
    return ok ? Promise.resolve() : Promise.reject(new Error("copy failed"));
  }
  function copy(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return fallbackCopy(text); });
    }
    return fallbackCopy(text);
  }
  function commandsFrom(pre) {
    // Copy only the commands typed after a "$" prompt, not the sample output.
    return pre.textContent.split("\n")
      .filter(function (l) { return /^\$ /.test(l); })
      .map(function (l) { return l.slice(2); })
      .join("\n");
  }
  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy");
      if (!text) {
        var scope = btn.closest(".window");
        var pre = scope && scope.querySelector(btn.getAttribute("data-copy-from"));
        text = pre ? commandsFrom(pre) : "";
      }
      if (!text) return;
      copy(text).then(function () {
        btn.classList.add("copied");
        if (status) status.textContent = "Copied to clipboard";
        setTimeout(function () {
          btn.classList.remove("copied");
          if (status) status.textContent = "";
        }, 1800);
      }, function () {
        if (status) status.textContent = "Could not copy. Select the text and copy it instead.";
      });
    });
  });

  /* ---------- Demo telemetry switch (illustration only) ---------- */
  var sw = document.querySelector("[data-demo-switch]");
  var swState = document.querySelector("[data-demo-state]");
  if (sw) {
    sw.addEventListener("click", function () {
      var on = sw.getAttribute("aria-checked") !== "true";
      sw.setAttribute("aria-checked", on ? "true" : "false");
      if (swState) swState.textContent = on ? "Would send this payload" : "Not sending";
    });
  }

  /* ---------- Latest version from the appcast (same origin) ---------- */
  if (window.fetch && window.DOMParser) {
    fetch("appcast.xml", { cache: "no-cache" })
      .then(function (r) { return r.ok ? r.text() : Promise.reject(); })
      .then(function (xml) {
        var doc = new DOMParser().parseFromString(xml, "application/xml");
        var item = doc.querySelector("item");
        if (!item) return;
        var nodes = item.getElementsByTagName("*");
        var version = null, notes = null;
        for (var i = 0; i < nodes.length; i++) {
          var name = nodes[i].localName;
          if (name === "shortVersionString" && !version) version = nodes[i].textContent.trim();
          if (name === "releaseNotesLink" && !nodes[i].getAttribute("xml:lang") && !notes) notes = nodes[i].textContent.trim();
        }
        if (!version || !/^[0-9][0-9A-Za-z.\-]*$/.test(version)) return;
        document.querySelectorAll("[data-version]").forEach(function (el) { el.textContent = "Version " + version; });
        var local = "MacHelper-" + version + ".md";
        if (notes && notes.indexOf(local) !== -1) {
          document.querySelectorAll("[data-notes-link]").forEach(function (a) { a.setAttribute("href", local); });
        }
      })
      .catch(function () {});
  }

  /* ---------- Menu bar clock ---------- */
  var clock = document.querySelector("[data-clock]");
  if (clock) {
    var fmt = function () {
      try {
        clock.textContent = new Date().toLocaleString("en-US", { weekday: "short", hour: "numeric", minute: "2-digit" }).replace(",", "");
      } catch (e) {}
    };
    fmt();
    setInterval(fmt, 30000);
  }

  /* ---------- Reveal on scroll ---------- */
  var reveals = document.querySelectorAll(".reveal");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) { io.observe(el); });
  }

  /* ---------- Live-feel CPU chip (decorative sample data) ---------- */
  var cpu = document.querySelector("[data-live-cpu]");
  var spark = document.querySelector("[data-spark]");
  if (cpu && spark && !reduceMotion) {
    var values = [16, 15, 17, 12, 14, 10, 13, 11, 12];
    var tick = function () {
      if (document.hidden) return;
      var last = values[values.length - 1];
      var next = Math.max(6, Math.min(32, Math.round(last + (Math.random() * 8 - 4))));
      values.push(next);
      values.shift();
      cpu.textContent = next + "%";
      spark.setAttribute("points", values.map(function (v, i) {
        return (i * 8) + "," + (24 - (v / 34) * 22).toFixed(1);
      }).join(" "));
    };
    setInterval(tick, 1600);
  }
})();
