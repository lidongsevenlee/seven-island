"use strict";

const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
const fullCapture = document.getElementById("full-capture");

function selectTab(tab) {
  for (const option of tabs) {
    const selected = option === tab;
    const panel = document.getElementById(option.getAttribute("aria-controls"));
    option.setAttribute("aria-selected", String(selected));
    option.tabIndex = selected ? 0 : -1;
    panel.hidden = !selected;
    if (selected) fullCapture.href = panel.querySelector("img").src;
  }
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
}
