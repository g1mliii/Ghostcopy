// Highlight the download for the visitor's own device.
//
// The landing page lists Mac, Windows and iPhone side by side, and the accent
// button used to be the Mac's whatever you were on - a Windows visitor saw
// their download as the secondary option. This moves the accent (.cta) to the
// visitor's platform, whitens the others (.cta-alt) and puts theirs first.
// Without JavaScript, or on a platform with no build yet, the page is left as
// it was served.
(function () {
    'use strict';

    function detect() {
        var ua = navigator.userAgent || '';
        var platform = (navigator.userAgentData && navigator.userAgentData.platform) ||
            navigator.platform || '';
        // iPadOS reports itself as a Mac; a touch screen gives it away.
        if (/iPhone|iPad|iPod/.test(ua) ||
            (/Mac/.test(platform) && navigator.maxTouchPoints > 1)) return 'ios';
        if (/Android/i.test(ua)) return null;
        if (/Mac/.test(platform) || /Macintosh/.test(ua)) return 'mac';
        if (/Win/.test(platform) || /Windows/.test(ua)) return 'windows';
        return null;
    }

    var mine = detect();
    var target = mine && document.querySelector('[data-platform="' + mine + '"]');
    if (!target) return;

    var links = document.querySelectorAll('[data-platform]');
    for (var i = 0; i < links.length; i++) {
        var own = links[i] === target;
        links[i].classList.toggle('cta', own);
        links[i].classList.toggle('cta-alt', !own);
    }
    target.parentNode.insertBefore(target, target.parentNode.firstElementChild);
})();
