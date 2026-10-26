// Runs in the page's own JS world, before YouTube's scripts.
(() => {
  const config = window.__hmpConfig || {};

  // YouTube TV's "Exit" calls window.close(), which Chromium refuses for a
  // page with history. Ask the extension to close the window instead.
  window.close = () => window.postMessage({ hmp: 'close' }, '*');

  if (config.forceH264) {
    // Same idea as the h264ify extension: VP9/AV1 would be decoded on the CPU
    // and stutter, H.264 is much cheaper.
    const blocked = /vp0?[89]|av01/i;
    const isTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = (type) => !blocked.test(type) && isTypeSupported(type);

    const canPlayType = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (type) {
      return blocked.test(type) ? '' : canPlayType.call(this, type);
    };

    const caps = navigator.mediaCapabilities;
    if (caps && caps.decodingInfo) {
      const decodingInfo = caps.decodingInfo.bind(caps);
      caps.decodingInfo = (cfg) => {
        const type = (cfg && cfg.video && cfg.video.contentType) || '';
        if (blocked.test(type)) {
          return Promise.resolve({ supported: false, smooth: false, powerEfficient: false });
        }
        return decodingInfo(cfg);
      };
    }
  }
})();
