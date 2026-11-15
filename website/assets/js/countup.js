// Sets up the header count to run up from 0 (app.js animates it). Loaded without defer right after
// the count (layouts/_partials/grid.html), so it runs before the page draws and the real number
// never flashes first. Its width is held at the full number's, so the rest of the line stays put.
// Skipped for reduced motion.
(function () {
  var t = document.getElementById('total');
  if (!t || (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches)) return;
  t.style.minWidth = t.getBoundingClientRect().width + 'px';
  t.dataset.countUp = t.textContent;
  t.textContent = '0';
})();
