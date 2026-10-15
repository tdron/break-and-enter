# break-and-enter

…actually called **Steal an Item** 🦝

A complete Roblox heist game. Break into houses, grab the loot, outrun the security drones, and stash everything in your warehouse, where it earns you cash every second. Spend the money on a faster getaway car, a bigger loot bag and trunk, more warehouse space and a better treadmill. Your treadmill sits outside your warehouse and trains you even while you're AFK, until you're fast enough to rob the Mansion.

![Overview of the town](docs/preview-overview.png)

## ▶️ Play it in 30 seconds

1. Download **[`StealAnItem.rbxlx`](StealAnItem.rbxlx)**.
2. Double-click it, or open Roblox Studio and choose **File → Open from File…**.
3. Press **Play** (F5).

Everything is inside that one file: the town, all the scripts and the UI. Nothing needs to be installed.

> **Multiplayer test:** Studio's **Test** tab → *Clients and Servers* → pick 2+ players → **Start**.

## 🎮 How to play

| Step | What to do |
|---|---|
| 1 | You spawn in **your own warehouse** (your name is on the sign). Press **🚗 CAR** to get your getaway car. |
| 2 | Drive east to the neighborhood. Walk up to a front door and **hold E to pick the lock**. |
| 3 | Walk up to loot and **hold E to steal** it. Your bag fills up and a loot sack appears on your back. |
| 4 | **Stealing trips the alarm!** After a short warning, security drones chase you. Get past the property's fence line to escape. If a drone catches you, you're **BUSTED** and lose everything you're carrying. |
| 5 | Put loot in your car with **Load Trunk [F]**, or carry it home. |
| 6 | Step on the **green DEPOSIT pad** in your warehouse, or park on the **yellow LOADING DOCK** to unload the trunk. |
| 7 | Items on your shelves **earn cash every second**. Buy upgrades at the **🛒 SHOP**. Walk onto **your treadmill** outside the warehouse to get faster (AFK works). |

**Controls:** WASD / arrow keys to walk and drive (W/S throttle, A/D steer). **E** to interact, **F** for the trunk, **Space** to jump, leave the car or hop off the treadmill. Mobile and gamepad use the standard Roblox controls.

### The neighborhood

| House | Count | Lockpick | Drone speed | Loot |
|---|---|---|---|---|
| 🏡 Cottage | 4 | 0.6 s | 11 (you start at 16, so easy) | Toasters, teddy bears, piggy banks… $25–$400 |
| 🏠 Suburban House | 4 | 1.2 s | 18 | Laptops, guitars, TVs, gold watches… $160–$1,500 |
| 🏢 Modern Villa (has lasers!) | 2 | 2.0 s | 26 | Gaming PCs, modern art, trophies, diamond necklaces… $1,400–$22,000 |
| 🏰 Grand Mansion (laser vault!) | 1 | 3.0 s | 34 | Gold bars, crowns, masterpieces, a giant diamond… $12,000–$120,000 |

Loot comes in Common, Rare, Epic and Legendary rarities and restocks after a while. Villas and the Mansion have **blinking laser tripwires**: time your run, or jump the low beams.

![Houses](docs/preview-houses.png)

### Upgrades (shop)

| Upgrade | Levels | What it does |
|---|---|---|
| 🎒 Loot Bag | 2 → 12 items | Carry more loot on foot |
| 🏎️ Getaway Engine | 45 → 110 mph | Faster car, plus new paint, a spoiler, racing stripes and underglow |
| 🧳 Trunk Space | 4 → 25 items | Bigger car trunk |
| 📦 Warehouse Space | 10 → 50 slots | More shelves means more passive income |
| 🏃 Treadmill | 2 → 34 XP/s | Your treadmill trains you faster (see below) |

If your warehouse is full, depositing better loot automatically sells your cheapest item to make room. You can also sell any shelf item yourself by holding E on it.

### 🏃 Your treadmill

Every warehouse has its own treadmill out front, to the left of the loading dock. A **YOUR TREADMILL** sign floats over yours.

- **Walk onto the belt** and your character starts running by itself. Your movement keys switch off, so you can go AFK and keep getting faster.
- Press **ESCAPE**, **Space**, or **A** on a gamepad to hop off beside it. Walk back on to run again.
- Each speed level adds **+1 walk speed**, from 16 up to 66 at max level.
- You upgrade the treadmill itself, either in the shop or by holding **E** at its console. Its trim gets flashier with every level, and only you can use or upgrade yours.

| Treadmill level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Speed XP per second | 2 | 3 | 5 | 8 | 12 | 17 | 24 | 34 |
| Price | free | $300 | $1,200 | $4,000 | $12,000 | $35,000 | $90,000 | $220,000 |
| Walk speed 16 → 66 from scratch | ~24 min | ~16 min | ~10 min | ~6 min | ~4 min | ~3 min | ~2 min | ~1.4 min |

