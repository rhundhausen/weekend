// The sources page (layouts/sources.html): the "show sources with no events" box and column
// sorting, both kept in the URL.
(function () {
  var box = document.getElementById('show-empty');
  var table = document.getElementById('sources-table');
  function apply() {
    table.classList.toggle('hide-empty', !box.checked);
    var url = new URL(location.href);
    if (box.checked) url.searchParams.set('show', 'all'); else url.searchParams.delete('show');
    history.replaceState(null, '', url.search ? url.pathname + url.search : url.pathname);
  }
  box.checked = new URLSearchParams(location.search).get('show') === 'all';
  box.addEventListener('change', apply);
  apply();

  // Sorting. Rows come in Source order; ties fall back to that order (the source name).
  var body = table.querySelector('tbody');
  var rows = Array.prototype.slice.call(body.rows);
  rows.forEach(function (r, i) { r.dataset.order = i; });
  var keys = {
    name: function (r) { return +r.dataset.order; },
    city: function (r) { return r.dataset.city; },
    type: function (r) { return r.dataset.type; },
    count: function (r) { return +r.dataset.count; },
  };
  var sort = 'name';
  var dir = 1;
  function render() {
    var key = keys[sort];
    rows.sort(function (a, b) {
      var x = key(a);
      var y = key(b);
      var c = typeof x === 'number' ? x - y : x.localeCompare(y);
      return c * dir || a.dataset.order - b.dataset.order;
    });
    rows.forEach(function (r) { body.appendChild(r); });
    table.querySelectorAll('th[data-sort]').forEach(function (th) {
      if (th.dataset.sort === sort) th.setAttribute('aria-sort', dir === 1 ? 'ascending' : 'descending');
      else th.removeAttribute('aria-sort');
    });
    var url = new URL(location.href);
    if (sort !== 'name' || dir !== 1) url.searchParams.set('sort', sort + (dir === -1 ? ':desc' : ''));
    else url.searchParams.delete('sort');
    history.replaceState(null, '', url.search ? url.pathname + url.search : url.pathname);
  }
  table.querySelectorAll('th[data-sort] button').forEach(function (button) {
    button.addEventListener('click', function () {
      var key = button.parentElement.dataset.sort;
      if (key === sort) dir = -dir;
      else { sort = key; dir = 1; }
      render();
    });
  });
  var asked = (new URLSearchParams(location.search).get('sort') || '').split(':');
  if (keys[asked[0]]) {
    sort = asked[0];
    dir = asked[1] === 'desc' ? -1 : 1;
    render();
  }
})();
