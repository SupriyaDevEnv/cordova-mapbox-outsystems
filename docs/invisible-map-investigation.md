# Invisible native map investigation

## Build timeline

The reported mobile binary was generated October 13, 2026. If it used main at
that time, the latest commit was `b7ed11a` (October 12). Confirm the actual pinned
ref in OutSystems; the build date alone does not establish its source revision.

- Automatic Android touch tracking: `4c63635` (September 24); iOS: `017b760`
  (September 28). These discover DOM rectangles and route gestures; they do not
  clear page backgrounds. Initialization also stops the external legacy bridge.
  Inspect that application's legacy `stop()` implementation for appearance side
  effects; it is not included in this repository.
- iOS behind-WebView frame conversion: `b9f244d` (September 30).
- Cleanup and Android WebView reparenting: `751e238` / main merge `3f8ab86`
  (October 16). These cannot be the native code in an October 13 binary.
- Android onStart/onPause/onResume calls already exist in `b7ed11a`; no evidence
  in the supplied log establishes a lifecycle failure.

## Confirmed newer regression and fix

The October 16 change replaced `WebView.setBackgroundColor(TRANSPARENT)` with
`View.setBackground(ColorDrawable(TRANSPARENT))`. Android's WebView overrides
setBackgroundColor to call its browser provider. A drawable alone does not clear
the browser surface, so it can hide a native map inserted underneath even after
the Mapbox style loads.

Restore the provider call, preserve a separate original drawable, and restore
the color on close while retaining the external-change ownership guard. Use the
original ColorDrawable color when available, otherwise Cordova's configured
BackgroundColor (default white). WebView exposes no public getter for arbitrary
provider-only color changes made by another plugin.

Reference: https://github.com/aosp-mirror/platform_frameworks_base/blob/master/core/java/android/webkit/WebView.java

This is a fix for the newer code, **not a confirmed explanation of the October
13 binary**. iOS already clears isOpaque, backgroundColor and scrollView's
background; changing its rendering path without reproduction is unwarranted.

## What the supplied log establishes

CSS width 392 times DPR 2.75 is 1078 pixels. CSS height 839 times DPR is 2307.25;
the reported native height 2142 plus top offset 165 is 2307. The bottom therefore
matches, but these logged calculations do not measure the actual laid-out native
view, GPU output, or occlusion by the WebView.

Android initialization resolves from the style-load callback. iOS resolves after
view setup. Neither means a visible map frame. The OutSystems tabs and
aria-hidden warnings do not identify a Mapbox rendering failure.

## Reproduction and device validation still required

Use the same options, token and style on both platforms. Record the installed
plugin ref and initialization arguments (without tokens).

1. On a test screen initialize with `behindWebView: false`. If this displays the
   map but behindWebView does not, investigate composition and page coverage.
   If neither displays, collect Mapbox loading/render errors and native layout
   measurements before changing CSS. Reinitialize between cases.
2. In behind-WebView mode inspect computed backgrounds and background images of
   html, body, the map placeholder and every covering OutSystems layout element.
   Native transparency cannot erase opaque HTML content. Clear only the map
   screen's covering backgrounds, preserving controls, sheets and popup panels.
3. Compare with the app's external legacy bridge disabled and inspect its stop
   function. Rectangle routing can disable gestures without hiding map pixels.
4. Verify first open, three close/reopen cycles, navigation away/back, background
   and foreground, rotation, pan/pinch, marker taps, and sheet/tab interactions.
   Verify the ordinary page background is restored after close.
5. On Android capture native view bounds and a screenshot; on iOS verify the map
   and overlay frames after coordinate conversion. Observe a rendered-frame
   event as well as style readiness; even a frame event alone cannot prove that
   the map is unobscured.

The isolated Java contract regression distinguishes the browser background from
the View drawable and exercises restoration. Existing Swift geometry/session
hosts and source parsing guard iOS behavior. These are not full SDK builds or
physical-device rendering tests. The consuming app, its CSS, installed binary,
Mapbox credentials and device session were not available during this review.
