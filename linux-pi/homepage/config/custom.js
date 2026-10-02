// Generated from server-base/homepage/custom.js.in.
// Tags each Homepage group with its accent (server-base/fleet.json) so
// custom.css can colour it. Homepage renders client-side and may re-render
// groups, so re-apply on DOM changes.
(() => {
  const accents = {"Management": "blue", "Pi Services": "emerald", "Servers": "indigo", "Shared services": "cyan"};
  const apply = () => {
    for (const heading of document.querySelectorAll(".service-group-name")) {
      const accent = accents[heading.textContent.trim()];
      const group = heading.closest(".services-group");
      if (accent && group && group.dataset.accent !== accent) {
        group.dataset.accent = accent;
      }
    }
  };
  apply();
  new MutationObserver(apply).observe(document.body, { childList: true, subtree: true });
})();
