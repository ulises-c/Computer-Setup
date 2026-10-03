// Generated from server-base/homepage/custom.js.in.
// Tags each Homepage group with its accent (server-base/fleet.json) so
// custom.css can colour it. Homepage renders client-side and may re-render
// groups, so re-apply on DOM changes.
(() => {
  const accents = {"Management": "blue", "NAS": "orange", "Network": "teal", "Servers": "indigo", "Storage": "amber"};
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

// Top bar extras the Glances info widget cannot show: GPUs and fans from this
// host's Glances, and RGB lighting from its status JSON when it has one. The
// URLs come from settings.yaml (topbarExtras), so private names stay in .env.
(() => {
  const extras = window.__NEXT_DATA__?.props?.pageProps?.initialSettings?.topbarExtras || {};
  if (!extras.glances && !extras.rgb) return;
  const svg = {
    gpu: '<path d="M2 7h18v10H2zM20 10h2v4h-2M6 17v2M10 17v2M14 17v2"/><circle cx="8" cy="12" r="2"/><circle cx="14" cy="12" r="2"/>',
    fan: '<circle cx="12" cy="12" r="2"/><path d="M12 10c0-4 1-7 4-7s3 4-2 7M14 12c4 0 7 1 7 4s-4 3-7-2M12 14c0 4-1 7-4 7s-3-4 2-7M10 12c-4 0-7-1-7-4s4-3 7 2"/>',
    rgb: '<circle cx="12" cy="8" r="5"/><circle cx="8" cy="15" r="5"/><circle cx="16" cy="15" r="5"/>',
  };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const chip = (icon, rows, pct, swatch) => {
    const line = ([value, label]) =>
      `<div class="text-theme-800 dark:text-theme-200 text-xs flex flex-row justify-between gap-2">` +
      `<div class="pl-0.5">${esc(value)}</div><div class="pr-1">${esc(label)}</div></div>`;
    const bar = pct == null ? "" :
      `<div class="mt-0.5 w-full bg-theme-800/30 rounded-full h-1 dark:bg-theme-200/20 resource-usage">` +
      `<div class="bg-theme-800/70 h-1 rounded-full dark:bg-theme-200/50" style="width:${Math.min(100, Math.max(0, pct))}%"></div></div>`;
    const dot = /^#[0-9a-fA-F]{6}$/.test(swatch || "") ? `<span class="topbar-swatch" style="background:${swatch}"></span>` : "";
    return `<div class="flex-none flex flex-row items-center mr-3 py-1.5 information-widget-resource topbar-extra">` +
      `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-theme-800 dark:text-theme-200 w-5 h-5 resource-icon">${svg[icon]}</svg>` +
      `<div class="flex flex-col ml-3 text-left expanded min-w-[85px]">${rows.map(line).join("")}${bar}</div>${dot}</div>`;
  };
  const getJson = async (url) => {
    try {
      const r = await fetch(url, { cache: "no-store" });
      return r.ok ? await r.json() : null;
    } catch {
      return null;
    }
  };
  let html = "";
  // Homepage re-renders the widget, so the extras box is re-attached when lost.
  const render = () => {
    const row = document.querySelector(".information-widget-glances > div");
    if (!row) return;
    let box = row.querySelector(":scope > .topbar-extras");
    if (!box) {
      box = document.createElement("div");
      box.className = "topbar-extras flex flex-row flex-wrap";
      row.appendChild(box);
    }
    // Compare against what was last written: the browser normalises innerHTML,
    // so comparing to it would rewrite (and re-trigger the observer) forever.
    if (box.dataset.src !== html) {
      box.dataset.src = html;
      box.innerHTML = html;
    }
  };
  const refresh = async () => {
    const parts = [];
    if (extras.glances) {
      const [gpus, sensors] = await Promise.all([
        getJson(`${extras.glances}/api/4/gpu`),
        getJson(`${extras.glances}/api/4/sensors`),
      ]);
      for (const g of gpus || []) {
        const rows = [[`${Math.round(g.proc ?? 0)}%`, "GPU"]];
        if (g.temperature != null) rows.push([`${g.temperature}°C`, "Temp"]);
        if (g.fan_speed != null) rows.push([`${g.fan_speed}%`, "Fan"]);
        if (g.mem != null) rows.push([`${Math.round(g.mem)}%`, "VRAM"]);
        parts.push(chip("gpu", rows.slice(0, 2), g.proc ?? 0));
        if (rows.length > 2) parts.push(chip("fan", rows.slice(2, 4), null));
      }
      for (const f of (sensors || []).filter((s) => s.type === "fan_speed")) {
        parts.push(chip("fan", [[`${f.value} RPM`, f.label]], null));
      }
    }
    if (extras.rgb) {
      const rgb = await getJson(extras.rgb);
      for (const d of rgb?.devices || []) {
        parts.push(chip("rgb", [[d.mode || "?", "RGB"], [d.name || "", ""]], null, d.color));
      }
    }
    html = parts.join("");
    render();
  };
  refresh();
  setInterval(refresh, 5000);
  new MutationObserver(render).observe(document.body, { childList: true, subtree: true });
})();
