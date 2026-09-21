# SwiftSparkyFitness — UI/UX Polish Review

**Goal:** take the app from *functional* → *polished* → *premium, production-quality iOS*.
**Date:** 2026-09-21 · **Device:** iPhone 17, iOS 27.0, 402×874pt · **Build:** `drj.SwiftSparkyFitness` (Debug)

This is a refinement review, **not** a redesign. The serif + cream + magenta identity is deliberate and good; everything below extends it rather than replacing it.

---

## How this was produced

Driven through the **Xcode MCP simulator** (`DeviceInteractionSynthesize`), interacting with the installed app as a real user: logged in, logged food, adjusted water, exceeded a goal, browsed past days, opened every sheet, triggered validation errors, killed the backend mid-session, and re-ran Today at accessibility-XXXL and in dark mode. ~85 screenshots plus the matching accessibility hierarchies (exact `{{x,y},{w,h}}` frames for every element) were captured.

A realistic day was seeded via the API first (7 foods across 3 meals, 1,022 kcal, water, a weight check-in) because every screen is misleading when empty.

Three specialist reviewers then worked over those artifacts and the source in parallel — one on visual design, one on motion/haptics/micro-interactions, one on IA/screen-states/accessibility. Their findings are merged and de-duplicated here.

### Confidence note

Every claim below was verified, most of them twice. Specifically:

- **Frames over eyeballs.** Overlap, alignment and tap-target claims come from the accessibility dumps, not from looking at screenshots.
- **Live over inferred.** The tab-state loss, the wrong meal chip, the missing scroll-to-top, the over-goal water bar and the login lockout were each reproduced by hand in the simulator, not deduced from code.
- **Two findings were investigated and discarded**, rather than shipped as bugs:
  - An apparent "meal totals don't match the ring" turned out to be an artifact of how I seeded data (the app pre-scales nutrition on write; my seed omitted those fields). The *real* related bug is narrower and is filed as **P0-5**.
  - A claim that the tab bar has "no clearance from the home indicator" is **wrong** — the buttons end at y=840.3 and the bottom safe area is 34pt, so they sit exactly on the boundary. Correct as built.

---

## Priority summary

| # | Finding | Sev |
|---|---|---|
| P0-1 | With no calorie goal set, the app cannot log anything, anywhere | P0 |
| P0-2 | Dynamic Type does nothing — layout is pixel-identical at accessibility-XXXL | P0 |
| P0-3 | The FAB completely covers the Dinner "+" button | P0 |
| P0-4 | The hero ring and macro tiles are invisible to VoiceOver | P0 |
| P0-5 | Hero ring disagrees with the meal list for any part-portion entry | P0 |
| P0-6 | Changing the server host locks existing installs out of login | P0 |
| P1-1 | Zero animation in the entire codebase | P1 |
| P1-2 | Switching tabs destroys state and silently resets the Diary date | P1 |
| P1-3 | Content scrolls under the status bar with no scroll-edge treatment | P1 |
| P1-4 | There is no over-goal state — being over looks like being on target | P1 |
| P1-5 | Diary can browse and edit a past day but cannot add to it | P1 |
| P1-6 | Log Food opens to 259pt of nothing, with recents already available | P1 |
| P1-7 | A meal's "+" ignores which meal you tapped | P1 |
| P1-8 | Two different text-field styles alternate down a single form | P1 |
| P1-9 | Six sheets, six header patterns; titles mis-centred by up to 6pt | P1 |
| P1-10 | Contrast: a third of the app's quiet text sits at 2.24:1 | P1 |
| P1-11 | Eight controls below the 44×44pt minimum | P1 |
| P1-12 | Tab bar has no selected state for VoiceOver and leaks symbol names | P1 |
| P1-13 | Once data is on screen, every later failure is invisible | P1 |
| P1-14 | Two Save buttons ignore `isSaving` — double-tap writes twice | P1 |
| P1-15 | Emoji used as interface icons in an SF Symbols app | P1 |
| P1-16 | Section headers misaligned from the content they label | P1 |
| P1-17 | No press feedback on the most-tapped controls | P1 |
| P1-18 | Water "+" haptic fires after the network round-trip | P1 |
| P2 | Type scale, radius tokens, unit typography, login layout, and 12 more | P2 |

---

# P0 — fix first

## P0-1 · With no calorie goal set, the app cannot log anything, anywhere

**What is wrong.** `Views/Today/TodayView.swift` gates the entire screen on `hasGoalSet`:

```swift
if !viewModel.hasGoalSet {
    GoalNotSetCard()            // ← and nothing else. No statRow(), no meals.
} else {
    …
    statRow()                   // water + weight cards live in here
}
…
if viewModel.hasGoalSet {
    LogFAB { … }                // ← the FAB is gated too
}
```

So a goal-less account sees one card whose only button is an explicit no-op (`// ponytail: goal-setting screen is a later module`). Diary has no add path, and Progress/Settings are placeholders. There is no way to log food, water, weight or exercise **anywhere in the app**.

The irony: three lines above, a comment states the exact principle that was missed — *"Water and weight … render in both states, otherwise there'd be no way to log water on a day with nothing else on it."*

**Why it matters.** `PROGRESS.md` documents the no-op button as a known omission, but not this combination. A new account lands in a state where the app is a single inert button. It is the one deliberate gap that genuinely strands a user.

**Recommended improvement.** Move `statRow()` and `LogFAB` outside the gate so logging always works, and make the button honest.

**How it could be implemented.**

```swift
if !viewModel.hasGoalSet {
    GoalNotSetCard { showsGoalNotice = true }
} else if viewModel.hasLoggedAnything {
    populated(summary)
} else {
    firstRun(summary)
}
statRow()                        // always
// …and delete the `if viewModel.hasGoalSet` wrapper around LogFAB
```

For the interim, copy the pattern `LoginView` already uses for Forgot Password:

```swift
.alert("Goal setting isn't available yet", isPresented: $showsGoalNotice) {
    Button("OK", role: .cancel) {}
} message: {
    Text("You can still log food, water and weight — your ring fills in once a goal is set.")
}
```

**Expected UX benefit.** A goal-less account becomes a usable app instead of a brick, and a button that can't work says so.

---

## P0-2 · Dynamic Type does nothing

**What is wrong.** `DesignSystem/AppFont.swift` is the whole type system, and both functions return **fixed-point** fonts:

```swift
static func display(_ size: CGFloat, …) -> Font { .system(size: size, …, design: .serif) }
static func body(_ size: CGFloat, …)    -> Font { .system(size: size, …, design: .default) }
```

`Font.system(size:)` does not participate in Dynamic Type — that requires `Font.system(_ textStyle:)` or `Font.custom(_:size:relativeTo:)`. Every call site in the app goes through these two.

Verified two ways: `01_launch.png` and `13_ax3xl.png` (accessibility-extra-extra-extra-large) are **pixel-identical**, and diffing the accessibility dumps shows every text element's height unchanged — `'Protein'` is `{37.3, 13.3}` at both default and accessibility-XXXL. The app's smallest text, `0 eaten`, is a 10pt font that stays 10pt forever. `@ScaledMetric` appears zero times, so fixed frames don't scale either.

