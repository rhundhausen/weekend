// The map view. app.js imports this module the first time Map is chosen, so the list page never
// loads it or MapLibre. Each event's point is e.spot, [lat, lon, exact], from the build (grid.html):
// exact 1 is the venue itself, 0 a ZIP code's or town's center. Events at one point are one
// feature; MapLibre clusters nearby features when zoomed out.
//
// The visitor's position stays in this page: it is never sent, stored, or put in the address. The
// tiles for whatever area is on screen come from OpenFreeMap, as with any web map.

const STYLES = {
  light: 'https://tiles.openfreemap.org/styles/positron',
  dark: 'https://tiles.openfreemap.org/styles/dark',
};
const NEAR_MILES = 150;
const POPUP_MAX = 20;
const FONT = ['Noto Sans Regular'];

function miles([lat1, lon1], [lat2, lon2]) {
  const rad = Math.PI / 180;
  const a = Math.sin(((lat2 - lat1) * rad) / 2) ** 2
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(((lon2 - lon1) * rad) / 2) ** 2;
  return 2 * 3958.8 * Math.asin(Math.min(1, Math.sqrt(a)));
}

function cssVar(name, fallback) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

function darkTheme() {
  const set = document.documentElement.dataset.theme;
  if (set) return set === 'dark';
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function soonest(a, b) {
  return a.sd < b.sd ? -1 : a.sd > b.sd ? 1 : (a.instant - b.instant) || a.title.localeCompare(b.title);
}

// The popup for one point: its events soonest first, as text only (event text comes from
// outside sources, so it is never treated as HTML).
function popupContent(list, exact) {
  const box = document.createElement('div');
  box.className = 'map-pop';
  // One venue written two ways ("For The" and "for the") is still one venue.
  const byName = new Map();
  for (const e of list) if (e.venue && !byName.has(e.venue.toLowerCase())) byName.set(e.venue.toLowerCase(), e.venue);
  const venues = [...byName.values()];
  const head = document.createElement('p');
  head.className = 'map-pop-place';
  head.textContent = exact && venues.length === 1 ? venues[0] : list[0].city || 'Events here';
  box.append(head);
  if (!exact) {
    const note = document.createElement('p');
    note.className = 'map-pop-note';
    note.textContent = `Placed at the center of ${list[0].city || 'the town'}, not at the venue.`;
    box.append(note);
  }
  const ul = document.createElement('ul');
  for (const e of list.slice(0, POPUP_MAX)) {
    const li = document.createElement('li');
    const when = document.createElement('span');
    when.className = 'map-pop-when';
    when.textContent = `${e.dateText}, ${e.timeText}`;
    let name;
    if (e.url && !e.broken) {
      name = document.createElement('a');
      name.href = e.url;
      name.target = '_blank';
      name.rel = 'noopener';
    } else {
      name = document.createElement('span');
    }
    name.className = 'map-pop-title';
    name.textContent = e.title;
    li.append(when, name);
    if (!exact || venues.length > 1) {
      const where = document.createElement('span');
      where.className = 'map-pop-venue';
      where.textContent = e.venue;
      li.append(where);
    }
    ul.append(li);
  }
  box.append(ul);
  if (list.length > POPUP_MAX) {
    const more = document.createElement('p');
    more.className = 'map-pop-more';
    more.textContent = `and ${(list.length - POPUP_MAX).toLocaleString('en-US')} more`;
    box.append(more);
  }
  return box;
}

export async function openMap(container, note, cfg) {
  const ml = await import(cfg.map.maplibre);
  ml.setWorkerUrl(cfg.map.worker);
  const center = cfg.map.center;

  let groups = new Map();
  let points = [];
  let me = null;
  let fitted = false;
  let popup = null;
  let styled = false;
  let failed = false;
  let count = '';

  const map = new ml.Map({
    container,
    style: darkTheme() ? STYLES.dark : STYLES.light,
    center: [center[1], center[0]],
    zoom: 9,
    dragRotate: false,
    pitchWithRotate: false,
    touchPitch: false,
  });
  map.touchZoomRotate.disableRotation();
  map.addControl(new ml.NavigationControl({ showCompass: false }), 'top-right');

  const geojson = () => ({
    type: 'FeatureCollection',
    features: points.map((p) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [p.lon, p.lat] },
      properties: { key: p.key, count: p.list.length, exact: p.exact },
    })),
  });

  function addLayers() {
    const accent = cssVar('--accent', '#1d4ed8');
    const ink = cssVar('--accent-text', '#ffffff');
    const surface = cssVar('--surface', '#ffffff');
    map.addSource('events', {
      type: 'geojson',
      data: geojson(),
      cluster: true,
      clusterRadius: 40,
      clusterMaxZoom: 14,
      clusterProperties: { total: ['+', ['get', 'count']] },
    });
    map.addLayer({
      id: 'clusters', type: 'circle', source: 'events', filter: ['has', 'point_count'],
      paint: {
        'circle-color': accent, 'circle-opacity': 0.9, 'circle-stroke-color': surface, 'circle-stroke-width': 2,
        'circle-radius': ['step', ['get', 'total'], 14, 25, 18, 100, 23, 500, 28],
      },
    });
    map.addLayer({
      id: 'cluster-count', type: 'symbol', source: 'events', filter: ['has', 'point_count'],
      layout: { 'text-field': ['to-string', ['get', 'total']], 'text-font': FONT, 'text-size': 12, 'text-allow-overlap': true },
      paint: { 'text-color': ink },
    });
    map.addLayer({
      id: 'exact', type: 'circle', source: 'events', filter: ['all', ['!', ['has', 'point_count']], ['==', ['get', 'exact'], 1]],
      paint: {
        'circle-color': accent, 'circle-stroke-color': surface, 'circle-stroke-width': 2,
        'circle-radius': ['step', ['get', 'count'], 8, 2, 11, 10, 14],
      },
    });
    map.addLayer({
      id: 'approx', type: 'circle', source: 'events', filter: ['all', ['!', ['has', 'point_count']], ['==', ['get', 'exact'], 0]],
      paint: {
        'circle-color': surface, 'circle-opacity': 0.85, 'circle-stroke-color': accent, 'circle-stroke-width': 3,
        'circle-radius': ['step', ['get', 'count'], 9, 2, 12, 10, 15],
      },
    });
    map.addLayer({
      id: 'point-count', type: 'symbol', source: 'events', filter: ['all', ['!', ['has', 'point_count']], ['>', ['get', 'count'], 1]],
      layout: { 'text-field': ['to-string', ['get', 'count']], 'text-font': FONT, 'text-size': 11, 'text-allow-overlap': true },
      paint: { 'text-color': ['case', ['==', ['get', 'exact'], 1], ink, accent] },
    });
  }

  function fitShown() {
    if (!points.length) {
      map.jumpTo({ center: [center[1], center[0]], zoom: 9 });
      return;
    }
    const bounds = new ml.LngLatBounds();
    for (const p of points) bounds.extend([p.lon, p.lat]);
    map.fitBounds(bounds, { padding: 40, maxZoom: 13, duration: 0 });
  }

  // Each style load (the first one, and a theme change) needs the events added again.
  map.on('style.load', () => {
    styled = true;
    if (failed) note.textContent = count;
    failed = false;
    addLayers();
  });
  // The map's style, tiles, and fonts come from OpenFreeMap. If the style can't be had, say so
  // instead of leaving an empty panel.
  map.on('error', () => {
    if (styled) return;
    failed = true;
    note.textContent = 'The map could not load. Try again later, or use List.';
  });

  map.on('click', 'clusters', async (ev) => {
    const feature = ev.features[0];
    const zoom = await map.getSource('events').getClusterExpansionZoom(feature.properties.cluster_id);
    map.easeTo({ center: feature.geometry.coordinates, zoom });
  });
  for (const layer of ['exact', 'approx']) {
    map.on('click', layer, (ev) => {
      const feature = ev.features[0];
      const group = groups.get(feature.properties.key);
      if (!group) return;
      // Never wider than the map. MapLibre doesn't slide a popup to fit, so on a narrow map the
      // point moves to the upper middle first and the popup opens below it.
      const width = Math.max(200, Math.min(320, container.clientWidth - 48));
      const narrow = container.clientWidth < 600;
      if (narrow) map.easeTo({ center: feature.geometry.coordinates, offset: [0, -container.clientHeight * 0.3], duration: 300 });
      popup?.remove();
      popup = new ml.Popup({ maxWidth: `${width}px`, focusAfterOpen: false, ...(narrow ? { anchor: 'top' } : {}) })
        .setLngLat(feature.geometry.coordinates)
        .setDOMContent(popupContent(group.list, group.exact))
        .addTo(map);
    });
  }
  for (const layer of ['clusters', 'exact', 'approx']) {
    map.on('mouseenter', layer, () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', layer, () => { map.getCanvas().style.cursor = ''; });
  }

  const scheme = window.matchMedia('(prefers-color-scheme: dark)');
  scheme.addEventListener('change', () => map.setStyle(darkTheme() ? STYLES.dark : STYLES.light));

  // Asked once, when the map first opens. Only a position near the city moves the map, so a
  // visitor far away still opens on the events.
  if (navigator.geolocation) {
    navigator.geolocation.getCurrentPosition((pos) => {
      const here = [pos.coords.latitude, pos.coords.longitude];
      if (miles(here, center) > NEAR_MILES) return;
      const dot = document.createElement('div');
      dot.className = 'map-me';
      dot.setAttribute('aria-label', 'You are here');
      me = new ml.Marker({ element: dot }).setLngLat([here[1], here[0]]).addTo(map);
      map.jumpTo({ center: [here[1], here[0]], zoom: 13 });
    }, () => {}, { timeout: 10000, maximumAge: 600000 });
  }

  return {
    // The events the list would show, from app.js render(). Redraws without moving the camera.
    update(events) {
      // An open popup lists what the old filters showed.
      popup?.remove();
      popup = null;
      groups = new Map();
      let placed = 0;
      for (const e of events) {
        if (!e.spot) continue;
        placed++;
        const [lat, lon, exact] = e.spot;
        const key = `${lat},${lon},${exact}`;
        let group = groups.get(key);
        if (!group) groups.set(key, (group = { key, lat, lon, exact, list: [] }));
        group.list.push(e);
      }
      for (const group of groups.values()) group.list.sort(soonest);
      points = [...groups.values()];
      const source = map.getSource('events');
      if (source) source.setData(geojson());
      // The first events set the view, unless the visitor's position already has. An empty first
      // set (a search that matches nothing) leaves it for the next.
      if (!fitted && points.length) {
        fitted = true;
        if (!me) fitShown();
      }
      const missing = events.length - placed;
      count = `${placed.toLocaleString('en-US')} ${placed === 1 ? 'event' : 'events'} on the map.`
        + (missing ? ` ${missing.toLocaleString('en-US')} without a location.` : '');
      if (!failed) note.textContent = count;
    },
    resize() {
      map.resize();
    },
  };
}