![A warehouse treadmill](docs/preview-treadmill.png)

> Roblox itself disconnects anyone who gives no input for about 20 minutes. That's a platform rule a game can't turn off, but progress is saved when they leave.

![Mansion interior](docs/preview-cutaway.png)

## 💾 Saving progress

Progress saves with DataStores: cash, upgrades, speed, warehouse items and trunk contents. Loot you're *carrying* doesn't save, so stash it!

DataStores only work in a **published** game:

1. **File → Publish to Roblox**.
2. **Game Settings → Security → Enable Studio Access to API Services** (to test saving inside Studio).

Unpublished, the game still runs normally and shows a small "progress won't be saved" message.

> Each server has **6 warehouses**, so set **Max Players = 6** when you publish (Game Settings → Places). If more people join, they can still play: their loot is sold for cash at any deposit pad.

## 🛠️ Customizing

Every number lives in **[`src/shared/Config.luau`](src/shared/Config.luau)**: upgrade prices and values (including the treadmill's XP per second), drone speeds, lockpick times, restock times, income rate, car handling and sounds.

- **Add or change loot:** [`src/shared/Items.luau`](src/shared/Items.luau). Each item is a small model built from parts, so no uploads are needed.
- **Change the town:** the map is generated by [`tools/map_builder.py`](tools/map_builder.py). You can also edit the map directly in Studio and save the place. Just don't rebuild afterwards, because rebuilding regenerates it.
- **Sounds:** the game uses sounds that ship with Roblox so they always work. Swap in your own `rbxassetid://` IDs in `Config.Sounds`.

After editing anything in `src/` or `tools/`, rebuild the place file:

```bash
python3 tools/build_place.py        # writes StealAnItem.rbxlx (+ sourcemap.json)
```

Only Python 3 is needed (standard library only).

## 📁 Project layout

```
StealAnItem.rbxlx          ← the game (open this in Roblox Studio)
src/
  server/                  → ServerScriptService.Server
    init.server.luau         boots everything, player join/leave
    PlayerData.luau          saving/loading, attributes the UI reads, leaderstats
    Inventory.luau           carried loot, trunk, loot sack on your back
    Plots.luau               personal warehouses, shelves, deposit pad, selling
    Houses.luau              doors, loot, alarms, security drones, lasers, busting
    Vehicles.luau            getaway car (hover physics, seats, trunk, dock unloading)
    Treadmills.luau          personal treadmills: AFK speed training, console upgrades
    Economy.luau             income ticks + upgrade purchases
    Notify.luau              toast notifications
  client/                  → StarterPlayerScripts.Client
    init.client.luau         builds the UI, listens to the server
    Hud / Shop / Notifications / BustedScreen / UI.luau
    VehicleController.luau   driving
    TreadmillController.luau auto-running on your treadmill, ESCAPE / Space to hop off
    WorldEffects.luau        sirens, treadmill belts, "your warehouse" marker
  shared/                  → ReplicatedStorage.Shared
    Config.luau  Items.luau  ItemModels.luau  Format.luau
tools/
  build_place.py           builds StealAnItem.rbxlx from src/ + the generated map
  map_builder.py           procedural town (houses, warehouses + treadmills, shop, roads)
  rbxlx.py                 Roblox XML place writer
  validate_place.py        checks the place file (structure + Roblox API)
  run_luau_tests.py        runs the Luau test suites
  render_preview.py        renders the preview images in docs/
tests/                     unit, server-integration and client tests (+ a mock Roblox engine)
default.project.json       optional Rojo project for live-syncing scripts
```

## 🧪 Development

The scripts are written in strict-mode Luau and checked against the real Roblox API.

```bash
python3 tools/build_place.py                                   # build the place
python3 tools/validate_place.py --database database.json      # check every class/property/enum
python3 tools/run_luau_tests.py --database database.json      # 54 tests (needs the `luau` CLI)
luau-lsp analyze --settings .vscode/settings.json --platform roblox \
  --sourcemap sourcemap.json --definitions=@roblox=globalTypes.d.luau src   # type-check
```

- `database.json` is Rojo's API dump ([rbx-dom](https://github.com/rojo-rbx/rbx-dom/blob/master/rbx_dom_lua/src/database.json)). `luau` and `luau-lsp` come from their GitHub releases.
- The integration tests run the real server and client scripts against a small mock of the Roblox engine. That mock loads the real generated map and rejects invalid properties, just like Roblox does. They play through joining, lockpicking, stealing, getting busted, escaping, depositing, earning, upgrading, AFK treadmill training (including hopping off with Space), driving, selling, and saving then loading.
- **Rojo (optional):** open `StealAnItem.rbxlx` in Studio, run `rojo serve`, and connect the Rojo plugin to live-sync `src/` while you edit.
