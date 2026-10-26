// Closing the last window ends Chromium and brings the kiosk back.
chrome.runtime.onMessage.addListener((message, sender) => {
  if (message && message.hmp === 'close' && sender.tab) {
    chrome.windows.remove(sender.tab.windowId);
  }
});
