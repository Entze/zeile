/**
 * Shared Cookie Consent Banner
 * Standalone vanilla JS — no framework dependencies.
 * Ported from claude-com/frontend/src/components/molecules/Consent/
 *
 * KEEP IN SYNC: This file duplicates logic from the React consent components.
 * If you change any of the following, update both places:
 *   - Country list         → here: CONSENT_COUNTRIES
 *                            React: inExplicitConsentRequiredCountry.ts
 *   - Cookie name/format   → here: COOKIE_KEY
 *                            React: types.ts (CONSENT_PREFERENCES_COOKIE_KEY)
 *   - Cookie cleanup lists → here: COOKIES_TO_DELETE / COOKIE_PATTERNS
 *                            React: cookies.ts (COOKIES_PER_CONSENT_CATEGORY)
 *   - Button text/selectors must match cookie_verification test suite
 *                            (anthropic/cookie_verification/anthropic_cookies.py)
 *
 * Usage: Load via a script tag with src="https://www.claude.com/shared/consent-banner.js".
 *        Adding `defer` is recommended but not required — the script guards on DOMContentLoaded internally.
 *
 * Geo detection: reads `cf_geo` cookie (set by Cloudflare Worker).
 *   If `cf_geo` is absent, the banner WILL show (fail-closed), matching the React version.
 * Test override: `?country=XX` URL param (for cookie_verification test suite).
 * Re-open: dispatch `new CustomEvent('show-consent-banner')` or click an element
 *          matching `[data-consent-reopen]`.
 */
