# SwiftSparkyFitness

A native SwiftUI client for a self-hosted [SparkyFitness](https://github.com/CodeWithCJ/SparkyFitness)
server. It talks to the backend API directly, bypassing the web frontend.

> Personal project. It points at a backend you run yourself — there is no
> hosted service behind it.

## What's in it

- **Today** — a triple ring (calories / active energy / water), meal-grouped
  food list, macro totals, and inline water and weight cards.
- **Diary** — browse any past day, expand/collapse meals, swipe to delete,
  tap any entry to edit it in the same sheet that created it.
- **Food logging** — searches your own custom foods and
  [OpenFoodFacts](https://world.openfoodfacts.org) together, with a live
  gram-stepper that recomputes macros as you adjust the portion.
- **Body tracking** — weight and measurements, written as one check-in row
  per day.

Progress and Settings are placeholders.

## Requirements

- Xcode 27 / iOS 27 SDK
- A running SparkyFitness backend (Docker Compose file included)

## Running it

Start the backend:

```bash
cp .env.example .env     # then fill in your own secrets
docker compose up -d
```

Generate strong values for the secret fields, e.g. `openssl rand -hex 32`.

Then point the app at your server. Run it, open **Settings**, and enter your
server's address — use your machine's Bonjour hostname rather than its LAN IP,
since the IP changes on every DHCP renewal:

```bash
echo "http://$(scutil --get LocalHostName).local:3010"
```

The address is stored on the device, so it survives rebuilds and nothing is
hardcoded in source. For development you can skip the typing by setting a
`SERVER_URL` environment variable in your Xcode scheme.

Add that same origin to `SPARKY_FITNESS_EXTRA_TRUSTED_ORIGINS` in `.env`,
then recreate the container — note that `docker compose restart` does **not**
re-read `.env`:

```bash
docker compose up -d sparkyfitness-server
```

Open `SwiftSparkyFitness.xcodeproj` and run.

## Architecture

MVVM, no third-party dependencies.

```
Models/        Decodable API shapes
Services/      APIClient + APIClientProtocol (the only networking)
ViewModels/    @MainActor ObservableObjects, one per screen
Views/         grouped by feature (Auth/, Today/, Diary/, Shared/)
DesignSystem/  colour, type, spacing tokens and shared components
```

Session state rides on URLSession's cookie jar (the better-auth session
cookie) — no manual token handling. Any 401 posts a single notification so
expired sessions are handled in one place instead of each screen inventing
its own error.

## Notes

- [`PROGRESS.md`](PROGRESS.md) — architecture decisions, backend quirks found
  while building against the live server, and what isn't built yet.
- [`SIMULATOR_MCP.md`](SIMULATOR_MCP.md) — driving the iOS Simulator from a
  Claude Code session: the Xcode MCP bridge, interaction commands, text entry,
  and the gotchas that cost the most time.
- [`UI_UX_REVIEW.md`](UI_UX_REVIEW.md) — a simulator-driven UI/UX audit and
  the fixes applied from it (accessibility, motion, correctness).

## License

[MIT](LICENSE)
