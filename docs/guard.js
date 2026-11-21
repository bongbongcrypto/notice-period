/* Loaded first. If one of this page's scripts does not load, or stops before the panel is drawn, the panel says so in
   one sentence instead of staying empty. The recorded run in the page's HTML is not touched. */
(function () {
  'use strict';
  var told = false;
  function tell() {
    var box = document.getElementById('state');
    /* a state already drawn means the scripts are running: nothing to say here */
    if (told || !box || box.hasAttribute('data-state')) return;
    told = true;
    var p = document.getElementById('boot-line');
    if (!p) { p = document.createElement('p'); p.id = 'boot-line'; box.appendChild(p); }
    p.textContent = 'A part of this page did not load, so the guided run and the replay are off. The recorded runs on this page are real and their links work. ';
    var a = document.createElement('a');
    a.href = String(window.location.href).split('#')[0];
    a.textContent = 'Reload the page';
    p.appendChild(a);
  }
  /* a script file that fails to load fires "error" on its element; that event does not bubble, so it is caught on the way down */
  window.addEventListener('error', function (ev) {
    var t = ev && ev.target;
    if (t && t.nodeName === 'SCRIPT') return tell();
    if (t === window) tell(); /* a script threw before the panel was drawn */
  }, true);
}());
