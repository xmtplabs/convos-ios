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

## Evidence

Annotated screenshots, raw full-resolution screenshots, and per-screen
recordings are attached to the pull request as durable artifact links.
