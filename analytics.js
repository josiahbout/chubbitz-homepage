/* Shared analytics for every page on the site.
   Loads Google Analytics, then reports clicks on any element carrying data-track.

   To track a new button or link, just add attributes to it — no changes needed here:
     data-track="event_name"          (required — the GA4 event name)
     data-track-label="which_one"     (optional — sent as the "label" parameter)

   Note: GA4's Enhanced Measurement already tracks outbound link clicks on its own,
   so data-track is mainly worth adding for things that aren't plain navigations
   (opening the pop-up, copying the email) or where a clearer name helps.
*/
(function () {
  var MEASUREMENT_ID = 'G-S286YSQPJ5';

  window.dataLayer = window.dataLayer || [];
  window.gtag = function () { window.dataLayer.push(arguments); };
  gtag('js', new Date());
  gtag('config', MEASUREMENT_ID);

  var tag = document.createElement('script');
  tag.async = true;
  tag.src = 'https://www.googletagmanager.com/gtag/js?id=' + MEASUREMENT_ID;
  document.head.appendChild(tag);

  // One delegated listener covers every element on the page, including any added later.
  document.addEventListener('click', function (e) {
    var target = e.target;
    if (!target || typeof target.closest !== 'function') return;

    var el = target.closest('[data-track]');
    if (!el) return;

    var params = {};
    if (el.dataset.trackLabel) params.label = el.dataset.trackLabel;

    var href = el.getAttribute('href');
    if (href) params.link_url = href;

    gtag('event', el.dataset.track, params);
  });
})();
