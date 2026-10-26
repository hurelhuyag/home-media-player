// Isolated content script: forwards requests from page.js to the extension.
window.addEventListener('message', (event) => {
  if (event.source === window && event.data && event.data.hmp === 'close') {
    chrome.runtime.sendMessage({ hmp: 'close' });
  }
});

// Show the mouse pointer only while the mouse is used (see hide-cursor.css).
let pointerTimer;
const hidePointer = () => {
  clearTimeout(pointerTimer);
  document.documentElement.classList.remove('hmp-pointer');
};
window.addEventListener('mousemove', () => {
  document.documentElement.classList.add('hmp-pointer');
  clearTimeout(pointerTimer);
  pointerTimer = setTimeout(hidePointer, 5000);
}, { capture: true, passive: true });
window.addEventListener('keydown', hidePointer, { capture: true, passive: true });
