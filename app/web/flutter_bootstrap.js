{{flutter_js}}
{{flutter_build_config}}

// The engine downloads Noto fallback fonts (emoji, CJK, Arabic, Indic, symbols)
// for glyphs Roboto lacks. They are self-hosted under fonts/fallback/ by
// tool/web_fallback_fonts.py, so the page needs no third-party font CDN and the
// CSP stays same-origin.
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: {
    fontFallbackBaseUrl: new URL("fonts/fallback/", document.baseURI).href,
  },
});
