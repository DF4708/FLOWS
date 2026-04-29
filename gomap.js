// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

document.addEventListener('DOMContentLoaded', function () {
  const rafThrottle = function (fn) {
    let scheduled = false;
    return function () {
      if (scheduled) return;
      scheduled = true;
      window.requestAnimationFrame(function () {
        scheduled = false;
        fn();
      });
    };
  };

  const applyFilterTitleSizing = function () {
    const panel = document.querySelector('.filter-panel');
    if (!panel) return;
    const labels = Array.from(panel.querySelectorAll('.filter-option-label'));
    if (!labels.length) return;
    let scale = 1;
    panel.style.setProperty('--filter-title-scale', scale.toFixed(3));
    const overflows = function () {
      return labels.some(function (label) {
        return label.scrollHeight - label.clientHeight > 1 || label.scrollWidth - label.clientWidth > 1;
      });
    };
    while (scale > 0.7 && overflows()) {
      scale *= 0.95;
      panel.style.setProperty('--filter-title-scale', scale.toFixed(3));
    }
  };

  const applyNoticeSizing = function () {
    const stack = document.getElementById('warning_cards');
    if (!stack) return;
    const cards = Array.from(stack.querySelectorAll('.notice-card'));
    if (!cards.length) return;
    let scale = 1;
    stack.style.setProperty('--notice-scale', scale.toFixed(3));
    const hasOverflow = function () {
      return cards.some(function (card) {
        return card.scrollHeight - card.clientHeight > 1 || card.scrollWidth - card.clientWidth > 1;
      });
    };
    while (scale > 0.55 && hasOverflow()) {
      scale *= 0.95;
      stack.style.setProperty('--notice-scale', scale.toFixed(3));
    }
  };

  const applyTimelineSizing = function () {
    const segmented = document.querySelector('.timeline-segmented');
    if (!segmented) return;
    const labels = Array.from(segmented.querySelectorAll('label.radio-inline'));
    if (!labels.length) return;
    let scale = 1;
    segmented.style.setProperty('--timeline-btn-scale', scale.toFixed(3));
    const overflows = function () {
      return labels.some(function (label) {
        return label.scrollWidth - label.clientWidth > 1 || label.scrollHeight - label.clientHeight > 1;
      });
    };
    while (scale > 0.5 && overflows()) {
      scale *= 0.94;
      segmented.style.setProperty('--timeline-btn-scale', scale.toFixed(3));
    }
  };

  const tagProgressNotifications = function () {
    document.querySelectorAll('.shiny-notification').forEach(function (node) {
      if (node.querySelector('.progress')) {
        node.classList.add('map-load-progress');
      }
    });
  };

  const scheduleFilterSizing = rafThrottle(applyFilterTitleSizing);
  const scheduleNoticeSizing = rafThrottle(applyNoticeSizing);
  const scheduleTimelineSizing = rafThrottle(applyTimelineSizing);
  const scheduleProgressTagging = rafThrottle(tagProgressNotifications);

  const warningCardsHost = document.getElementById('warning_cards');
  if (warningCardsHost) {
    const noticeObserver = new MutationObserver(function () {
      scheduleNoticeSizing();
    });
    noticeObserver.observe(warningCardsHost, { childList: true, subtree: true });
  }

  const observeTimelineSegmented = function () {
    const segmented = document.querySelector('.timeline-segmented');
    if (!segmented || segmented.dataset.timelineObserved === 'true') return true;
    if (typeof ResizeObserver === 'function') {
      const ro = new ResizeObserver(function () {
        scheduleTimelineSizing();
      });
      ro.observe(segmented);
      segmented.dataset.timelineObserved = 'true';
      return true;
    }
    return false;
  };
  if (!observeTimelineSegmented()) {
    const timelineMountObserver = new MutationObserver(function () {
      if (observeTimelineSegmented()) timelineMountObserver.disconnect();
    });
    timelineMountObserver.observe(document.body, { childList: true, subtree: true });
  }

  const alignSidesToRouteShell = function () {
    const routeShell = document.querySelector('.route-shell');
    if (!routeShell) return;
    const rect = routeShell.getBoundingClientRect();
    if (!rect || !rect.height) return;
    const clampedTop = Math.max(0, Math.round(rect.top));
    const topPx = clampedTop + 'px';
    ['.legend-shell', '.route-summary-shell'].forEach(function (sel) {
      const el = document.querySelector(sel);
      if (el) el.style.top = topPx;
    });
  };
  const scheduleSideAlignment = rafThrottle(alignSidesToRouteShell);

  const observeRouteShell = function () {
    const routeShell = document.querySelector('.route-shell');
    if (!routeShell) return false;
    if (routeShell.dataset.routeAlignObserved !== 'true') {
      if (typeof ResizeObserver === 'function') {
        const ro = new ResizeObserver(function () {
          scheduleSideAlignment();
        });
        ro.observe(routeShell);
        routeShell.dataset.routeAlignObserved = 'true';
      } else {
        return false;
      }
    }
    scheduleSideAlignment();
    return true;
  };
  if (!observeRouteShell()) {
    const routeShellMountObserver = new MutationObserver(function () {
      if (observeRouteShell()) routeShellMountObserver.disconnect();
    });
    routeShellMountObserver.observe(document.body, { childList: true, subtree: true });
  }

  const routeSummaryHost = document.getElementById('route_summary_shell');
  if (routeSummaryHost) {
    const summaryObserver = new MutationObserver(function () {
      scheduleSideAlignment();
    });
    summaryObserver.observe(routeSummaryHost, { childList: true });
  }

  const notificationObserver = new MutationObserver(function (mutations) {
    const touchedNotifications = mutations.some(function (mutation) {
      return Array.from(mutation.addedNodes || []).some(function (node) {
        return node.nodeType === 1 && (
          node.classList.contains('shiny-notification') ||
          (typeof node.querySelector === 'function' && node.querySelector('.shiny-notification'))
        );
      });
    });
    if (touchedNotifications) {
      scheduleProgressTagging();
    }
  });
  notificationObserver.observe(document.body, { childList: true });

  window.addEventListener('resize', function () {
    scheduleFilterSizing();
    scheduleNoticeSizing();
    scheduleTimelineSizing();
    scheduleSideAlignment();
  });

  document.addEventListener('toggle', function (evt) {
    if (evt.target && evt.target.classList && evt.target.classList.contains('filter-details')) {
      scheduleFilterSizing();
    }
  }, true);

  document.addEventListener('keydown', function (evt) {
    const input = document.getElementById('search_query');
    const routeStart = document.getElementById('route_start');
    const routeEnd = document.getElementById('route_end');
    if (input && document.activeElement === input && evt.key === 'Enter') {
      const button = document.getElementById('search_go');
      if (button) button.click();
    }
    if ((routeStart && document.activeElement === routeStart && evt.key === 'Enter') ||
        (routeEnd && document.activeElement === routeEnd && evt.key === 'Enter')) {
      const routeButton = document.getElementById('route_go');
      if (routeButton) routeButton.click();
    }
  });

  document.addEventListener('change', function (evt) {
    if (!window.Shiny || typeof window.Shiny.setInputValue !== 'function') return;
    const target = evt.target;
    if (!target) return;

    if (target.matches('input[name="primary_map"]')) {
      window.Shiny.setInputValue('primary_map', target.value, { priority: 'event' });
      return;
    }

    if (target.matches('input[name="time_horizon"]')) {
      window.Shiny.setInputValue('time_horizon', target.value, { priority: 'event' });
      return;
    }

    if (target.matches('input[name="reference_layers"]')) {
      const values = Array.from(document.querySelectorAll('input[name="reference_layers"]:checked')).map(function (node) {
        return node.value;
      });
      window.Shiny.setInputValue('reference_layers', values, { priority: 'event' });
    }
  });

  scheduleProgressTagging();
  scheduleFilterSizing();
  scheduleNoticeSizing();
  scheduleTimelineSizing();
  scheduleSideAlignment();

  const setupProgressHandler = function () {
    if (window.Shiny && typeof Shiny.addCustomMessageHandler === 'function') {
      Shiny.addCustomMessageHandler('updateProgressBar', function (data) {
        const bar = document.querySelector('#map_progress_ui .map-progress-bar');
        const detail = document.querySelector('#map_progress_ui .map-progress-detail');
        const raw = (data && typeof data.value !== 'undefined') ? Number(data.value) : NaN;
        if (bar && Number.isFinite(raw)) {
          bar.style.width = Math.max(0, Math.min(100, raw)) + '%';
        }
        if (detail) {
          const text = (data && typeof data.detail === 'string' && data.detail.length > 0)
            ? data.detail
            : 'Map ready.';
          detail.textContent = text;
        }
      });
      return;
    }
    setTimeout(setupProgressHandler, 50);
  };
  setupProgressHandler();
});
