/* =====================================================================
   GROWTH METRICS  -  edit the numbers below, save, and push. That's it.
   =====================================================================

   These are the stats that rotate in the little pill under the Sponsor!
   button on the homepage.

   - Change a number:   edit the text between the quotes.
   - Change the order:  move the lines around. They show top to bottom.
   - Add or remove:     add or delete a line. Any number of stats works;
                        the rotation timing adjusts itself.

   Write each value exactly how you want it to appear, e.g. "52.6K",
   "4.7M+", "5". Keep the commas at the end of each line except the last.
*/
(function () {

  var METRICS = [
    { value: "61.2K", label: "followers" },
    { value: "6mil", label: "views"     },
    { value: "5",     label: "sponsors"  }
  ];

  /* How long each stat stays up before switching to the next, in seconds. */
  var SECONDS_PER_STAT = 3;


  /* ------------------ nothing below here needs editing ------------------ */

  function render() {
    var pill = document.getElementById("stat-rotator");
    if (!pill) return;

    var items = METRICS.filter(function (m) {
      return m && String(m.value == null ? "" : m.value).trim() !== "";
    });
    /* No stats: leave the pill empty, and CSS keeps an empty pill hidden. */
    if (!items.length) return;

    var count = items.length;
    var reduceMotion = window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    var rotate = count > 1 && !reduceMotion;

    if (rotate) {
      /* Each stat gets an equal slice of one full cycle: fade in, hold, and
         hand off exactly as the next one fades in, so the pill is never
         blank between stats. Built here so it works for any number of stats. */
      var share = 100 / count;
      var style = document.createElement("style");
      style.textContent =
        "@keyframes stat-cycle-js{" +
          "0%{opacity:0}" +
          (share * 0.045).toFixed(2) + "%," + (share * 0.955).toFixed(2) + "%{opacity:1}" +
          share.toFixed(2) + "%,100%{opacity:0}" +
        "}";
      document.head.appendChild(style);
    }

    var cycleSeconds = count * SECONDS_PER_STAT;
    items.forEach(function (m, i) {
      var el = document.createElement("span");
      el.className = "stat-item";
      el.textContent = (String(m.value).trim() + " " + (m.label || "")).trim();
      if (rotate) {
        el.style.animation = "stat-cycle-js " + cycleSeconds + "s ease-in-out " +
          (i * SECONDS_PER_STAT) + "s infinite";
      } else {
        /* One stat, or the visitor has asked for less motion: show the first, still. */
        el.style.opacity = i === 0 ? "1" : "0";
      }
      pill.appendChild(el);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", render);
  } else {
    render();
  }
})();
