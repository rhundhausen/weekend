// Day, sunset, or night look and icons, set before the first paint so the page never flashes.
// Loaded in <head> without defer (layouts/baseof.html), which also puts the city's coordinates
// and the icons folder on <html> as data-lat, data-lon, and data-icons.
//
// The periods follow the city's sky, worked out each day from its sunrise and sunset (NOAA's
// sunrise equation), so they move with the seasons: sunset runs from an hour before sunset to half
// an hour after it (about the end of civil twilight), night until half an hour before sunrise, and
// day the rest. Times are instants, so a visitor in another zone sees the city's sky. Checked again
// every 10 minutes for open tabs. The CSS colors and the header logo follow data-period; this
// script points the favicon links at the matching icons.
(function () {
  var root = document.documentElement;
  var base = root.dataset.icons;
  var LAT = Number(root.dataset.lat), LON = Number(root.dataset.lon), MIN = 60000, rad = Math.PI / 180;
  // Sunrise and sunset (ms since 1970) on the solar day nearest now, at the city.
  function sun(now) {
    var jd = now / 86400000 + 2440587.5;
    var n = Math.round(jd - 2451545.0009 + LON / 360);
    var j = 2451545.0009 - LON / 360 + n;
    var m = (357.5291 + 0.98560028 * (j - 2451545)) % 360;
    var c = 1.9148 * Math.sin(m * rad) + 0.02 * Math.sin(2 * m * rad) + 0.0003 * Math.sin(3 * m * rad);
    var l = (m + c + 180 + 102.9372) % 360;
    var transit = j + 0.0053 * Math.sin(m * rad) - 0.0069 * Math.sin(2 * l * rad);
    var dec = Math.asin(Math.sin(l * rad) * Math.sin(23.4397 * rad));
    var w = Math.acos((Math.sin(-0.833 * rad) - Math.sin(LAT * rad) * Math.sin(dec)) / (Math.cos(LAT * rad) * Math.cos(dec))) / rad;
    function ms(x) { return (x - 2440587.5) * 86400000; }
    return { rise: ms(transit - w / 360), set: ms(transit + w / 360) };
  }
  function periodAt(now) {
    var s = sun(now);
    if (now < s.rise - 30 * MIN || now >= s.set + 30 * MIN) return 'night';
    return now >= s.set - 60 * MIN ? 'sunset' : 'day';
  }
  function set() {
    var period = periodAt(Date.now());
    if (root.dataset.period === period) return;
    root.dataset.period = period;
    // The icon links come before this script in <head>.
    var links = { 'icon-ico': 'favicon.ico', 'icon-svg': 'favicon.svg', 'icon-apple': 'apple-touch-icon.png' };
    for (var id in links) {
      var link = document.getElementById(id);
      if (link) link.href = base + period + '/' + links[id];
    }
  }
  set();
  setInterval(set, 600000);
})();
