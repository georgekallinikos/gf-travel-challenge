# GoFerry Travel Challenge v0.15

Mobile-first promotional game prototype published from `main` / root with GitHub Pages.

## Current experience

- Catch the Ferry arcade game.
- Two-player Travel Match with 8 playful, commercially useful questions.
- Unique invitation links and cross-device answer synchronization through Supabase.
- Optional email capture for a clearly labelled demo 5% coupon.
- Separate optional marketing consent.
- Animated compatibility result and full-screen confetti rain.
- Private live-data dashboard at `admin-demo.html`, protected by verified `@takt.gr` authentication and database Row Level Security.
- GoFerry app CTA click tracking.

## One-time database setup

Run `supabase-setup.sql` in the SQL Editor of Supabase project `vqkrhqmzmzbkbypnudha`.

For dashboard magic-link authentication, add this redirect URL in Supabase Authentication → URL Configuration:

`https://georgekallinikos.github.io/gf-travel-challenge/admin-demo.html`

Only the browser-safe Supabase publishable key is included in the website. No database password or secret key is stored in this repository.

## Prototype limitations

- `GOFERRY5` is a demo coupon; no real discount or coupon email is issued.
- App Store and Google Play links are not connected yet.
- Privacy text, retention schedule and final campaign terms require business/legal approval before production launch.
