# Scrap Shift

A 1-4 player co-op game made with Godot 4.7. Land at an abandoned facility, carry
scrap back to the ship, avoid the monster, meet the quota, and survive as long as you can.

## Controls

| Key | Action |
|---|---|
| WASD / mouse | Move and look |
| Shift / Space | Sprint / jump (when dead, Space switches which crewmate you watch) |
| E / G | Pick up or use the console / drop |
| F | Flashlight |
| Esc | Menu |

## Play it now

Double-click **Scrap Shift** in this folder, then press **Play now**.

To play with friends, one person chooses **Host a game with friends** and the others choose
**Join a game**. For several windows on one Mac, run this command once per extra window:

```bash
tools/Godot.app/Contents/MacOS/Godot --path .
```

To play with someone on your home network, type the host's local IP address into the
join box. Over the internet this version needs the host to forward UDP port 24567. Step 6
below replaces that with Steam invites.

## Settings

Open **Settings** from the main menu or the pause menu. Every change applies straight away and
is remembered. Settings live in `scripts/autoload/settings.gd` and the screen in
`scripts/settings_menu.gd`.

| Tab | What's there |
|---|---|
| Display | Window mode and size, V-Sync, frame limit, render quality, anti-aliasing, flashlight shadows, brightness, field of view |
| Audio | Master, ambience and sound effects volume |
| Controls | Mouse sensitivity, invert mouse, rebind every key (mouse buttons work too) |
| Controller | Look sensitivity, invert look, stick dead zone, vibration, rebind every button |
| Gameplay | Creature hints, crosshair |

Controller defaults: left stick moves, right stick looks, A jumps, X picks up or uses, B drops,
Y is the flashlight, RT sprints, Start pauses. In menus, LB and RB switch tabs and B goes back.

## Maps and creatures

Each run visits the four maps in a random order, and threats grow as rounds pass. To change
a map, or add one, edit `scripts/map_themes.gd`.

| Map | Vibe | Its rule | Who's there |
|---|---|---|---|
| Rust Foundry | Hot orange light, heavy machines | Lots of side routes | Stalker, Mimics, Sentinels |
| Cryo Vault | Thick pale-blue fog | Stamina recovers at half speed | Watchers, Patch |
| Bio Lab | Sickly green, failing lights | Tight corridors, few loops | Stalker, toxic vents, Mimic, Patch |
| Blackout Reactor | Near-black, red alarm pulses | Scrap worth 30% more | Listeners, Watcher, Wisp, Sentinel |

| Threat | What it does | How to beat it |
|---|---|---|
| Stalker | Patrols, spots you and runs you down | Sprint away, or reach the ship |
| Watcher | Moves only when nobody can see it | Keep someone's eyes on it |
| Listener | Blind; rushes toward noise | Walk or stand still; never sprint nearby |
| Mimic | Looks like scrap, bites when you get close | Real scrap shows a pick-up prompt |
| Toxic vent | Fills a room with gas on a timer | Wait for it to close, then cross |

| Helper | What it does |
|---|---|
| Patch | A drone that flies to hurt players and heals them, with limited charge |
| Sentinel | A pylon that stuns the nearest hunter it can see, then recharges |
| Wisp | A light that leads you toward scrap and turns red near hunters |

The ship is always safe. The first time you meet each one, the HUD explains it.

## How the work flows

**1. How the game is organised.** One player is the host, and their game is the referee.
Each player moves their own character so controls feel instant, while the host decides
everything that could be disputed: who holds what, who gets hurt, and when a round ends.

| File | Job |
|---|---|
| `scripts/rules.gd` | Every balance number. Start here to tune the game. |
| `scripts/autoload/net.gd` | Connections and the crew list. The only file that knows about ENet. |
| `scripts/autoload/session.gd` | Round flow, and checking every player request. |
| `scripts/facility_layout.gd` | Generates the map from a seed, so the host only sends one number. |
| `scripts/level.gd` | Turns that map into walls and lights. |
| `scripts/player.gd`, `scrap.gd` | Players and items. |
| `scripts/monster.gd`, `scripts/entities/` | Every creature and helper. |
| `scripts/map_themes.gd` | Every map's look, sound, rules and residents. |
| `scripts/main.gd` | Menus and HUD. |
| `scripts/autoload/sfx.gd` | Every sound, and how loud it plays. |
| `scripts/autoload/store.gd` | The in-game shop. |
| `supabase/functions/`, `cloud/store_schema.sql` | The payment server and its tables. |
| `scripts/assets.gd`, `assets/` | Loading the models and sounds. |
| `scripts/autoload/cloud.gd`, `cloud/schema.sql` | The online database. |

