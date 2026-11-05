# GoFerry Travel Challenge — implementation handoff (v0.9)

## What this prototype demonstrates

- Mobile-first hub with Catch the Ferry and Travel Match.
- Travel Match invitation happens before the host answers.
- Ten questions produce a compatibility score; commercial interpretations are never displayed to players.
- The host waits after submitting until all invited players complete their answers.
- Every score receives a positive result message and an app-download/prize-draw call to action.
- `admin-demo.html` is a private-dashboard design using sample data only.

## Production components still required

1. Authenticated API and database for groups, invitations, players, answers and completion state.
2. Realtime update or polling so the result appears only after every accepted invite is complete.
3. Transactional invitation delivery, abuse/rate limiting and expiry handling.
4. Private GoFerry staff authentication and role-based dashboard access.
5. Official App Store/Google Play links plus campaign/deep-link attribution.
6. Prize-draw rules, eligibility, dates, territory, privacy notice and consent wording approved before launch.

## Suggested data model

- `group`: id, host_player_id, expected_players, status, created_at, completed_at.
- `invitation`: id, group_id, channel, recipient_hash, status, sent_at, accepted_at, expires_at.
- `player`: id, group_id, email (optional until required), consent_version, consent_at.
- `answer`: player_id, question_version, question_key, choice_index, created_at.
- `result`: group_id, compatibility_score, calculated_at.
- `campaign_event`: player_id, event (`app_cta_click`, `store_open`, `app_registration`), timestamp, campaign_id.

Do not treat a store-link click as a verified prize entry. The reliable entry point is an app registration or authenticated app open attributed to the campaign link.

## Analytics dimensions represented by the questions

Destination, companions, travel season, trip length, onboard preference, vehicle, island-hopping intent, booking channel, booking lead time and booking motivator.

## Current demo limitations

GitHub Pages is static. The live prototype stores demo answers only in the current browser. It does not collect real customer data, send invitations from GoFerry, create prize entries or authenticate the dashboard.
