"use strict";

const demo = document.getElementById("demo");
const captureViewport = demo.querySelector(".capture-viewport");
const tabs = Array.from(demo.querySelectorAll('[role="tab"]'));
const description = document.getElementById("demo-description");
const fullCapture = document.getElementById("full-capture");
const motionToggle = document.getElementById("motion-toggle");
const motionIcon = document.getElementById("motion-icon");
const motionLabel = document.getElementById("motion-label");
const demoError = document.getElementById("demo-error");
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const demos = new Map(tabs.map((tab) => {
  const panel = document.getElementById(tab.getAttribute("aria-controls"));
  return [tab, { panel, video: panel.querySelector("video") }];
}));

let activeTab = tabs.find((tab) => tab.getAttribute("aria-selected") === "true");
let shouldPlay = !reduceMotion.matches;
let inView = !("IntersectionObserver" in window);

function updatePlaybackControl() {
  const { video } = demos.get(activeTab);
  const playing = !video.paused;
  motionIcon.textContent = playing ? "Ⅱ" : "▶";
  motionLabel.textContent = playing ? "暂停演示" : "播放演示";
  motionToggle.disabled = video.error !== null;
  demoError.hidden = video.error === null;
}

function syncPlayback() {
  const activeVideo = demos.get(activeTab).video;
  for (const { video } of demos.values()) {
    if (video !== activeVideo) video.pause();
  }

  if (!shouldPlay || !inView || document.hidden) {
    activeVideo.pause();
  } else if (!activeVideo.error) {
    if (!activeVideo.hasAttribute("src")) activeVideo.src = activeVideo.dataset.src;
    activeVideo.play().catch((error) => {
      if (error.name === "AbortError" || activeVideo !== demos.get(activeTab).video) return;
      shouldPlay = false;
      updatePlaybackControl();
    });
  }
  updatePlaybackControl();
}

function selectTab(tab) {
  if (activeTab === tab) return;
  activeTab = tab;
  for (const [option, { panel }] of demos) {
    const selected = option === activeTab;
    option.setAttribute("aria-selected", String(selected));
    option.tabIndex = selected ? 0 : -1;
    panel.hidden = !selected;
  }
  const { video } = demos.get(tab);
  if (video.readyState > 0) video.currentTime = 0;
  description.textContent = tab.dataset.caption;
  fullCapture.href = video.poster;
  syncPlayback();
}

for (const [index, tab] of tabs.entries()) {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    const moves = {
      ArrowRight: (index + 1) % tabs.length,
      ArrowLeft: (index - 1 + tabs.length) % tabs.length,
      Home: 0,
      End: tabs.length - 1,
    };
    if (!Object.hasOwn(moves, event.key)) return;
    event.preventDefault();
    const next = tabs[moves[event.key]];
    selectTab(next);
    next.focus();
  });
  const { video } = demos.get(tab);
  video.muted = true;
  for (const event of ["play", "pause", "error"]) {
    video.addEventListener(event, () => {
      if (tab === activeTab) updatePlaybackControl();
    });
  }
}

motionToggle.addEventListener("click", () => {
  shouldPlay = demos.get(activeTab).video.paused;
  syncPlayback();
});
document.addEventListener("visibilitychange", syncPlayback);
const mobileNav = document.querySelector(".mobile-nav");
for (const link of mobileNav.querySelectorAll("a")) {
  link.addEventListener("click", () => { mobileNav.open = false; });
}
reduceMotion.addEventListener("change", ({ matches }) => {
  shouldPlay = !matches;
  syncPlayback();
});

if ("IntersectionObserver" in window) {
  const playbackObserver = new IntersectionObserver(([entry]) => {
    inView = entry.intersectionRatio >= 0.08;
    syncPlayback();
  }, { threshold: 0.08 });
  playbackObserver.observe(captureViewport);
}

syncPlayback();
