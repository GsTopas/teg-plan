# TEG Leveranceplan — guide for Claude

A shared delivery plan for Topas' TEG digitalisation programme (Jul 2026 – Sep 2028).
It replaces a spreadsheet-based "TEG 3 Års Digitaliserings plan". Colleagues open
https://gstopas.github.io/teg-plan/, log in with their work e-mail, and edit the
same plan live. The owner is Gorm (gs@topas.dk). The UI, code comments and commit
messages are all in Danish. Keep writing them in Danish.

## Architecture

- **One file.** The whole app is `index.html`, holding CSS, markup and a single
  `<script>`. There is no build step, no bundler, no npm and no framework. Edit
  the file and push to `main`, and GitHub Pages deploys it within a minute.
  Don't add a build step unless Gorm asks for one.
- **Backend = Supabase** project "topas-analyst" (ref `oxpuloflkdcpshrabvkn`). It is
  shared with other Topas tools (the `nav_*`, `tours`, … tables), so only the
  `plan_*` tables belong to this app. The publishable key in the file is meant to
  be public, because access is enforced by RLS.
- **Schema backup:** `supabase/schema.sql` is a snapshot of the tables, RLS,
  functions, triggers and realtime setup. It is not a migration. Change the live
  DB through a Supabase migration (`apply_migration`), then update that file in
  the same PR.
- **`kilder/`** holds background documents (the original 3-year plan, notes).
  Read them for context on *why* the plan is shaped as it is. The site does not use them.
- **Only dependency:** supabase-js from jsDelivr, pinned (`@2.116.0`) and loaded
  with `defer`. `init()` runs on DOMContentLoaded.
- **Auth:** magic-link (OTP) login. There is no password and no server of our own.

## Access model (RLS)

- `plan_can_read()`: any `@topas.dk` user, or an e-mail listed in `plan_readonly`.
- `plan_can_edit()`: `@topas.dk` users who are *not* on `plan_readonly`.
- `plan_changelog` can only be read by topas.dk users, never by guests.
- At boot the client calls `rpc('plan_can_edit')`. For read-only users it hides
  `#editCard`, adds `body.readonly`, disables inputs in Spor-detalje and blocks
  the quick-edit and fee popups. The database enforces the same rules anyway, so
  the UI hiding is cosmetic.
- Guests are added by inserting a row in `plan_readonly` (Supabase dashboard).

## Data model (DB → client)

The time axis is a **month index 0–26** (0 = Jul 2026, 26 = Sep 2028) everywhere,
in the DB (CHECK constraints) and in the client (`MONTHS`, `QUARTERS`).

| Table | Client global | Meaning |
|---|---|---|
| `plan_tracks` | `TRACKS` | "Spor" = project/workstream. `from_m`→`from`, `solid_to`→`solidTo` (end of the active phase, "Til"), `to_m`→`to` (extends past solidTo for `ongoing` tracks), `baseline` (running operations/"basisdrift", always last, grey), `sort` (manual order, NULL = auto by deadline), `category` (one of `TRACK_CATS`), `color` (a CSS var name from `COLOR_SLOTS`), fees: `fee_onetime`, `fee_recurring` (per year), `fee_extra` + `fee_extra_label` (optional extra recurring line), `fee_internal` (internal salary cost). `id` is a readable slug (`slugifyTrack`). |
| `plan_milestones` | `track.milestones[]` | "Punkt/opgave" = task. `m` = deadline month, `from_m` = start month (NULL → same as `m`), `status` ∈ `todo/igang/faerdig/blokeret`. `owner` is a **derived** text (names of the allocations), kept in sync by the client. |
| `plan_allocations` | `ALLOC` | % of a person's time on a track. Exactly one of `person_id` or `dept` (a whole department). If `milestone_id` is set, its period **follows the milestone** (DB trigger `plan_sync_alloc_period` plus client `allocPeriod()`). Without a milestone it is a "løbende allokering" with its own `from_m`/`to_m`. |
| `plan_dependencies` | `DEPS` | `from_ms` (prerequisite milestone) → `to_ms` (a milestone) or just `to_track` (project start). `dep_type`: `start` = must finish before the target *starts*, `finish` = before the target *finishes* (drawn dashed). |
| `plan_subtasks` | `SUBTASKS` | "Delopgaver" under a milestone: person, hours (estimate only, doesn't affect load %), `due_date`, `status` (`done` is kept in sync as `status === 'faerdig'` for older data). |
| `plan_people` | `PEOPLE` | `id` is a slug, `department` → `dept`. Names are assumed unique. |
| `plan_departments` | `DEPTS` | Stand-alone department list, so departments without people can still be allocated. |
| `plan_changelog` | `CHANGELOG` | Written by the `plan_log_change` trigger on every table (who/what/old/new jsonb). The client shows the latest 30. |
| `plan_readonly` | — | Guest e-mails (see access model). |

Deleting relies on **FK cascades** in the DB. The client only mirrors them locally
(see the delete handlers).

## Views

Three tabs, selected via the URL hash (`#overblik`, default timeline, `#detalje/<trackId>`):

1. **Overblik** (`renderOverblik`): quarter view to Q3 2028, grouped by
   category. A bar is only drawn in quarters that contain a deadline (◆). Tracks
   without tasks get a thin frame line. Fee lines show under the track name and
   wrap, with row height measured through a canvas. Clicking a bar opens the fee
   popup (`openFeeEdit`), and the total line sums all fees.
2. **Tidslinje & Opgaver** (the default, all `.view-ov` sections):
   - `renderGantt`: one thin line per track for its period, plus one sub-row
     per task (bar from start to deadline, ◆ at the deadline, label above) and
     dependency arrows in SVG. Clicking a ◆ opens `openMsQuickEdit`.
   - `renderHeat`: load per person per month (sum of %). Department
     allocations get their own rows but are never flagged as overbooked.
   - `renderWarnings`: overbooked (>100 %), missed deadlines, blocked tasks
     and dependency conflicts.
   - The "Redigér data" editors cover tracks, tasks (grouped per track),
     running allocations, dependencies, people/departments and the change log.
3. **Spor-detalje** (`renderDetail`): one track's tasks with status and
   subtasks.

Filters: the person filter *hides* tracks the person isn't on (including through
their department), and the track filter *dims* the other tracks.