**Why it matters.** Far more people enlarge text than use VoiceOver; it is *the* standard low-vision accommodation. A nutrition app whose numbers are 10–13pt and cannot grow is unusable for a meaningful share of its audience.

**How it could be implemented.** Map sizes to semantic styles — every existing call site keeps compiling:

```swift
enum AppFont {
    private static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<12.5: return .caption
        case ..<13.5: return .footnote
        case ..<15.5: return .subheadline
        case ..<16.5: return .body
        case ..<18.5: return .headline
        case ..<21:   return .title3
        case ..<26:   return .title2
        default:      return .largeTitle
        }
    }
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(style(for: size), design: .serif).weight(weight)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(style(for: size), design: .default).weight(weight)
    }
}
```

Expect real fallout at large sizes — the three-column macro row, the four meal chips in one `HStack`, and the three intensity chips will all overflow. Handle with `ViewThatFits` or a vertical stack above `.accessibility1`, **then** clamp with `.dynamicTypeSize(...DynamicTypeSize.accessibility3)`. Sweep fixed frames with `@ScaledMetric`.

If real Newsreader/Work Sans `.ttf`s ever land, the scaling form is `Font.custom("Newsreader", size: size, relativeTo: style(for: size))` — without `relativeTo:` custom fonts are just as frozen.

**Expected UX benefit.** The app becomes legible to low-vision users; today it categorically is not.

---

## P0-3 · The FAB completely covers the Dinner "+" button

**What is wrong.** Measured frames on Today:

| Element | Frame | x-range | y-range |
|---|---|---|---|
| FAB | `{{326.0, 717.0}, {56.0, 56.0}}` | 326–382 | 717–773 |
| Dinner "+" | `{{362.0, 715.7}, {20.0, 20.0}}` | 362–382 | 715.7–735.7 |

The Dinner "+" is **entirely inside** the FAB's bounds, and the FAB is drawn later (it is a sibling of the `ScrollView`, not inside it). It is completely untappable. The FAB also overlaps `+ Measurements` (`{{269.7, 717.0}, {98.3, 14.3}}`, right edge 368) and sits on the Weight card. Visible in `30_today_real.png`, `32_today_bot.png` and `60_dark_today.png`.

**Why it matters.** A functioning control is permanently unreachable, and the FAB visually collides with the last card on every scroll.

**Recommended improvement.** Reserve space for the FAB at the bottom of the scroll content, and — per **P1-7** — give the section "+" buttons a real purpose so the collision matters less.

**How it could be implemented.** Add bottom padding to the scroll content equal to the FAB's footprint:

```swift
.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
```

on the `ScrollView` in `TodayView`. If the FAB becomes a `Menu` (**P1-1 / step-count**), the same inset still applies.

**Expected UX benefit.** Every control on Today becomes reachable, and the last card stops being obscured.

---

## P0-4 · The hero ring and macro tiles are invisible to VoiceOver

**What is wrong.** `DesignSystem/RingChart.swift` is three `Circle().trim(…)` strokes with no accessibility treatment. VoiceOver's entire experience of the app's primary display is six loose static texts:

```
'978' · 'kcal left' · '1,022 eaten' · 'Calories' · 'Active energy' · 'Water'
```

The three progress values are conveyed by **arc length and colour only** and are completely unavailable. Colour is also the sole link between the legend word "Water" and the blue arc, so the ring fails for colour-blind users too, not just VoiceOver users.

Macro tiles have the same defect: `'82g'` and `'Protein'` are separate elements — six swipes for three numbers, value before label. Same for the water card's hand-drawn progress bar, which emits nothing.

**How it could be implemented.** Collapse each composite into one labelled, valued element. On `RingChart`'s outer `ZStack`:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel("Daily progress")
.accessibilityValue(accessibilityValue)   // passed in from DailySummaryCard
```

built from numbers already in hand:

> "1,022 of 2,000 calories eaten, 978 remaining. Active energy 0 of 300. Water 1,250 of 2,000 millilitres, 63 percent."

Then `.accessibilityHidden(true)` on the legend so it isn't read twice. For macro columns: `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Protein")` + `.accessibilityValue("82 grams")`.

Independently, add a non-colour channel to the legend (inline numeric values — see **P2 · Ring legend**) so it survives colour-blindness.

**Expected UX benefit.** The dashboard becomes readable non-visually. Today, two thirds of it is silent.

---

## P0-5 · The hero ring disagrees with the meal list for any part-portion entry

**What is wrong.** Two different sources of truth for calories on one screen:

- `Views/Shared/DailySummaryCard.swift` — ring and centre number read `summary.calorieBalance.eaten` / `.remaining` (**server-computed**).
- `Views/Today/TodayView.swift` — section totals are `entries.reduce(0) { $0 + $1.calories }` and each row prints `entry.calories` (**client-computed**).

The app writes *pre-scaled* nutrition (`calories = variant.calories × quantity / baseServing`), then the server re-applies `quantity / serving_size` when computing `calorieBalance`. They agree only when the logged quantity happens to equal one base serving.

Verified with a controlled test — a food with a 100 g / 200 kcal base variant, logged at 50 g (truth: 100 kcal):

```
entry.calories returned by API : 100   ← meal list and section total show this  ✅
server calorieBalance.eaten    : 50    ← the hero ring shows this               ❌
```

`DailySummaryCard` is shared with Diary, so both screens have the split.

**Why it matters.** The largest number in the app is wrong for any non-standard portion — which is most real logging — and it visibly contradicts the list directly beneath it. It went unnoticed because verification used 1-serving logs, where the two happen to agree.

**Recommended improvement.** Derive the hero from the same entries the screen already renders, rather than from the server field. That makes the screen internally consistent and removes the dependency on an upstream quirk you don't control.

**How it could be implemented.** In `DailySummaryCard`, compute locally:

```swift
let eaten = summary.foodEntries.reduce(0) { $0 + $1.calories }
let remaining = summary.calorieBalance.goal - eaten + summary.calorieBalance.burned
```

