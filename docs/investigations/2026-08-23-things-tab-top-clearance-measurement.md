# Things (Context) tab top-clearance measurement

Measurement-only QA run: no app code or test changes. Verdict: **H1** - the
Home-minus-Reminders difference is a CSS Intro-vs-Heading difference, not a
native safe-area bug on the pushed `HomeBrowserPageView`.

## Environment

| Item | Value |
| --- | --- |
| Device | iPhone 17 Pro Simulator (UDID 88B7BD58-6A92-4974-B5A3-6FE231CEC26D) |
| iOS runtime | iOS 26.0 |
| Host | macOS 26.3.1, Xcode 26.3 (pinned by `Scripts/outpost-bootstrap.sh`) |
| Scheme / config | `Convos (Dev)`, `-configuration Dev -derivedDataPath .derivedData` |
| Bundle id | `org.convos.ios-preview` |
| Logical screen | 402 x 874 pt, scale 3.0 (screenshots 1206 x 2622 px) |
| Nominal safe-area-inset-top | 62 pt (iPhone 17 Pro portrait; confirmed from the toolbar capsule row's accessibility frame, see below) |
| Space state | real provisioned Space: "Welcome home" grid with populated Notes / Members / Events / Reminders widgets (not the preparing/placeholder state) |

## Method

Pixel measurement from full-resolution (3x) simulator screenshots; all values
converted to points by dividing by the screen scale. Safari Web Inspector was
attempted but is not automatable on this outpost: driving Safari's Develop menu
requires System Events accessibility automation, which times out
(`AppleEvent timed out. (-1712)`) because the outpost has no accessibility grant
and no interactive Safari session. So the runtime `env(safe-area-inset-top)` and
`WKWebView.scrollView.contentInset.top` were not read directly; screenshot pixel
measurement is the baseline, per the brief.

Edges were located by luminance transition at the horizontal centre of the
selected segment pill (the pill renders pure white over the page's near-white
gradient) and by the first row containing content-coloured glyph pixels below
the pill.

## Per-screen measurements

| Screen | Segmented control bottom Y (pt) | First content glyph top Y (pt) | Gap = content-top - control-bottom (pt) |
| --- | --- | --- | --- |
| Things home grid (`HomeLayoutView`) | 153.00 | 256.33 ("Welcome home") | **103.33** |
| Reminders page (`HomeBrowserPageView`, pushed) | 153.00 | 232.67 ("Reminders") | **79.67** |

**Home - Reminders delta = 23.67 pt (~24 pt).**

The segmented control sits at exactly the same Y on both screens: the white pill
spans 123.00-153.00 pt, matching the accessibility frame of
`conversation-tab-context` (y = 123, height = 30) exactly.

The 62 pt safe-area-inset-top is not derived from the pill; it is read
independently from the accessibility tree: the toolbar capsule row
(`conversation-toolbar-button`) has frame y = 62, height = 52, and the capsule
row is laid out flush to the top safe area with height
`ConversationChromeMetrics.capsuleRowHeight` = 52 - so inset = 62 pt, the nominal
value for iPhone 17 Pro in portrait.

The computed control rect is therefore
62 + 52 (`capsuleRowHeight`) + 8 (`capsuleControlSpacing`) = 122 pt top and
122 + 32 (`controlHeight`) = 154 pt bottom, i.e. 1 pt outside the measured
white-pill edge on each side (the capsule's antialiased/rounded edge is not pure
white, and the accessibility frame agrees with the measured 123-153). Using the
computed 154 pt instead of the measured 153.00 pt shifts both gaps down by
exactly 1 pt (102.33 and 78.67) and leaves the Home - Reminders delta unchanged
at 23.67 pt, so the verdict does not depend on which of the two edges is used.

## Verdict: H1

The delta is 23.67 pt, i.e. ~24 pt, exactly the predicted difference between the
Space Home page's Intro block (24 px top padding) and the Reminders page's
Heading (0 px top margin). Both surfaces place the segmented control identically
and both clear it, so the native top inset
(`proxy.safeAreaInsets.top + ConversationChromeMetrics.controlClearance` = 62 + 52
= 114 pt) is being applied consistently on the pushed page as well:

- Reminders: 114 (native inset) + 56 (page padding) = 170 pt content-box top;
  measured glyph top 232.67 pt, i.e. 62.67 pt of heading line-box/ascent lead.
- Home: 170 + 24 (Intro top padding) = 194 pt; measured glyph top 256.33 pt -
  the same 62.33 pt of lead.

There is no evidence of H2: `HomeBrowserPageView`'s `GeometryReader` safe-area
read is not wrong when nested in `HomeBrowserNavigationHost`'s
`UINavigationController`; the pushed page is neither under- nor over-cleared.
Nothing to fix natively. If the two Space screens should start at the same Y,
that is a Space CSS change (the Intro's 24 px top padding), not an iOS change.

## Follow-up: where the chrome scrim is drawn

`ConversationChromeScrim` (`Convos/Conversation Detail/ConversationTopChrome.swift`)
is a sibling layer above the page, not the chrome's `.background`, and its extent
is arithmetic rather than measured:

    scrimHeight = controlBottom + scrimRampLength = 153.00 + 113.00 = 266.00 pt

So it runs from y = 0 (it `ignoresSafeArea(edges: .top)`, i.e. under the status
bar), holds full strength down to the control bottom at 153.00 pt, then ramps
linearly to fully transparent over the next 113 pt.

Pixel check of the ramp's end, at 3x scale (266.00 pt = 798 px). Method: mean
luminance of the content-free left gutter (x = 6-40 px), scanned down until the
profile flattens onto the page's own settled background (245.0/255). Both screens
share an identical profile down to ~154 pt (the scrim's hold region) and then
diverge with their own page content:

| Screen | Predicted end | Flattens at | Delta |
| --- | ---: | ---: | ---: |
| Things home grid | 266.00 pt (798 px) | 264.00 pt (792 px) | -2.00 pt |
| Reminders page | 266.00 pt (798 px) | 265.33 pt (796 px) | -0.67 pt |

No mismatch: both land within 2 pt of the predicted 266 pt. The measurement
reads slightly early because the final few percent of a white tint over a
near-white page falls below 8-bit quantization, so the last sliver of the ramp is
not distinguishable from the settled background - a floor of the method, not
clipping. Notably the scrim is *not* stopping short the way the code comment's
historical "69 pt short" background-clipping note describes; the sibling-layer
form draws its full height.

Where each page's first content line sits on the ramp:

| Screen | First glyph top | Into ramp | Ramp position | Scrim still opaque |
| --- | ---: | ---: | ---: | ---: |
| Things home grid ("Welcome home") | 256.33 pt | 103.33 pt | 91% | ~9% |
| Reminders page ("Reminders") | 232.67 pt | 79.67 pt | 71% | ~29% |

Both pages therefore begin their first line *inside* the fade tail rather than
below it - Home 9.67 pt before the scrim ends, Reminders 33.33 pt before. This is
consistent with H1 and is by design: the ramp is deliberately longer than the
content clearance so the wash dies out over content instead of ending on a hard
edge. It does mean the Reminders heading is drawn under a ~29% wash where Home's
is under ~9%; if that reads as a tint difference between the two screens, the lever
is `scrimRampLength` or the Space's Intro padding, not the native inset.

## Evidence

Annotated screenshots (both the clearance measurement and the scrim bounds), raw
full-resolution screenshots, and per-screen recordings are attached to the pull
request as durable artifact links.