## Key logic worth knowing

- **`depStatus(d)`** compares the prerequisite's deadline `a` with the target
  month `b`. For `start`, `b` is the target's start month (or the track's
  `from`); for `finish`, it is the target's deadline (or the track's `solidTo`).
  If `a > b` it is a conflict (red); if `b - a ≤ 1` it is tight (yellow). The
  same rule is repeated in `renderGantt`, `renderOverblik` and `renderWarnings`,
  so a change has to be made in all four places.
- **Track order** (`visibleTracks`): tracks with a manual `sort` come first,
  then auto-order by `solidTo`, and baseline tracks always come last.
- **Owner text sync:** when allocations on a milestone change, `ms.owner` is
  rebuilt from the allocation names and saved (`syncMsOwner` / `syncOwner` /
  `resyncOwnersFor`).
- **"Today" line:** `TODAY_X` is computed from the current date and clamped to
  the horizon.

## Editing / sync pattern (read before touching the UI)

These rules came out of the Sep 10 performance pass. Breaking them brings back
lost focus, UI stutter or overwritten colleague edits.

- **Optimistic writes:** the `DB.*` helpers mutate local state first, then send
  the query in the background. New rows get a client `crypto.randomUUID()`.
  `PENDING`/`afterIns` make sure an update or delete on a just-created row waits
  for its INSERT to finish. On error, `dbTry` shows a toast, reloads everything
  and re-renders.
- **Updates write the whole row** (e.g. `updMilestone` sends every field). Always
  look up a fresh object (`findMs(id)`, `trackById(id)`) inside handlers,
  because realtime reloads replace the objects and a stale closure would roll
  back a colleague's change.
- **Realtime:** one channel covers all plan tables except `plan_changelog`
  (its rows always come with another change). The reload is debounced by 350 ms
  and **deferred while `editingNow()`** is true (focus in an editor input or an
  open owner-pick).
- **`refresh(rebuildEditors)`** only re-renders the visible view. Pass
  `refresh(false)` from `change` handlers, because the value is already in the
  input and rebuilding would steal focus. Pass `refresh(true)` after add/delete
  or structural changes.
- **Rows are identified by id** (`data-xx="<id>:<field>"`, split at the *last*
  colon). Never use array index. Department names may contain `:`, so the
  department pickers split at the *first* colon.
- **Lazy pickers:** person/percentage panels are built only when a
  `details.owner-pick` is opened.
- Always escape interpolated text with `esc()`. `color` is validated against
  `/^--s-[a-z]+$/` because it's inserted into style attributes.
- Frozen axis headers (`frozenHead`) are driven by events (a capture-phase
  scroll listener plus a 200 ms interval). Don't reintroduce a
  requestAnimationFrame loop.

## Checklists

**Adding a column to a plan table**
1. Add it with a migration in Supabase (with a CHECK if it has a range).
2. Map it in `loadAll` (snake_case → camelCase, `null` stays `null` for
   optional numbers).
3. Include it in the relevant `DB.upd*` / `DB.add*` payload, since a missing
   field is silently not saved.
4. Add a UI field and a label in `renderChangelog`'s `feltNavn` map.
5. Add it to the export button's JSON if relevant, and update `supabase/schema.sql`.

**Extending the horizon** (done twice: to Jun 2028, then Sep 2028)
- `MONTHS` loop count, `MCOUNT` and `qLabels` count in `renderOverblik`.
- DB CHECK constraints (`plan_ms_*`, `plan_alloc_*` `≤ 26`).
- Header subtitle, footer, export `horizon` string, the Overblik description text.

## Known loose ends

- The header subtitle still says "Juli 2026 – juni 2028" and the README says
  "18-måneders". Both predate the Sep 2028 horizon.
- The department % inputs allow up to 300, but the DB CHECK on
  `plan_allocations.pct` caps it at 150. Values above 150 fail to save and
  trigger a reload.
- `ongoing`/`baseline` flags can only be edited in the Supabase Table Editor.

## Working conventions

- Commit prefixes: `feat:`, `ui:`, `fix:`, `perf:`, `chore:`. Messages in Danish
  without æøå (written as ae/oe/aa). Explain the *why* in the body when it
  isn't obvious.
- No test suite. Verify changes by opening the page, or at least by
  syntax-checking the script (`node --check` on the extracted `<script>`).
- The plan data is live and shared, so don't write test data to the production
  tables.
