# Connection artwork

Created for the September 2026 redesign with the built-in `image_gen` tool,
using the user's dark-theme references. No image API scripts were used.

Saved project assets:

- `globe.png`: cobalt network globe, 1672 × 941.
- `armenia-map.png`: regional map with violet Armenia outline, 1254 × 1254.
- `orb.png`: glossy purple glass sphere with a transparent background,
  1254 × 1254, RGBA.

Generation briefs (summarized):

1. Recreate the reference's luminous cobalt global network Earth on deep navy;
   remove all interface elements, text, buttons and the central sphere.
2. Create the connected-state regional map in the same navy and electric-blue
   style; illuminate Armenia's outline in violet near the upper right portion,
   leave space for the central sphere and fade the lower region into navy.
   No text, labels or interface elements.
3. Create an isolated glossy violet glass sphere matching the reference,
   with a bright specular highlight and purple caustics. Genuine transparent
   background; no icon, rings, text or controls.

Both application themes use these exact files and the same positioning.
`ConnectionArt.lightPalette` recolors the map at render time. The map is a
decorative illustration, not a navigation or geographic data source.
Flags, map labels, power/shield icons and orbital decorations are drawn in
Flutter. Only the server screen uses map artwork.

The orb moves with periodic harmonics over 24 seconds. Every harmonic has an
integer frequency, so both position and velocity match at the loop boundary.
Reduced-motion preferences stop the decorative animation.

Visual review: from `apps/desktop`, run
`flutter test test/app_test.dart --dart-define=KENAI_CAPTURE_UI=true` on Windows.
It captures all four connection states and the other main pages in both themes
under `output/ui-review`. Captures use mock dependencies and never create a VPN
tunnel. The screenshots use Segoe UI and the Flutter Material icon font.