Keep `.goal` and `.burned` from the server; only `eaten`/`remaining` need recomputing. (Worth reporting the double-scaling upstream too, but don't block on it.)

**Expected UX benefit.** Today stops contradicting itself, and the headline number becomes correct for every portion size.

---

## P0-6 · Changing the server host locks existing installs out of login

**What is wrong.** `APIClient.clearStaleCookies()` only deletes cookies whose domain matches the **current** `baseURL.host`:

```swift
guard let host = baseURL.host, … else { return }
for cookie in cookies where cookie.domain.contains(host) || host.contains(cookie.domain) { … }
```

After the switch from the LAN IP to `your-mac.local`, cookies from the old host survive and make the next sign-in fail with the raw backend string **"Missing or null Origin"** — the exact error this function exists to prevent.

Reproduced live: the app could not sign in at all; after `simctl uninstall` (which wipes the cookie jar) and reinstall, login succeeded first try.

**Why it matters.** It is unrecoverable from inside the app — there is no sign-out (**P2 · Settings**), and the error names a concept the user cannot act on. Anyone with the app already installed is simply locked out by a config change.

**How it could be implemented.** `baseURL` is the only thing that should own that jar, so sweep it all:

```swift
private func clearStaleCookies() {
    guard let storage = session.configuration.httpCookieStorage else { return }
    storage.cookies?.forEach(storage.deleteCookie)
}
```

Also map the raw message to something actionable, the way the other auth errors already are.

**Expected UX benefit.** Host changes stop bricking installs, and the one auth error that leaks server jargon stops leaking.

---

# P1 — clearly hurts polish

## P1-1 · Zero animation in the entire codebase

**What is wrong.** A full-repo grep for `withAnimation`, `.animation(`, `.transition(`, `matchedGeometryEffect`, `contentTransition`, `symbolEffect`, `phaseAnimator`, `keyframeAnimator` and `sensoryFeedback` returns **0 matches**. `@FocusState` also returns **0**. Deployment target is iOS 27, so nothing is gated on availability.

Every state change is a hard cut: the rings snap to full, numbers jump, Diary's section collapse is an instant vanish, login → app is a jump cut, rows appear and disappear without transition.

The haptics pass was done thoughtfully and shipped; the motion pass was never started. That asymmetry is most of why the app reads as developer-built despite good structure underneath.

**Highest-return fixes, in order:**

1. **Fill the rings.** `RingChart` uses `.trim`, which is free to animate — nothing drives it. Add to the trimmed `Circle`:
   ```swift
   .animation(.easeOut(duration: 0.85).delay(Double(index) * 0.08), value: layer.progress)
   ```
   Seed the first fill with `@State private var hasAppeared` and trim to `hasAppeared ? layer.progress : 0`. Use `.spring(response: 0.55, dampingFraction: 0.85)` for later changes so a change reads differently from an entrance. This is the single highest-return animation in a fitness app.

2. **Roll the digits.** `.contentTransition(.numericText())` is used nowhere. Best case is the food-portion stepper, where a 30pt calorie figure recomputes live and currently flickers on every tap. Also the ring centre (`.numericText(countsDown: true)` so "kcal left" visibly counts down), macro totals and the water total.

3. **Animate the disclosure.** `DiaryViewModel.toggleSection` mutates with no `withAnimation`; rows blink out. Wrap in `withAnimation(.snappy(duration: 0.28))`, rotate a single `chevron.down` instead of swapping symbols, and add `Haptics.selection()` — it's a hand-rolled disclosure control, exactly the category `Haptics.swift` already identifies as deserving one.

4. **Cross-fade auth → app** and slide login ↔ sign-up; give `ErrorBanner` a `.move(edge: .top).combined(with: .opacity)` entrance instead of popping in.

Guard all of it behind `@Environment(\.accessibilityReduceMotion)` at the point of introduction — there is nothing to reduce today, but there will be.

---

## P1-2 · Switching tabs destroys state and silently resets the Diary date

**What is wrong.** `MainTabView` selects content with a `switch` in a `@ViewBuilder`. Each branch is a distinct view identity, so switching tabs tears down the subtree, destroys the `@StateObject`, and re-fires `.task { await viewModel.load() }`.

**Verified live:** Diary on *Sun, Sep 20* → tap Today → tap Diary → back on *Mon, Sep 21*. The date, collapsed sections, water ledger and scroll position are all gone, and four requests re-fire each way.

**Also verified live:** re-tapping the already-active tab does nothing — scroll position stayed at 88%. Native `TabView` gives scroll-to-top for free; `AppTabBar` early-returns when `selection == tab`.

**Recommended improvement.** Move to a native `TabView` with `Tab` values (iOS 18+). It keeps each tab alive, which fixes the state loss and the redundant fetches as a side effect, and also buys the `.isSelected` VoiceOver trait (**P1-12**), scroll-to-top, keyboard traversal, and Dynamic Type in the bar.

**Honest migration cost.** You lose the ringed-circle glyph treatment — a native bar renders plain SF Symbols. If that ring is load-bearing for the brand, author a `.symbolset` containing ring+glyph and use `Tab(_:image:value:)`. Everything else in `TabBar.swift` deletes. Roughly half a day including the symbol work.

If the custom bar must survive a release, at minimum keep all four tabs alive in a `ZStack` gated by `.opacity`/`.allowsHitTesting`, or lift the view models to `MainTabView`.

---

## P1-3 · Content scrolls under the status bar with no scroll-edge treatment

**What is wrong.** Scrolled content passes behind the status bar and collides with the clock. Clearly visible in `02_today_scrolled.png` (the ring's "2,000" rendering through "9:38") and `32_today_bot.png` ("Sourdough Toast" behind "9:56"). There is no material, blur or fade at the top edge.

The bottom is fine — the `ScrollView` ends at y=791 where the tab bar begins, and the tab buttons sit exactly on the 34pt safe-area boundary. This is a **top-edge-only** problem.

**How it could be implemented.** The cheapest correct fix is to stop hand-rolling the screen header and let the system draw a scroll edge effect — wrap Today and Diary in a `NavigationStack` with an inline `.navigationTitle`. If the bespoke serif title must stay in the scroll content, add a top `safeAreaInset` carrying a `.ultraThinMaterial` strip sized to the status-bar inset, so content fades under a real material instead of colliding with glyphs.

---

## P1-4 · There is no over-goal state

**What is wrong.** Three independent clamps hide the single most important state a calorie tracker communicates:

```swift
Text("\(max(0, Int(summary.calorieBalance.remaining)))")   // DailySummaryCard
.trim(from: 0, to: max(0, min(1, layer.progress)))          // RingChart
min(totalMl / goalMl, 1)                                    // WaterViewModel
```

Eating 2,000 of a 2,000 kcal goal and eating 3,200 produce a **byte-identical card**: full magenta ring, `0`, `kcal left`.

**Verified live for water:** I tapped "+" up to **2250 / 2000 ml** and the bar simply pins at 100% in the same blue (`82_water_over.png`). Over goal is visually identical to hitting it exactly.

**How it could be implemented.** Branch the centre label on sign and stack an overshoot arc:

```swift
let remaining = summary.calorieBalance.remaining
Text("\(abs(Int(remaining)))")
    .foregroundStyle(remaining < 0 ? AppColor.destructive : AppColor.ink)
Text(remaining < 0 ? "kcal over" : "kcal left")
```
```swift
if layer.progress > 1 {
    Circle().trim(from: 0, to: min(layer.progress - 1, 1))
        .stroke(AppColor.destructive, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
}
```

Don't rely on colour alone — the text change carries it for colour-blind users, the `accessibilityValue` from **P0-4** for VoiceOver.

---

## P1-5 · Diary can browse and edit a past day but cannot add to it

**What is wrong.** `DiaryView` has no FAB and no per-section "+". Its sheets are all *edit existing*. The empty state says *"Switch to Today to log food, water, or exercise"* — but Today's logging always targets `Date()`.

The plumbing already exists: `FoodDetailViewModel.init` and `LogExerciseViewModel.init` both take an `entryDate`. Only the create UI is missing.

**How it could be implemented.** Wrap Diary's `List` in the same `ZStack(alignment: .bottomTrailing)` Today uses, reuse `LogFAB`, and pass `entryDate: viewModel.selectedDate` into the sheets.

**Expected UX benefit.** "I forgot to log yesterday's dinner" is the second-most-common task in any food tracker. It currently has no solution.

---

## P1-6 · Log Food opens to 259pt of nothing

**What is wrong.** Measured from `50_logfood.txt`: meal chips end at y=536, the footer starts at y=795.3 — **259pt of empty white** with two elements in it. The idle case is literally `case .idle: EmptyView()`.

Separately, `FoodSearchViewModel.isSearching` is `@Published`, is set and cleared — and **no view ever reads it**. So typing shows: blank → (350ms debounce + a two-source network round trip including OpenFoodFacts) → blank → results. On a slow link that is seconds of a screen that looks broken and identical to "no query yet".

And the data for a recents list already exists: `GET /api/foods` returns **`recentFoods`** and **`topFoods`** (confirmed live — this contradicts `PROGRESS.md`'s note that no recent-foods endpoint was verified).

**How it could be implemented.** Three distinct renderings for three distinct facts:

```swift
case .idle:
    if viewModel.isSearching {
        ProgressView().frame(maxWidth: .infinity).padding(.top, 48)
    } else if !viewModel.recentFoods.isEmpty {
        recentsSection(viewModel.recentFoods)          // one tap to re-log
    } else {
        ContentUnavailableView("Search for a food", systemImage: "magnifyingglass",
            description: Text("Or add your own with “Enter food manually”."))
    }
```

`ContentUnavailableView` (iOS 17+) brings correct VoiceOver grouping and Dynamic Type for free.

**Expected UX benefit.** The most frequent action in the app — re-logging something you eat often — drops from *type + wait + tap* to a single tap.

---

## P1-7 · A meal's "+" ignores which meal you tapped

**What is wrong.** Every meal-section "+" just sets `isPresentingFoodSearch = true`, passing no meal type. `FoodSearchViewModel` then picks the chip purely from the clock.

**Verified live:** at 10:13 PM I tapped the "+" beside **BREAKFAST** and the sheet opened with **Dinner** selected (`81_mealchip_check.png`).

**Why it matters.** The affordance promises a destination and silently substitutes another. Unless the user notices the chip row, the food is filed under the wrong meal.

**How it could be implemented.** Add `@Published var pendingMealType: MealType?` to `TodayViewModel`, set it from the section button, and have `FoodSearchViewModel.init` prefer it over the time-of-day fallback. Keep the heuristic for the FAB path — it's a genuinely good touch there.

---

## P1-8 · Two different text-field styles alternate down a single form

**What is wrong.** `CustomFoodView` and `LogExerciseView` each use two incompatible field components in adjacent rows:

- `AppTextField` — white fill, 1pt hairline border, radius 14, padding 16/14
- `plainField` — beige fill, no border, radius 12, padding 14/12 — **duplicated privately in both files**

`51_logex.png` makes it unmistakable: ACTIVITY is beige, DURATION directly under it is white-and-bordered, CALORIES BURNED is beige again. The frames quantify the stagger: `NAME` field text at x=40.6, `SERVING SIZE` field text at x=38.7, and the two styles differ ~6pt in height.

The read-only calories readout also uses the same beige as editable fields, so "is an input" and "is not an input" look identical.

**How it could be implemented.** One component with a style, and delete both `plainField` helpers:

```swift
struct AppTextField: View {
    enum Style { case filled, outlined }   // filled inside sheets, outlined on cream
    var style: Style = .filled
}
```

`LoginView`/`SignUpView` pass `.outlined` (correct there — they sit on cream); every sheet uses the default. Render the calories readout with no field background at all.

---

## P1-9 · Six sheets, six header patterns — and titles are mis-centred

**What is wrong.** Every sheet hand-builds an `HStack` header, and because they're `Cancel / Spacer / Title / Spacer / Save`, the spacers balance the *leftover* space, not the screen.

Measured in `51_logex.txt`: Cancel is 45.4pt wide, Save is 33.3pt, title centre lands at **207.05** against a sheet centre of **201.0** — **6.05pt off**, exactly `(45.4 − 33.3) / 2`.

Header heights differ too: Log Food's Cancel sits at y=424.3, Log Exercise's at y=430.4 — so the title visibly hops between sheets. `FoodDetailView`'s right-hand "Add" is a plain `Text` styled exactly like every real Save button, and does nothing. The date-picker sheet has no header or Cancel at all.

**How it could be implemented.** One `SheetHeader` using a `ZStack` so the title centres on the sheet:

```swift
ZStack {
    Text(title).font(AppFont.display(18))            // truly centred
    HStack {
        leading.frame(minWidth: 44, minHeight: 44, alignment: .leading)
        Spacer()
        trailing.frame(minWidth: 44, minHeight: 44, alignment: .trailing)
    }
}
```

The `minWidth: 44` also fixes those sheets' tap targets for free. Better still, move to `NavigationStack` + `.toolbar` with `.cancellationAction` / `.confirmationAction`, which adds heading traits and Dynamic Type — see the caveat in **P2 · Sheet architecture**.

---

## P1-10 · Contrast: a third of the app's quiet text sits at 2.24:1

**What is wrong.** Computed from the literal hex values in `AppColor.swift` (verified independently):

| Token | Hex | On white | Required |
|---|---|---|---|
| `placeholder` / `inactiveTab` | `B7ABA6` | **2.24 : 1** | 4.5 |
| `carbs` | `F5A623` | **2.03 : 1** | 4.5 |
| `energy` | `1FA98A` | **2.95 : 1** | 4.5 |
| `accent` | `E23573` | **4.21 : 1** | 4.5 |
| `secondaryText` | `6E6469` | 5.69 : 1 | ✅ |

`placeholder` carries `1,022 eaten` (10pt, inside the hero ring), `Not logged yet`, `RESULTS`, the search placeholder, and — via `inactiveTab` — **three of the four tab labels**. `carbs` and `energy` are the only tokens in the file with no light/dark pair; they were tuned for the dark surface at the cost of light mode, which is the default skin.

**How it could be implemented.** Split the two jobs currently sharing one token, and make the macro colours adaptive:

```swift
static let placeholder = Color.adaptive(light: Color(hex: "9A8D92"), dark: Color(hex: "8A7C82"))
static let inactiveTab = Color.adaptive(light: Color(hex: "8C7F84"), dark: Color(hex: "9A8C92"))
static let energy      = Color.adaptive(light: Color(hex: "13735E"), dark: Color(hex: "2FD3AC"))
static let carbs       = Color.adaptive(light: Color(hex: "9A6206"), dark: Color(hex: "F5A623"))
```

Keep the bright values for **ring arcs and legend marks** via `energyGraphic`/`carbsGraphic` aliases — large graphic marks don't need text contrast, and the chart should stay vibrant.

Also promote `1,022 eaten` from 10pt placeholder to 12pt `secondaryText`: it's the number the user actually logged, currently the smallest and faintest text in the app.

---

## P1-11 · Eight controls below the 44×44pt minimum

Measured from the hierarchy dumps — exact frames, not estimates:

| Control | Frame | Notes |
|---|---|---|
| Diary date chevrons ‹ › | **6.7 × 11.7** | ~4% of required area; primary nav on that screen |
| Sheet `Save` | **33.3 × 17.0** | |
| Sheet `Cancel` | **45.4 × 17.6** | |
| Meal "+" | **20 × 20** | ×4 on Today |
| `+ Measurements` | **98.3 × 14.3** | |
| `Log today's →` | **89 × 15.7** | |
| `Forgot password?` / `Create an account` | **113 × 15.7** | |
| Water ± | 38 × 38 | close |
| Tab buttons | 88.7 × **41.3** | fixed by `TabView` |

The date arrows are the worst, and they sit next to the date button — so a miss silently opens the date picker instead of changing day.

**How it could be implemented.** Pad the touch target, keep the glyph size:

```swift
Image(systemName: "chevron.left")
    .font(.system(size: 13, weight: .semibold))
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())
```

and reduce the surrounding `HStack(spacing: 14)` to `0` so the row doesn't spread. Sheet buttons are solved by **P1-9**; tab buttons by **P1-2**. Do this **after** the Dynamic Type work so you're padding final sizes.

---

## P1-12 · The tab bar has no selected state for VoiceOver, and leaks symbol names

**What is wrong.** From the dumps, in every capture:

```
Button, {{12.0, 799.0}, {88.7, 41.3}}, label: 'Today'
 Image, identifier: 'sunrise', label: 'Sunrise'
…
Button, label: 'Settings'
 Image, identifier: 'slider.horizontal.3', label: 'Edit'      ← announces "Edit"
```

1. **No `Selected` trait on any tab, in any capture** — including the one where that tab is active. The dumps *do* emit traits (Diary's forward chevron correctly shows `Disabled`), so this is a real gap.
2. **Inner images are their own a11y elements**, announcing SF Symbol default names: "Sunrise", "List", "Chart Line", and **"Edit"** for Settings.
3. No tab-bar container semantics, so there's no "Tab 1 of 4".

A VoiceOver user hears *"Sunrise… Today… List… Diary… Chart Line… Progress… Edit… Settings"* and cannot tell which tab they're on.

**How it could be implemented.** `TabView` (**P1-2**) fixes all three. If the custom bar must survive, patch it on the label's `VStack`:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(tab.label)
.accessibilityAddTraits(tab == selection ? [.isButton, .isSelected] : .isButton)
```

The same symbol-name leak affects the FAB menu ("Scale For Weighing Mass", "Ruler With Measurement Marks"), Diary's collapse chevrons ("Go Up"), and `ErrorBanner` ("Exclamation Mark In A Filled Circle") — all decorative, all want `.accessibilityHidden(true)`.

Also: Diary's date arrows are labelled **"Back"/"Forward"** (SF Symbol defaults implying navigation history) rather than "Previous day"/"Next day", and section headers carry no expanded/collapsed state.

**Visually**, the bar has its own problem: a 1.9pt `Circle().stroke` around an 11pt glyph means the ring out-weighs the icon, and the four glyphs render at visibly different densities inside identical rings (`sunrise` 15.3×13.0 vs `list.bullet` 11.3×8.3). Consider dropping the ring, using `.fill` variants for the selected state, and normalising to one optical box.

---

## P1-13 · Once data is on screen, every later failure is invisible

**What is wrong.** Both day screens render the error only in the `summary == nil` branch. But `errorMessage` is set on *every* failure — pull-to-refresh, a Diary day change, a post-save reload, and every delete. In all of those `summary != nil`, so the message is assigned and **never rendered**. The only feedback is `Haptics.error()`.

Worst case: you swipe to delete in Diary, the DELETE fails, the reload fails, and the row is still sitting there with no explanation. Or you page to a previous day, the fetch fails, and you're reading *yesterday's* numbers under *today's* date label.

**How it could be implemented.** Keep the cold-start state; add a persistent inline banner for the warm case:

```swift
.safeAreaInset(edge: .top) {
    if viewModel.summary != nil, let errorMessage = viewModel.errorMessage {
        ErrorBanner(message: errorMessage)
            .padding(.horizontal, AppSpacing.screenPad)
    }
}
```

and post `AccessibilityNotification.Announcement(errorMessage)` so non-visual users learn the refresh failed. `ErrorBanner` already exists — it just needs a second call site.

**Related:** the banner also doesn't clear on recovery. After the server came back, the stale *"Could not connect to the server."* was still on screen.

---

## P1-14 · Two Save buttons ignore `isSaving` — double-tap writes twice

**What is wrong.** `LogExerciseViewModel.isSaving` and `CustomFoodViewModel.isSaving` are `@Published` and **never referenced by any view**. `LogExerciseView`'s Save has no `.disabled` and no spinner, and its save makes *two sequential* network calls. On a slow link the button sits looking tappable for seconds.

This is not just a feel problem: a second tap writes a second exercise session / second custom food, unrecoverable without a manual delete.

`LogBodyView` and `FoodDetailView` already do this correctly — `FoodDetailView` passes `isLoading: viewModel.isSaving` to `PrimaryButton`, which already handles it.

**How it could be implemented.** Adopt the same pattern in the two stragglers, or move Save into a real toolbar (**P1-9**) where `.confirmationAction` gives correct emphasis.

---

## P1-15 · Emoji used as interface icons

**What is wrong.** Four emoji in an app that otherwise uses SF Symbols throughout (`fork.knife`, `figure.run`, `scalemass`, `ruler`, `magnifyingglass`, `wifi.slash`, …):

```
WaterCard.swift:35        Text("💧 Water")
FoodSearchView.swift:195  Text("🔎").font(.system(size: 36))
DiaryView.swift:166       Text("📭").font(.system(size: 36))
DiaryView.swift:353       Text("💧").font(.system(size: 16))
```

Apple Color Emoji is a full-colour, cartoon, **non-tintable** typeface. The 🔎 renders as a bright blue-and-white cartoon magnifier at 36pt above elegant serif copy. Emoji ignore `foregroundStyle`, so they don't adapt to dark mode and don't tint with the accent.

**How it could be implemented.** `drop.fill` in `AppColor.water`, `tray` and `magnifyingglass` in `AppColor.placeholder`. `SearchNetworkErrorView` already shows the right pattern — a tinted symbol inside a soft-filled 60pt circle. Apply that to all three empty states so they match.

---

## P1-16 · Section headers are misaligned from the content they label

**What is wrong.** Three left edges that should be one:

| Screen | Element | x |
|---|---|---|
| Today | `BREAKFAST · 296 KCAL` | **20.0** |
| Today | `Greek Yogurt, Plain` (row text) | **34.0** |
| Today | `Not logged yet` | **20.0** |
| Diary | `Breakfast · 296 kcal` header | **36.0** |
| Diary | `Greek Yogurt, Plain` | **34.0** |

So the header outdents 14pt from its content on Today and indents 2pt past it on Diary — the *same component* reading at x=20 on one tab and x=36 on the next. Trailing edges diverge too: Today's header "+" right-edges at 382 against a calorie column at 368.

**How it could be implemented.** One content-gutter token, used everywhere:

```swift
enum AppSpacing {
    static let screenPad: CGFloat = 20
    static let cardPad: CGFloat = 14        // currently 16 and used ZERO times
    static let contentInset: CGFloat = 34   // screenPad + cardPad
}
```

Wrap Today's header `HStack` in `.padding(.horizontal, AppSpacing.cardPad)`; on Diary replace `.padding(.horizontal, screenPad)` with `listRowInsets(EdgeInsets())` + `.padding(.horizontal, contentInset)`.

---

## P1-17 · No press feedback on the most-tapped controls

**What is wrong.** `.buttonStyle(.plain)` — which removes *all* press response — is applied to the water steppers, "Enter amount…", both BodyCard buttons, and Diary's date chevrons and section headers. Separately, `PrimaryButton` puts `.background`/`.clipShape` on the `Button` rather than the label, so the default style dims the text while the pink capsule stays lit — a half-pressed look. `LogFAB` has the same shape.

**How it could be implemented.** One shared style in `DesignSystem/`:

```swift
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
```

Apply to all eight `.plain` sites, `PrimaryButton` (`scale: 0.98`) and `LogFAB` (`scale: 0.92`).

**Expected UX benefit.** Every control acknowledges contact in under a frame, independent of the network — which currently nothing does.

---

## P1-18 · The water "+" haptic fires after the network round-trip

**What is wrong.** `WaterViewModel.adjust(drinks:)` sets `isBusy = true`, awaits the network call, and **then** fires `Haptics.light()`. The `+` is disabled for the whole round trip, and the total and bar then jump with no animation.

A stepper is the one control where the haptic *is* the acknowledgment; firing it hundreds of milliseconds late feels like a stutter. Tapping three glasses means three serialized round-trips with a dead button between them.

`FoodDetailView` gets this right — `Haptics.light()` fires synchronously in the button action — which proves the pattern is understood and just wasn't applied here.

**How it could be implemented.** Haptic on tap, optimistic number, reconcile on response:

```swift
Button {
    Haptics.light()                                   // immediate
    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { totalMl += mlPerDrink }
    Task { await viewModel.adjust(drinks: 1) }        // reconciles
} label: { … }
```

Replace the `isBusy` gate with in-flight coalescing (accumulate pending drinks, debounce ~400ms, send one call) so rapid taps work.

---

# P2 — refinement

**Type scale.** Fifteen distinct sizes — serif at 34/30/28/26/22/18/16 and sans at 20/16/15/14/13/12/11/10 — plus **20 raw `.system(size:)` calls** that bypass `AppFont` entirely. Seven sans sizes live inside a 6pt range; nobody can distinguish 14 from 15. Collapse to ~6 named roles (`hero`, `title`, `sheetTitle`, `stat`, `bodyM`, `bodyS`, `caption`), which also makes the Dynamic Type migration a six-line change instead of a sweep.

**The serif appears on exactly one number.** `AppFont.display` is applied to a numeral precisely once — the ring's `978`. Every other prominent number (`1250 / 2000 ml`, `73.4 kg`, `82g`, every row's calories) is system sans. The identity the brand rests on shows up on one glyph cluster and vanishes for the other ~40 numbers on the same screen. Promote the serif to card-level hero numbers; keep sans (with `.monospacedDigit()`) for tabular row figures.

**Unit typography — four treatments, one correct.** `BodyCard` composes `Text("73.4").bold + Text(" kg").secondary` so the unit recedes. That's right, and it's the only place that does it. Elsewhere: `1250 / 2000 ml` is all one weight, `82g` shouts, food rows show `170g` with no space and a bare `100` with **no unit at all**. Extract a shared `ValueUnit` view and use it everywhere; add the missing `kcal`.

**Radius and spacing tokens don't describe reality.** Actual usage: `14` ×14 (literal, no token), `AppRadius.md` ×11, `12` ×9 (literal, no token), `AppRadius.lg` ×5, `10` ×3, `AppRadius.sm` ×1, `16` ×1. **`AppRadius.pill` and `AppSpacing.cardPad` are used zero times.** Five radii appear in a single 400pt scroll. Collapse to `control: 12 / row: 14 / card: 20 / hero: 24` and make the tokens match what the app actually does.

**Cards are 1.07:1 against the page.** Light `FAF6F3` vs `FFFFFF`; dark `171217` vs `241D25` (1.11:1). The hairline border is doing 100% of the work. Move the background to the briefed `#F7F3F0` (or `F5F0EC`) and add one shared `.appCard()` modifier with a soft warm shadow — which also consolidates five duplicated background/overlay/clipShape triplets. In dark mode the empty ring tracks (`3A2F38`, 1.32:1) currently out-shine the surface, so the *absence* of data is the loudest thing in the hero card; darken to ~`2C2430`.

**The middle ring is permanently grey.** Active energy is driven by `burned / max(goal * 0.15, 1)` — a denominator invented client-side. With no exercise logged it draws nothing, while the legend confidently lists a green "Active energy" dot for a colour that never appears. Either drop to two rings, or give the empty ring an honest goal and a visible zero state. Either way make the legend value-bearing (`Water · 1,250 ml`) rather than a colour key.

**The macro card teaches a different reading mode than the card 8pt above it.** The ring is entirely goal-relative; the macro row is absolute grams with no goal, bar or percentage — `82g / 100g / 33g` with no way to know if 82g is good. Express as `82 / 140g`, matching the water card's existing grammar. Also: protein reuses `AppColor.accent`, so magenta simultaneously means calories, protein, the FAB, the selected tab and every link — give protein its own data hue.

**The hero card is ~63% empty.** `RingCard` has vertical padding but **no horizontal padding**, so a 220pt ring in a 362pt card leaves 71pt of blank white on each side. Either shrink the ring to ~180 and put secondary stats in the gutters, or narrow the card.

**Empty meal sections have no surface**, and the left edge jumps 14pt when the first food lands (bare text at x=20 → card text at x=34). Give the empty state a dashed placeholder row at the same geometry as a food card — the app already has that language in `GoalNotSetCard`. Also unify the copy: Today says "Not logged yet", Diary says "Nothing logged" for the identical state.

**Login is 56% empty cream with no brand mark.** First content at y=488 of 874, form bottom-anchored by a single `Spacer()`, no logo or wordmark, and a 28pt gutter used nowhere else in the app (everything else is 20). Add a brand lockup in the upper region — the `RingChart` geometry at 56pt makes a natural mark — and balance with spacers on both sides so the composition holds at any device size.

**Sheet architecture.** Log Food → Custom Food stacks a second sheet at *pixel-identical frames* with no visual stacking cue, so it looks like a push but behaves like a stack: "Cancel" returns you to a search sheet you thought you'd left, and both sheets stay in the accessibility tree (VoiceOver can reach the covered one). Convert to a `NavigationStack` with `.navigationDestination`. **Caveat worth heeding:** `FoodSearchView`'s header comment documents a real past bug where a `NavigationStack` in a multi-detent sheet reserved ~130pt of invisible nav-bar space. That's specific to a hidden bar in a `.medium` detent — use a visible `.inline` title and drop `.medium` for that sheet, and verify in the simulator before committing.

**`.searchable` instead of a hand-rolled field.** The current `TextField` + separate magnifier icon gives up the search trait, the clear button, `.searchSuggestions` (the natural home for recents), the `.search` return key, and Dynamic Type. The icon is also its own a11y element announcing "Search" before an unlabelled field.

**Every text sheet costs an extra tap.** No `@FocusState` anywhere, so Log Food, Add Water, Custom Food and Log Exercise all open with the keyboard down. Log Food also opens at `.medium`, so raising the keyboard reflows the sheet under the user — open it at `.large`.

**The FAB costs ~0.8s of dead air.** It dismisses the chooser sheet and presents the real sheet from the dismiss handler (a deliberate race-avoidance measure, but two full sheet animations on the primary action). A `Menu` presents and dismisses instantly and removes the intermediate sheet entirely.

**Date picking is two steps where one would do.** Tapping a date then pressing "Go to date" — tapping a date could navigate and dismiss. The sheet also has no Cancel and no title, and drops the brand typography entirely (the system `.graphical` picker can't be restyled, so frame it with the standard `SheetHeader` instead). Minor: for an account created today, `minDate == maxDate`, so every cell renders disabled with no explanation.

**Diary day paging shows a new date over stale content** with no indication, and there's no swipe gesture on a screen whose whole purpose is moving between days. Add a directional transition, dim stale content while loading, and wire up `DragGesture`.

**No write in the app confirms success** beyond a haptic — nothing for users with haptics off. Post an `AccessibilityNotification.Announcement`, and consider an optimistic insert plus a brief toast so the ring visibly rewards the log instead of the screen reloading from scratch.

**`Divider()` is the only system-coloured line in the app** (cool translucent black) among warm `AppColor.hairline` rules everywhere else; it also runs full-bleed into the card's rounded corners. Replace with an inset hairline `Rectangle`.

**Number formatting is inconsistent** — `1,022 eaten` groups, `1250 / 2000 ml` and `296 KCAL` don't. Cause: `Text("\(Int(x)) eaten")` resolves as a `LocalizedStringKey` and gets locale formatting free, while the others build a `String` first. Route everything through one `Num.int()` helper.

**Component sizes drift.** The accent-soft icon circle ships at 20/26/36pt in three places; meal chips (82.6×27.2) and intensity chips (112×32.3) differ in size *and* use **opposite selected idioms** — solid accent fill vs. soft fill with accent text, so "selected" means two different things 30 seconds apart. Filled accent buttons ship at three specs. One chip component, one button with a size enum.

**No request timeout.** `APIClient` never sets `timeoutIntervalForRequest`, so the 60s default applies and every `isSaving`/`isBusy` gate can hold a control disabled for a full minute. Set ~12s for a LAN backend.

**Cold launch always flashes Login.** `ContentView` renders with `session == nil` and only *then* runs `restoreSession()`, so frame one of every launch is the full Login screen even for a valid session. Worse, `currentSession()` uses `try?`, collapsing "network unreachable" and "no valid session" into the same `nil` — which is why a server outage silently logs you out (`61_error.png`). Make restoration tri-state (`restoring` / `signedIn` / `unreachable`) and rethrow `URLError` so an offline launch shows "can't reach the server — Retry" instead of a fake logout. Login itself already handles this correctly, which makes the launch path's silence more jarring.

**No sign-out, anywhere.** No `signOut` in the protocol, no call site; `session` is only cleared by a 401. On a shared device that's a privacy problem, and it blocks recovery from **P0-6**. A minimal Settings screen (email, Sign Out, server URL, version) retires three dead ends at once.

**`Haptics.error()` fires on passive loads.** `load()` runs from `.task` on appear, from every sheet dismissal and every date change — none user-initiated. Combined with **P1-2**, the app buzzes an error notification on *every tab switch* while the server is unreachable. Gate it on a `userInitiated` flag; keep error haptics on writes, where they're correct.

**`Haptics.warning()` on swipe-delete is too heavy.** The user has already swiped *and* tapped the red button; the decision is made. Native Mail/Reminders fire nothing here. Downgrade to `.light()` and move it to when the row actually leaves.

**Haptic generators are created per call with no `prepare()`**, so the first fire in a sequence is commonly late or dropped — worst exactly where taps are rapid (the food stepper, the chips). Migrate to `.sensoryFeedback(_:trigger:)`, which handles engine preparation.

---

# What is already good — preserve this

1. **The serif + cream + magenta identity genuinely works.** `30_today_real.png` does not look like a default SwiftUI app, which is rare. The `978` in New York serif over warm cream is the strongest moment in the product. Every recommendation above extends this rather than replacing it.

2. **`AppColor` is a real token file with institutional memory.** Light/dark pairs via `Color.adaptive`, and the comments record *why* each divergence exists (`inputBackground` was light-only and made dark text unreadable; `water` deepens in dark because the sky blue washed out). Most design systems lose this. Fix three tokens and the file is genuinely good.

3. **`SearchNetworkErrorView` is the best screen state in the app** — named cause ("Can't reach the food database"), a retry, *and* a way to proceed anyway. That three-part shape is the template every other error state should copy.

4. **Distinguishing "no results" from "network error"** instead of collapsing both into `results.isEmpty`, plus a `Task.isCancelled` guard so a debounced keystroke never flashes a false network error. Subtle and frequently gotten wrong.

5. **Field-level validation.** Red label + red border + a one-line human reason under the specific field, with no modal interrupting the fix. "What did you do?" and "How many minutes?" are better copy than "Field required", and the layout holds — errors insert cleanly at a consistent 19.6pt each with nothing clipping.

6. **Auth error mapping.** Duplicate email and weak password go under their field; a bad login goes to a banner plus a reddened-but-message-less password field, because the client can't know which field is wrong. That's exactly the right reasoning.

7. **The centralised 401 → `.sessionExpired` notification**, so an expired session produces one clear message instead of every screen inventing its own "network error".

8. **`DailySummaryCard` is correctly extracted and genuinely shared.** Today and Diary render pixel-identical summaries — same x, same widths, differing only by scroll offset. That discipline is why the header misalignment stands out as fixable rather than structural.

9. **The food row is a well-made component** — name 15 semibold / unit 12 secondary stacked left, calories right-aligned, shared verbatim between Today and Diary, right-aligning cleanly to x=368 across all seven rows with no jitter. Level everything else up to this.

10. **`BodyCard`'s weight treatment is the app's best typographic moment** — `73.4` at 20 bold plus ` kg` at 13 secondary, composed so they share a baseline.

11. **Swipe-to-delete on a real `List`**, adopted specifically because `.swipeActions` requires it and then stripped of system chrome — the right trade, made for the right reason, and the one place VoiceOver gets first-class behaviour free (the actions rotor). Food-derived water is deliberately rendered non-swipeable rather than looking deletable and failing.

12. **Per-line tap routing on the body row** — tapping the weight opens the weight sheet, not the measurements sheet — with the motivating bug documented.

13. **Pull-to-refresh on both data screens**, and `.scrollDismissesKeyboard(.interactively)` (the interactive variant, correctly) on Log Food.

14. **Time-of-day meal pre-selection** is a real step removed for free. It only needs to yield to an explicit signal (**P1-7**), not be replaced.

15. **Water is deliberately not in the FAB menu**, because burying a one-tap action two sheets deep would be slower. Correct step-count reasoning, written down.

16. **Date bounds derived from the account creation date**, with genuinely disabled forward navigation (`Disabled` shows correctly in the accessibility tree) rather than an arbitrary window.

17. **The haptics vocabulary itself.** A five-verb API with intent-named wrappers and comments explaining which *control class* each serves is better than most shipping apps — as is the explicit decision *not* to haptic navigation taps. The problems are placement and timing, not judgment.

18. **`WaterCard.progressBar` is hand-rolled for a documented reason** (`ProgressView` ignored `.tint`; `scaleEffect` left a midpoint artifact). Right call, honestly recorded.

19. **The decision log throughout the source and `PROGRESS.md`.** The "Not yet built" list is explicit and accurate, and several entries record *why* something was skipped. It made this review substantially faster and will make the next one faster too. Keep writing these.

---

# Suggested sequencing

Ordered by user impact per hour, and by dependency.

**Week 1 — correctness and the cheap wins**
1. **P0-1** un-brick the goal-not-set state (3 lines)
2. **P0-6** widen the cookie sweep (3 lines) — you are currently locked out
3. **P0-3** FAB bottom inset (1 line)
4. **P0-5** compute the hero from entries (2 lines)
5. **P1-7** pass the meal type through (small)
6. **P1-14** render `isSaving` in the two stragglers (small)

**Week 2 — accessibility foundation**
7. **P0-2** Dynamic Type. Do this **before** hit targets and labels, because it changes every layout you'd otherwise be measuring. Budget a day for chip/column overflow.
8. **P0-4** + **P1-12** ring/macro descriptions, tab traits, label sweep. Mechanical, ~40 modifiers, no layout risk — the biggest VoiceOver gain per line changed.
9. **P1-11** hit targets (now that sizes are final)
10. **P1-10** contrast tokens

**Week 3 — the feel pass**
11. **P1-17** one `PressableStyle`, applied everywhere
12. **P1-1** ring fill, numeric transitions, disclosure animation, auth cross-fade
13. **P1-18** optimistic water + immediate haptic; haptic placement corrections
14. **P1-13** persistent error banner; cold-launch tri-state

**Week 4 — structure**
15. **P1-2** `TabView` migration (+ custom symbol if the ring stays)
16. **P1-6** recents + search loading state
17. **P1-5** Diary FAB
18. **P1-4** over-goal treatment
19. **P1-9** / **P1-8** one `SheetHeader`, one field style

**Later — system consolidation**
20. Type scale, radius/spacing tokens, `ValueUnit`, `.appCard()`, emoji → SF Symbols, `.searchable` + `NavigationStack` sheet re-architecture, Settings with sign-out.

---

# Appendix A — operational findings (for `PROGRESS.md`)

Not UI, but discovered during this session and worth recording:

- **`docker compose restart` does NOT re-read `.env`.** It restarts the process with the old environment. After editing `.env` you need `docker compose up -d sparkyfitness-server`, which recreates the container. Verified: after a `restart`, `docker exec sparkyfitness-server printenv | grep TRUSTED` still showed the previous IP; after `up -d` it showed the `.local` value. Confirm with that `printenv`, not with the restart succeeding.

- **`SPARKY_FITNESS_EXTRA_TRUSTED_ORIGINS` doesn't appear to take effect.** Against the recreated container with `…=http://your-mac.local:3010`, a sign-in sent with `Origin: http://your-mac.local:3010` is rejected **403 INVALID_ORIGIN**, while `Origin: http://192.168.1.50:3010` — no longer configured anywhere — returns **200**, and sending *no* `Origin` header returns **200**. The native app sends no `Origin`, so it's unaffected; but don't rely on that variable to gate anything.

- **`GET /api/foods` returns `recentFoods` and `topFoods`.** `PROGRESS.md` currently records that no recent-foods endpoint was verified — it exists, and it's what **P1-6** should use.

- **The server double-scales food-entry calories.** It re-applies `quantity / serving_size` to the already-scaled `calories` the app writes. See **P0-5** for the controlled test and the client-side workaround.

- **Test-data note.** When seeding entries directly via the API, send the pre-scaled `calories`/`protein`/`carbs`/`fat` the way `APIClient.foodEntryBody` does. Omitting them makes the server fall back to base per-serving values and produces data that looks like an app bug but isn't.

---

# Appendix B — evidence

~85 screenshots and matching accessibility hierarchies were captured during the walkthrough. The 15 referenced below have been copied somewhere durable:

**`a local screenshots folder (not committed)`**

(The full set, including the `.txt` accessibility hierarchies with exact element frames, lived in the job's scratch directory and is not preserved.)

| File | Shows |
|---|---|
| `30_today_real.png` / `.txt` | Today populated — hero, macros, first meals |
| `32_today_bot.png` | Today scrolled — status-bar collision, water + weight cards, FAB overlap |
| `01_launch.png` vs `13_ax3xl.png` | Default vs accessibility-XXXL — pixel-identical |
| `12_dark.png` / `60_dark_today.png` | Dark mode, empty and populated |
| `40_diary.png` / `42_diary_top.png` | Diary populated, date header |
| `41b_swipe.png` | Swipe-to-delete revealed |
| `43_datepicker.png` | Graphical date picker sheet |
| `50_logfood.png` | Log Food idle — the 259pt void |
| `81_mealchip_check.png` | Breakfast "+" opening with Dinner selected |
| `51_logex.png` / `52_ex_validation.png` | Exercise form, two field styles, validation |
| `11_customfood.png` | Stacked sheets at identical frames |
| `82_water_over.png` | Water 2250/2000 — bar pinned, no over-goal state |
| `20_today_full.png` | Login — 56% empty |
| `61_error.png` / `62_login_err.png` | Server down: silent Login vs. correct login error |
