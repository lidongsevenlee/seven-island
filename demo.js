"use strict";

const demo = document.getElementById("demo");
const captureViewport = demo.querySelector(".capture-viewport");
const tabList = demo.querySelector(".capture-tabs");
const tabs = Array.from(tabList.querySelectorAll('[role="tab"]'));
const motionToggle = document.getElementById("motion-toggle");
const motionIcon = document.getElementById("motion-icon");
const demoError = document.getElementById("demo-error");
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const demos = tabs.map((tab) => {
  const panel = document.getElementById(tab.getAttribute("aria-controls"));
  return { tab, panel, video: panel.querySelector("video") };
});

let activeIndex = tabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true");
let shouldPlay = !reduceMotion.matches;
let inView = !("IntersectionObserver" in window);

function updatePlaybackControl() {
  const { video } = demos[activeIndex];
  const label = video.paused ? "播放录屏" : "暂停录屏";
  motionIcon.textContent = video.paused ? "▶" : "Ⅱ";
  motionToggle.setAttribute("aria-label", label);
  motionToggle.title = label;
  motionToggle.disabled = video.error !== null;
  demoError.hidden = video.error === null;
}

function syncPlayback() {
  const activeVideo = demos[activeIndex].video;
  for (const { video } of demos) {
    if (video !== activeVideo) video.pause();
  }

  if (!shouldPlay || !inView || document.hidden) {
    activeVideo.pause();
  } else if (!activeVideo.error) {
    if (!activeVideo.hasAttribute("src")) activeVideo.src = activeVideo.dataset.src;
    activeVideo.play().catch((error) => {
      if (error.name === "AbortError" || activeVideo !== demos[activeIndex].video) return;
      shouldPlay = false;
      updatePlaybackControl();
    });
  }
  updatePlaybackControl();
}

function selectTab(index) {
  if (activeIndex === index) return;
  activeIndex = index;
  tabList.style.setProperty("--active-index", index);
  for (const [option, { tab, panel }] of demos.entries()) {
    const selected = option === activeIndex;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
    panel.hidden = !selected;
  }
  const { video } = demos[index];
  if (video.readyState > 0) video.currentTime = 0;
  syncPlayback();
}

for (const [index, { tab, video }] of demos.entries()) {
  tab.addEventListener("click", () => selectTab(index));
  tab.addEventListener("keydown", (event) => {
    const moves = {
      ArrowRight: (index + 1) % tabs.length,
      ArrowLeft: (index - 1 + tabs.length) % tabs.length,
      Home: 0,
      End: tabs.length - 1,
    };
    if (!Object.hasOwn(moves, event.key)) return;
    event.preventDefault();
    const nextIndex = moves[event.key];
    selectTab(nextIndex);
    tabs[nextIndex].focus();
  });
  video.muted = true;
  for (const event of ["play", "pause", "error"]) {
    video.addEventListener(event, () => {
      if (index === activeIndex) updatePlaybackControl();
    });
  }
  video.addEventListener("ended", () => {
    if (index !== activeIndex || !shouldPlay || !inView || document.hidden) return;
    if (reduceMotion.matches || tabList.contains(document.activeElement)) {
      shouldPlay = false;
      updatePlaybackControl();
      return;
    }
    selectTab((index + 1) % tabs.length);
  });
}

motionToggle.addEventListener("click", () => {
  shouldPlay = demos[activeIndex].video.paused;
  syncPlayback();
});
document.addEventListener("visibilitychange", syncPlayback);
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