**2. One round.** The host picks a seed > every machine builds the same facility > the host
creates players, scrap and the monster > players bank scrap in the ship > the round ends when
someone launches, time runs out, or everyone dies > quota met: next, harder round. Quota
missed: each player saves the run to the database and the crew returns to the lobby.

## Testing

Run these after every change. Both must report no problems.

```bash
python3 tests/run_tests.py
```

That runs rule checks plus a real session: four separate copies of the game on real network
connections, and a fifth player who must be refused. It covers cheating attempts, deaths,
disconnects, and a fake database.

```bash
tools/Godot.app/Contents/MacOS/Godot --path . res://tests/test_main.tscn -- role=ui
```

That opens a real window and uses the actual menus, keyboard, mouse and graphics.

## What's left

### 3. Connect the cloud database (you, about 10 minutes)

1. Create a free project at [supabase.com](https://supabase.com).
2. In **SQL Editor**, paste all of `cloud/schema.sql` and press Run.
3. Under **Authentication**, turn on **anonymous sign-ins**.
4. Under **Project Settings > API**, copy the project URL and the **publishable** key into
   `scripts/cloud_config.gd`. Never use the secret key.
5. Play a run and lose. The score should appear in the `runs` table and on the main menu.

### 4. Voice chat and more content

The art and sound are in (see `CREDITS.md` and `assets/licenses/`). Voice chat is the next
big feature, followed by more monsters, scrap and facility types.

To measure how loud each sound is after changing it:

```bash
tools/Godot.app/Contents/MacOS/Godot --path . res://tests/test_main.tscn -- role=levels
```

### Selling items with QRIS (non-Steam versions only)

[Steam requires in-game purchases to use the Steam Wallet](https://partner.steamgames.com/doc/features/microtransactions),
so QRIS must stay out of the Steam version. A build exported with the `steam` feature tag
hides the shop and refuses Midtrans orders. Selling on Steam needs Steam's own microtransaction
system, which isn't built yet.

How a purchase flows: the game asks `create-qris-order` for an item > the server looks up the
price and asks Midtrans for a QR code > the player pays > Midtrans notifies `midtrans-webhook`
> the server checks the signature, re-confirms with Midtrans, and unlocks the item > the game,
checking every 3 seconds, sees it. The game never decides that something is paid for.

**Test mode setup:**

1. Connect the cloud database first (step 3), then paste `cloud/store_schema.sql` into the
   Supabase SQL Editor and press Run. Product names and prices live in the `products` table.
2. Create a Midtrans account and switch its dashboard to **Sandbox**.
3. Install the [Supabase command line tool](https://supabase.com/docs/guides/cli), then run
   these yourself, typing your sandbox server key where shown. Never put this key in the game.

   ```bash
   supabase login
   ```

   ```bash
   supabase link --project-ref YOUR_PROJECT_REF
   ```

   ```bash
   supabase secrets set MIDTRANS_SERVER_KEY=YOUR_SANDBOX_SERVER_KEY
   ```

   ```bash
   supabase functions deploy create-qris-order
   ```

   ```bash
   supabase functions deploy midtrans-webhook --no-verify-jwt
   ```

4. In Midtrans, set the Payment Notification URL to
   `https://YOUR_PROJECT_REF.supabase.co/functions/v1/midtrans-webhook`.
5. Buy something in the game and complete it with Midtrans's sandbox payment simulator.

**Before taking real money, all of these must be done:**

- Pass every case in test mode: paid, expired, refunded, and paying two open QR codes.
- Add real account login. Purchases belong to an anonymous account stored on one computer, so
  today a player who reinstalls or changes computers loses what they bought.
- Add terms, a refund policy and a support contact, and check your tax duties.
- Confirm Midtrans approves your business for selling digital game items.
- Watch the function logs for `REFUND NEEDED` and `AMOUNT MISMATCH`. Refunds are done by hand.

Only then set your production key and `MIDTRANS_IS_PRODUCTION=true` with `supabase secrets set`.

### 5. Playtest with friends

Play over a real connection and tune `rules.gd`. Automated tests can't tell you if it's
fun, or how it feels with real lag.

### 6. Steam

1. Sign up at [Steamworks](https://partner.steamgames.com), pay the $100 app fee, and finish
   the identity, bank and tax forms to get your App ID.
2. Add GodotSteam (a build for Godot 4.7.2 exists), and replace `net.gd`'s `host()` and
   `join()` with Steam lobbies, invites and networking. The rest of the game doesn't change.
3. Send scores through a server check that verifies the player's Steam identity. Today's
   scores come from the player's own game, so they can be faked.
4. Export for Windows, and test on a real Windows PC.
5. Upload the build, set up the store page and trailer, pass Valve's review, and release.
   Check your Steamworks account for the current waiting periods.