;(function () {
  'use strict'

  // Capture script src at parse time (document.currentScript is only available during
  // synchronous script execution). Used to derive the sibling consent-banner.css URL.
  var _scriptSrc = document.currentScript ? document.currentScript.src : null
  if (!_scriptSrc) {
    var _scripts = document.getElementsByTagName('script')
    for (var _i = 0; _i < _scripts.length; _i++) {
      if (_scripts[_i].src && _scripts[_i].src.indexOf('consent-banner.js') !== -1) {
        _scriptSrc = _scripts[_i].src
        break
      }
    }
  }

  // ── Constants ──────────────────────────────────────────────────────────────

  var COOKIE_KEY = 'anthropic-consent-preferences'
  var SHOW_EVENT = 'show-consent-banner'

  var ACCEPT_ALL = Object.freeze({analytics: true, marketing: true})
  var REJECT_ALL = Object.freeze({analytics: false, marketing: false})

  // Countries/regions requiring explicit consent before non-essential cookies.
  // Mirrors claude-com inExplicitConsentRequiredCountry.ts:79-158.
  var CONSENT_COUNTRIES = [
    // EU 27
    'AT',
    'BE',
    'BG',
    'HR',
    'CY',
    'CZ',
    'DK',
    'EE',
    'FI',
    'FR',
    'DE',
    'GR',
    'HU',
    'IE',
    'IT',
    'LV',
    'LT',
    'LU',
    'MT',
    'NL',
    'PL',
    'PT',
    'RO',
    'SK',
    'SI',
    'ES',
    'SE',
    // French overseas
    'RE',
    'GP',
    'MQ',
    'GF',
    'YT',
    'BL',
    'MF',
    'PM',
    'WF',
    'PF',
    'NC',
    // Dutch overseas
    'AW',
    'CW',
    'SX',
    // Danish
    'FO',
    'GL',
    // Finnish
    'AX',
    // UK
    'GB',
    'UK',
    // UK overseas & Crown Dependencies
    'AI',
    'BM',
    'IO',
    'VG',
    'KY',
    'FK',
    'GI',
    'MS',
    'PN',
    'SH',
    'TC',
    'GG',
    'JE',
    'IM',
    // Other
    'CA',
    'BR',
    'IN',
  ]
  var CONSENT_SET = {}
  for (var i = 0; i < CONSENT_COUNTRIES.length; i++) {
    CONSENT_SET[CONSENT_COUNTRIES[i]] = true
  }

  // Cookies to delete when user opts out of a category.
  // Mirrors claude-com cookies.ts COOKIES_PER_CONSENT_CATEGORY.
  var COOKIES_BY_CATEGORY = {
    analytics: [
      'ajs_anonymous_id',
      'ajs_user_id',
      'ajs_group_id',
      'analytics_session_id',
      '_ga',
      '_gid',
      '_gat',
      '__utma',
      '__utmb',
      '__utmc',
      '__utmt',
      '__utmz',
      '__utmv',
      '_gaexp',
      '_gaexp_rc',
      '_opt_expid',
      'AMP_TOKEN',
      'FPID',
      'FPLC',
      'TESTCOOKIESENABLED',
      'li_giant',
      'ln_or',
      'oribi_cookie_test',
      'oribili_user_guid',
    ],
    marketing: [
      '_fbc',
      '_fbp',
      '__gads',
      '__gpi',
      '__gpi_optout',
      '__gsas',
      '_gcl_aw',
      '_gcl_dc',
      '_gcl_au',
      '_gcl_gb',
      '_gcl_gf',
      '_gcl_ha',
      '_gcl_gs',
      '_gcl_ag',
      'GCL_AW_P',
      'GED_PLAYLIST_ACTIVITY',
      'ACLK_DATA',
      'FLC',
      '_opt_awcid',
      '_opt_awmid',
      '_opt_awgid',
      '_opt_awkid',
      '_opt_utmc',
      'FPAU',
      'FPGCLDC',
      'FPGCLAW',
      'FPGCLGB',
      'FPGSID',
      'FCCDCF',
      'FCNEC',
      'li_fat_id',
      'ar_debug',
      '_ttclid',
      '_rdt_uuid',
      '_rdt_cid',
    ],
  }

  // Regex patterns for dynamic cookie names (GA4, GTM, Google Ads).
  var COOKIE_PATTERNS_BY_CATEGORY = {
    analytics: [/^_gat_gtag_UA_/, /^_ga_/, /^_dc_gtm_/],
    marketing: [/^_gac_/, /^_gac_gb_/],
  }

  // ── Cookie helpers ─────────────────────────────────────────────────────────

  function getDomainFromHost(hostname) {
    function endsWith(str, suffix) {
      return str.indexOf(suffix, str.length - suffix.length) !== -1
    }
    if (hostname === 'claude.ai' || endsWith(hostname, '.claude.ai')) return '.claude.ai'
    if (hostname === 'claude.com' || endsWith(hostname, '.claude.com')) return '.claude.com'
    if (hostname === 'anthropic.com' || endsWith(hostname, '.anthropic.com'))
      return '.anthropic.com'
    return undefined
  }

  function getCookie(name) {
    var cookies = document.cookie.split(';')
    for (var i = 0; i < cookies.length; i++) {
      var parts = cookies[i].trim().split('=')
      if (parts[0] === name) return decodeURIComponent(parts.slice(1).join('='))
    }
    return undefined
  }

  function hasCookie(name) {
    var cookies = document.cookie.split(';')
    for (var i = 0; i < cookies.length; i++) {
      if (cookies[i].trim().indexOf(name + '=') === 0) return true
    }
    return false
  }

  function setCookie(name, value) {
    var domain = getDomainFromHost(window.location.hostname)
    var parts = [
      name + '=' + encodeURIComponent(value),
      'max-age=' + 60 * 60 * 24 * 365,
      'path=/',
      'samesite=lax',
    ]
    // Always set secure — matches React version (cookies.ts:58). On http://localhost
    // during dev the cookie won't persist, but that's expected and matches behavior.
    parts.push('secure')
    if (domain) parts.push('domain=' + domain)
    document.cookie = parts.join('; ')
  }

  function deleteCookie(name) {
    if (!/^[\w-]+$/.test(name)) return
    var hostname = window.location.hostname
    var domain = getDomainFromHost(hostname)
    var hostParts = hostname.split('.')
    var rootDomain = hostParts.length >= 2 ? hostParts.slice(-2).join('.') : null

    var domains = [undefined]
    if (domain) domains.push(domain)
    if (rootDomain && rootDomain !== domain) domains.push(rootDomain)
    if (hostname && hostname !== domain && hostname !== rootDomain) domains.push(hostname)

    var paths = ['/', '']
    for (var d = 0; d < domains.length; d++) {
      for (var p = 0; p < paths.length; p++) {
        var dp = domains[d] ? '; domain=' + domains[d] : ''
        var pp = paths[p] !== '' ? '; path=' + paths[p] : ''
        document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT' + pp + dp
      }
    }
  }

  function getAllCookieNames() {
    return document.cookie.split(';').map(function (c) {
      return c.split('=')[0].trim()
    })
  }

  function deleteCookiesForCategory(category) {
    var names = getAllCookieNames()
    var exact = COOKIES_BY_CATEGORY[category] || []
    var patterns = COOKIE_PATTERNS_BY_CATEGORY[category] || []

    for (var i = 0; i < names.length; i++) {
      var n = names[i]
      if (exact.indexOf(n) !== -1) {
        deleteCookie(n)
        continue
      }
      for (var p = 0; p < patterns.length; p++) {
        if (patterns[p].test(n)) {
          deleteCookie(n)
          break
        }
      }
    }
  }

  // ── Geo detection ──────────────────────────────────────────────────────────

  function getCountryCode() {
    // Test override via URL param (for cookie_verification suite, geo_mock_strategy=param)
    var match = window.location.search.match(/[?&]country=([A-Za-z]{2})/)
    if (match) return match[1].toUpperCase()

    // Production: cf_geo cookie set by Cloudflare Worker (format: "US-CA")
    var geo = getCookie('cf_geo')
    if (geo) return geo.split('-')[0]

    return null
  }

  // Unknown country → show banner (fail-closed), matching the React SSR default.
  function requiresExplicitConsent() {
    var code = getCountryCode()
    return code ? !!CONSENT_SET[code] : true
  }

  // ── GPC ────────────────────────────────────────────────────────────────────

  function isGPCEnabled() {
    return !!(navigator && navigator.globalPrivacyControl)
  }

  // ── Consent logic ──────────────────────────────────────────────────────────

  function getInitialPreferences() {
    var raw = getCookie(COOKIE_KEY)
    if (raw) {
      try {
        var parsed = JSON.parse(raw)
        if (typeof parsed.analytics === 'boolean' && typeof parsed.marketing === 'boolean') {
          return parsed
        }
      } catch (e) {
        /* fall through */
      }
    }
    return requiresExplicitConsent()
      ? {analytics: false, marketing: false}
      : {analytics: true, marketing: true}
  }

  function applyPreferences(prefs) {
    var categories = ['analytics', 'marketing']
    for (var i = 0; i < categories.length; i++) {
      if (!prefs[categories[i]]) deleteCookiesForCategory(categories[i])
    }
  }

  function savePreferences(prefs) {
    setCookie(COOKIE_KEY, JSON.stringify(prefs))
    applyPreferences(prefs)
  }

  // ── DOM construction ───────────────────────────────────────────────────────

  // CSS lives in the sibling consent-banner.css file, injected via <link> so consumer
  // sites with a strict style-src CSP (no 'unsafe-inline') can still load the banner.
  // Calls `callback` once the stylesheet has loaded (or immediately if already injected).
  function injectStyles(callback) {
    if (document.getElementById('consent-banner-styles')) {
      callback()
      return
    }
    var cssUrl = _scriptSrc
      ? _scriptSrc.replace(/consent-banner\.js(\?.*)?$/, 'consent-banner.css')
      : 'consent-banner.css'
    var link = document.createElement('link')
    link.id = 'consent-banner-styles'
    link.rel = 'stylesheet'
    link.href = cssUrl
    var called = false
    function once() {
      if (called) return
      called = true
      callback()
    }
    link.onload = once
    // If CSS fails to load, show the banner anyway rather than blocking forever.
    link.onerror = once
    document.head.appendChild(link)
  }

  function createBanner(initialPrefs, onSave) {
    var analyticsOn = initialPrefs.analytics
    var marketingOn = initialPrefs.marketing
    var simpleView = true
    var closed = false
    var ready = false

    // <dialog>
    var dialog = document.createElement('dialog')
    dialog.id = 'consent-container'
    dialog.setAttribute('data-testid', 'consent-banner')
    dialog.setAttribute('aria-labelledby', 'consent-banner-title')

    function render() {
      while (dialog.firstChild) dialog.removeChild(dialog.firstChild)

      var inner = document.createElement('div')
      inner.className = 'cb-inner'

      var title = document.createElement('h3')
      title.className = 'cb-title'
      title.id = 'consent-banner-title'
      title.textContent = 'Cookie settings'
      inner.appendChild(title)

      if (simpleView) {
        renderSimpleView(inner)
      } else {
        renderCustomizeView(inner)
      }

      dialog.appendChild(inner)
    }

    function renderSimpleView(parent) {
      var desc = document.createElement('p')
      desc.className = 'cb-desc'
      desc.appendChild(
        document.createTextNode(
          'We use cookies to deliver and improve our services, analyze site usage, and if you ' +
            'agree, to customize or personalize your experience and market our services to you. You ' +
            'can read our Cookie Policy ',
        ),
      )
      var policyLink = document.createElement('a')
      policyLink.className = 'cb-link'
      policyLink.href = 'https://www.anthropic.com/legal/cookies'
      policyLink.textContent = 'here'
      desc.appendChild(policyLink)
      desc.appendChild(document.createTextNode('.'))
      parent.appendChild(desc)

      var btns = document.createElement('div')
      btns.className = 'cb-btns'

      var customize = makeBtnWithSuffix(
        'Customize',
        'cookie settings',
        'cb-btn cb-btn-secondary cb-customize',
        function () {
          simpleView = false
          render()
        },
      )
      customize.setAttribute('data-testid', 'consent-customize')

      var reject = makeBtnWithSuffix(
        'Reject',
        'all cookies',
        'cb-btn cb-btn-secondary',
        function () {
          onSave(REJECT_ALL)
        },
      )
      reject.setAttribute('data-testid', 'consent-reject')

      var accept = makeBtnWithSuffix('Accept', 'all cookies', 'cb-btn cb-btn-primary', function () {
        onSave(ACCEPT_ALL)
      })
      accept.setAttribute('data-testid', 'consent-accept')

      btns.appendChild(customize)
      btns.appendChild(reject)
      btns.appendChild(accept)
      parent.appendChild(btns)
    }

    function renderCustomizeView(parent) {
      var desc = document.createElement('p')
      desc.className = 'cb-desc'
      desc.textContent =
        'Our website uses cookies to distinguish you from other users of our website. This ' +
        'helps us provide you with a more personalized experience when you browse our website ' +
        'and also allows us to improve our site. Cookies may collect information that is used ' +
        'to tailor ads shown to you on our website and other websites. The information might be ' +
        'about you, your preferences or your device. The information does not usually directly ' +
        'identify you, but it can give you a more personalized web experience. You can choose ' +
        'not to allow some types of cookies.'
      parent.appendChild(desc)

      var form = document.createElement('form')
      form.className = 'cb-form'

      form.appendChild(
        makeOption('Necessary', 'Enables security and basic functionality.', true, true),
      )
      form.appendChild(
        makeOption(
          'Analytics',
          'Enables tracking of site performance.',
          analyticsOn,
          false,
          function (v) {
            analyticsOn = v
          },
        ),
      )
      form.appendChild(
        makeOption(
          'Marketing',
          'Enables ads personalization and tracking.',
          marketingOn,
          false,
          function (v) {
            marketingOn = v
          },
        ),
      )

      parent.appendChild(form)

      var save = makeBtn('Save preferences', 'cb-btn cb-btn-primary cb-save', function () {
        onSave({analytics: analyticsOn, marketing: marketingOn})
      })
      save.setAttribute('data-testid', 'consent-save')
      parent.appendChild(save)
    }

    function makeBtn(text, className, onClick) {
      var btn = document.createElement('button')
      btn.type = 'button'
      btn.className = className
      btn.textContent = text
      btn.addEventListener('click', onClick)
      return btn
    }

    // Matches React ConsentBanner: short label visible on all screens,
    // suffix hidden on mobile via .cb-mobile-hidden to prevent overflow
    // in the 3-column grid.
    function makeBtnWithSuffix(label, suffix, className, onClick) {
      var btn = document.createElement('button')
      btn.type = 'button'
      btn.className = className
      btn.appendChild(document.createTextNode(label))
      var span = document.createElement('span')
      span.className = 'cb-mobile-hidden'
      span.textContent = suffix
      btn.appendChild(span)
      btn.addEventListener('click', onClick)
      return btn
    }

    function makeOption(name, description, checked, required, onChange) {
      var label = document.createElement('label')
      label.className = 'cb-option'
      label.setAttribute('data-testid', 'consent-option-' + name.toLowerCase())

      var info = document.createElement('div')
      var h = document.createElement('h6')
      h.className = 'cb-option-title'
      h.textContent = name
      var p = document.createElement('p')
      p.className = 'cb-option-desc'
      p.textContent = description
      info.appendChild(h)
      info.appendChild(p)

      var sw = document.createElement('div')
      sw.className = 'cb-switch-wrap'

      var status = document.createElement('span')
      status.className = 'cb-status'
      status.textContent = required ? 'Required' : checked ? 'On' : 'Off'

      var toggle = document.createElement('span')
      toggle.className = 'cb-toggle'

      var input = document.createElement('input')
      input.type = 'checkbox'
      input.name = name
      input.checked = required || checked
      input.disabled = !!required
      input.addEventListener('change', function () {
        if (!required && onChange) {
          onChange(input.checked)
          status.textContent = input.checked ? 'On' : 'Off'
        }
      })

      var track = document.createElement('span')
      track.className = 'cb-track'

      toggle.appendChild(input)
      toggle.appendChild(track)
      sw.appendChild(status)
      sw.appendChild(toggle)

      label.appendChild(info)
      label.appendChild(sw)
      return label
    }

    // Escape key → reject all (matches React ConsentBanner behavior).
    // We intercept Escape and preventDefault to save reject-all preferences
    // instead of letting <dialog>'s built-in close() just dismiss without saving.
    function onKeyDown(e) {
      if (e.key === 'Escape' && dialog.open) {
        e.preventDefault()
        onSave(REJECT_ALL)
      }
    }

    // Wait for CSS to load before showing to avoid a flash of unstyled content.
    injectStyles(function () {
      if (closed) return
      ready = true
      render()
      document.body.appendChild(dialog)
      // show() (not showModal) — no backdrop or focus trap, so users can still
      // interact with the page while the banner is visible.
      dialog.show()
      document.addEventListener('keydown', onKeyDown)
    })

    return {
      close: function () {
        closed = true
        dialog.close()
        dialog.remove()
        document.removeEventListener('keydown', onKeyDown)
      },
      reopen: function () {
        if (!ready) return
        var current = getInitialPreferences()
        simpleView = true
        analyticsOn = current.analytics
        marketingOn = current.marketing
        render()
        if (!dialog.parentNode) document.body.appendChild(dialog)
        dialog.show()
      },
    }
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  var bannerInstance = null

  function init() {
    // GPC takes absolute precedence
    if (isGPCEnabled()) {
      savePreferences(REJECT_ALL)
      return
    }

    var prefs = getInitialPreferences()
    applyPreferences(prefs)

    var cookieExists = hasCookie(COOKIE_KEY)

    function handleSave(newPrefs) {
      savePreferences(newPrefs)
      if (bannerInstance) {
        bannerInstance.close()
        bannerInstance = null
      }
    }

    function showBanner() {
      if (bannerInstance) {
        bannerInstance.reopen()
      } else {
        var current = getInitialPreferences()
        bannerInstance = createBanner(current, handleSave)
      }
    }

    // Show banner if cookie not set AND user is in a consent-required country
    if (!cookieExists && requiresExplicitConsent()) {
      showBanner()
    }

    // Listen for re-open event (from footer "Privacy choices" link)
    window.addEventListener(SHOW_EVENT, showBanner)

    // Support [data-consent-reopen] attribute and links/buttons with "Privacy choices" text.
    // Use capturing phase so preventDefault() fires before target="_blank" navigation.
    document.addEventListener(
      'click',
      function (e) {
        var target = e.target
        while (target && target !== document) {
          if (target.hasAttribute && target.hasAttribute('data-consent-reopen')) {
            e.preventDefault()
            showBanner()
            return
          }
          // Match footer links/buttons whose text says "Privacy choices" (case-insensitive)
          var tag = target.tagName
          if (tag === 'A' || tag === 'BUTTON') {
            var text = (target.textContent || '').trim().toLowerCase()
            if (text.indexOf('privacy choices') !== -1) {
              e.preventDefault()
              showBanner()
              return
            }
          }
          target = target.parentNode
        }
      },
      true,
    )
  }

  // Run on DOMContentLoaded or immediately if already loaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init)
  } else {
    init()
  }
})()
