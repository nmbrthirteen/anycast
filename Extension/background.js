// Chrome stops idle service workers and wipes module state, so the casting tab lives in session storage.
async function getCastingTab() {
  const { castingTab = null } = await chrome.storage.session.get("castingTab");

  return castingTab;
}

async function setCastingTab(tabId) {
  await chrome.storage.session.set({ castingTab: tabId });
}

async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });

  if (contexts.length === 0) {
    await chrome.offscreen.createDocument({
      url: "offscreen.html",
      reasons: ["USER_MEDIA"],
      justification: "Capture the tab and stream it to the AnyCast app",
    });
  }
}

async function setBadge(text, color) {
  await chrome.action.setBadgeText({ text });

  if (color) await chrome.action.setBadgeBackgroundColor({ color });
}

chrome.action.onClicked.addListener(async (tab) => {
  await ensureOffscreen();

  if ((await getCastingTab()) !== null) {
    chrome.runtime.sendMessage({ target: "offscreen", type: "stop" });
    await setCastingTab(null);
    await setBadge("");

    return;
  }

  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
  await setCastingTab(tab.id);
  await setBadge("TV", "#2f7cf6");
  chrome.runtime.sendMessage({ target: "offscreen", type: "start", streamId, title: tab.title || "Browser tab" });
});

chrome.runtime.onMessage.addListener(async (message) => {
  if (message.target !== "background") return;

  if (message.type === "stopped") {
    await setCastingTab(null);
    await setBadge("");
  } else if (message.type === "error") {
    await setCastingTab(null);
    await setBadge("!", "#d93025");
  }
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  if (tabId === (await getCastingTab())) chrome.runtime.sendMessage({ target: "offscreen", type: "stop" });
});
