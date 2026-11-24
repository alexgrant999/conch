Conch site design kit

The landing page at conch.alexandergrant.app. One page, static, built from index.html and src/styles.css. Tokens live in the @theme block of src/styles.css and nowhere else.

Scene

A developer at a Mac with a dark terminal and several Claude Code sessions open, arriving from a search or a link, who wants to see the app and copy the install command in under a minute. Dark is the default because the page sits next to their terminal. Light comes from prefers-color-scheme.

Colour

Restrained. Tinted neutrals plus one accent.
Neutrals are tinted toward hue 285, the cool grey of the app icon.
The accent is the Claude orange the app uses for its caret and its waiting dot (#D97757, darkened in light mode so text passes 4.5 to 1).
Green (done) is only for the finished check mark, never for text.
Tokens: canvas, raised, key, line, ink, muted, accent, done. Tailwind's default palette is switched off, so any other colour class produces nothing.

What may be loud

One thing per view. The H1 in the hero, the "Waiting for you" row in the status section, the screenshots elsewhere. The orange stays under a tenth of any screen: the $ prompt, the waiting dot and row, focus rings, link underline on hover.

Type

The Mac system font (SF Pro) and SF Mono, through the system stacks. No web fonts, so nothing to download and the page reads like the app.
Scale: display (36 to 68px), title (28 to 42px), lede (19 to 23px), heading 20px, body 17px, small 15px. Nothing smaller than 15px.
Mono only for the install command and the claude CLI name. Keyboard shortcuts are kbd keycaps in the sans face, written Cmd+J to match the README.

Shape

Three radii: window 12px for the cropped Quick Open detail, control 8px for the command block and the waiting row, key 5px for keycaps. Hairline borders in line. No CSS shadows, no gradients, no blur. The only shadow on the page is the real macOS window shadow inside the screenshots.

Screenshots

Both are 2944 x 1844 PNGs with alpha: the window with its own macOS shadow on a transparent background, the window itself 2720 x 1620 and inset 112px left and right, 70px at the top and 154px at the bottom.
The hero is shown whole, with no border or radius. Negative margins (w-[108.24%], -mx-[4.12%], -mt-[2.57%], -mb-[5.66%]) make the img's layout box equal the window, so the window edge lines up with the text column and the shadow spills into the page padding. main clips horizontal overflow for the widths where the shadow passes the viewport edge.
Quick Open is shown as a 16:9 crop around the palette (source x 720 to 2260 from y 70), because the whole window at column width makes the palette text about 6px. The crop sits in a rounded-window box with a ring.
If a screenshot is replaced with one framed differently, recompute those percentages. The build writes the new pixel size into the img tags by itself.
Link previews use media/og.png, which the build makes from hero.png on the dark canvas colour at 1200 x 630.

Layout

12 column grid inside a 76rem page width, left aligned. Sections alternate canvas and raised bands and change column count, density and headline size from one to the next. The hero screenshot runs the full page width. The Quick Open detail sits left with its text as a caption to the right on wide screens.

Motion

Only the working spinner turns, and it stops under prefers-reduced-motion.

Accessibility floors

4.5 to 1 for text, 3 to 1 for status marks and focus rings, checked in both schemes. 44px minimum tap targets outside running text. Status is always a word next to the glyph, never colour alone. The copy button only appears when JS runs, and its result is announced through a polite live region.

Banned

Gradients, gradient text, glass, glow, card grids with icons, stats, testimonials, pricing, coloured eyebrow labels, fade-up on load, a third font, em dashes and en dashes, semicolons in copy.
