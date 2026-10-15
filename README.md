# break-and-enter

…actually called **Steal an Item** 🦝

A complete Roblox heist game. You spawn in a walled yard of garages with the market in the middle, then sneak down a canyon street of houses at night, pick the locks, grab the loot and outrun the guards: cats in the cottages, a different dog breed in every other house, and security drones at the Grand Mansion. Stash everything in your warehouse, where it earns you cash every second — or walk up to a shelf and **take an item back off it**, or sell it on the spot. The other stall in the yard is the **💰 SELL POINT**, where the trader buys whatever you're carrying (and what's in your car's trunk, if you park it there). Spend the money on a faster getaway car, a bigger loot bag and trunk, more warehouse space and a better treadmill. Your treadmill sits outside your warehouse and trains you even while you're AFK, until you're fast enough to rob the Mansion. Every house has its own loot, **Epic and Legendary items glow in their rarity's colour**, and the **📖 Loot Index** shows how many of the 48 items you've collected.

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
| 1 | You spawn in **the yard**: a parking lot ringed by six garages. One of them is yours (your name is over the door), and you always respawn inside it. Press **🚗 CAR** to get your getaway car. |
| 2 | Drive east down the street. Walk up to a front door and **hold E to pick the lock** (only at night!). |
| 3 | Walk up to loot and **hold E to steal** it. Your bag fills up and a loot sack appears on your back. |
| 4 | **Stealing trips the alarm!** After a short warning, the house's guards wake up and chase you. Get past the front fence to escape. If a guard catches you, you're **BUSTED** and lose everything you're carrying. |
| 5 | Put loot in your car with **Load Trunk [F]**, or carry it home. |
| 6 | Step on the **green DEPOSIT pad** in your warehouse, or park on the **yellow LOADING DOCK** to unload the trunk. |
| 7 | Items on your shelves **earn cash every second**. Hold **E** on a shelf to open your **📦 STORAGE**, where you can **take an item back into your bag** or sell it for cash. |
| 8 | In a hurry? Drive to the **💰 SELL POINT** stall in the middle of the yard and sell your whole bag at once — the trader also buys your trunk while your car is parked at the stall. Buy upgrades at the **🛒 UPGRADE SHOP** stall opposite. Walk onto **your treadmill** outside your garage to get faster (AFK works). |

**Controls:** WASD / arrow keys to walk and drive (W/S throttle, A/D steer). **E** to interact, **F** for the trunk, **Space** to jump, leave the car or hop off the treadmill. Mobile and gamepad use the standard Roblox controls.

### 🅿️ The yard (where you spawn)

The spawn is a walled parking lot at the west end of the street. **Six garages** stand around its edges — two on each of three sides — each one with a loading dock, a car spot and a treadmill outside. A cube cliff wraps the three closed sides, and the only way out is the road east, which the cliffs follow until they meet the canyon street.

Each garage is your **warehouse**: the loading dock, the green DEPOSIT pad, your shelves and your treadmill are all there.

In the middle of the lot stand **two market stalls, back to back**: the **🛒 UPGRADE SHOP** facing the spawn and the **💰 SELL POINT** facing the garages.

![The yard](docs/preview-yard.png)

### The street

All ten houses are the same roomy design (living room, kitchen, bedroom, study and a display pedestal at the end of the hall), painted differently and alternating sides of the road. Each one backs onto a rocky cliff made of different-sized cubes, so the street feels like a canyon. The further east you go, the tougher the guards and the better the loot. The Grand Mansion closes off the end of the road.

| Houses | Guards | Lockpick | Guard speed | Loot |
|---|---|---|---|---|
| 🏡 1–4: Maple, Willow, Rose & Daisy Cottage | 🐱 one cat each: ginger, tuxedo, Siamese, grey tabby | 0.6 s | 11 (you start at 16, so easy) | $25–$420 |
| 🏠 5–8: Blue Oak, Cedar, Elm Street & Birch House | 🐶 two dogs each: Chihuahuas, Pugs, Corgis, Dalmatians | 1.2 s | 18 | $160–$1,600 |
| 🏠 9–10: Pine Ridge & Aspen House (lasers!) | 🐕 two German Shepherds / two Dobermans | 2.0 s | 26 | $1,400–$22,000 |
| 🏰 Grand Mansion (laser vault!) | 🤖 four security drones | 3.0 s | 34 | $12,000–$120,000 |

Cats and dogs sleep in their pet beds until the alarm goes off, then run along the floor after the nearest thief (their eyes turn red). The drones still fly. Each house's sign shows its guard and speed. The two hardest houses and the Mansion have **blinking laser tripwires**: time your run, or jump the low beams.

Every house has **its own loot** (4 to 6 different items): two Commons, a Rare and an Epic, plus Legendaries in the hardest houses.

<details>
<summary>Spoilers: every item, house by house</summary>

| House | Common | Rare | Epic | Legendary |
|---|---|---|---|---|
| Maple Cottage | Toaster, Yarn Basket | Coffee Maker | Grandma's Jewels | |
| Willow Cottage | Desk Lamp, Teddy Bear | Cuckoo Clock | Silver Tea Set | |
| Rose Cottage | Old Radio, Cookie Jar | Piggy Bank | Antique Music Box | |
| Daisy Cottage | Snow Globe, Hair Dryer | Record Player | Crystal Cat Statue | |
| Blue Oak House | Microwave, Blender | Electric Guitar | Golden Watch | |
| Cedar House | Laptop, Smart Speaker | Flatscreen TV | Diamond Dog Collar | |
| Elm Street House | Game Console, Retro Camera | Telescope | Royal Corgi Portrait | |
| Birch House | Boombox, Vintage Fire Helmet | Saxophone | Ruby Ring | |
| Pine Ridge House | Espresso Machine, Gaming PC | Modern Art | Jewelry Box | Diamond Necklace |
| Aspen House | Robot Dog, VR Headset | Golden Trophy | Limited Sneakers | Sapphire Tiara |
| Grand Mansion | Gold Bars, Ancient Vase | Masterpiece Painting | Royal Crown | Giant Diamond, Pharaoh Mask |

</details>

![The street](docs/preview-houses.png)

![Inside a house](docs/preview-interior.png)

### 🌙 Night and ☀️ Daytime

Heists happen at night. Every **4 minutes** the clock at the top of the screen runs through:

- **🌙 Night, 3½ minutes.** Every house is open for business.
- **☀️ Daytime, 30 seconds.** The owners come home. Every house locks up, alarms stop, lasers switch off, and anyone still on a property is shown out to the pavement (you keep whatever you're carrying). Then **every house restocks all of its loot**.

Daytime is the only time loot comes back, so a house you've emptied stays empty until the next sunrise. Use the daytime to unload, upgrade or train.

### 📖 Loot Index

Press **📖 LOOT INDEX** to see every item in the game, grouped by house, each with a little 3D picture. Items you haven't stolen yet are black silhouettes marked **???**. Steal one and it's unlocked for good: it's saved with your progress, and a toast announces each new discovery. A red badge on the button counts discoveries you haven't looked at yet, and completed houses get a ✅.

### 📦 Warehouse storage

Hold **E** on any item on your shelves — or press the **📦 STORAGE** button on the HUD — to open your warehouse storage. Every stored item is listed with its value and the cash it earns you per second, and each row has two buttons:

- **🎒 TAKE** unequips it: the item comes off the shelf and back into your bag (so you can carry it, load it into a car, or move it to another plot's deposit pad).
- **💰 SELL** sells it for cash on the spot and frees the shelf.

Only you can do either of those in your warehouse; the server checks every action. Taking an item back stops it earning income until you stash it again.

### 💰 The sell point

The second market stall in the middle of the yard is run by a trader who buys loot outright. Hold **E** at the counter to open the window:

- Everything in your **bag** is listed with its price. **💰** sells one item, **🤑 SELL EVERYTHING** sells the lot.
- Park your **car within 45 studs** of the stall and the **trunk** is included too — handy for unloading a full haul without going home. The window watches for your car and updates itself when it's close enough.

Selling is instant cash (no shelves involved), which makes it the fastest way to fund an upgrade after a big run.

![The market stalls in the yard](docs/preview-stalls.png)

### ✨ Glowing loot

Anything **Epic or Legendary** glows in the colour of its rarity — Epic items are wrapped in a purple aura, Legendaries in gold — so you can spot the good stuff across a room, and see at a glance what's worth grabbing first. Rarity colours match the **📖 Loot Index** and the shop.

### Upgrades (at the market stall)

| Upgrade | Levels | What it does |
|---|---|---|
| 🎒 Loot Bag | 2 → 12 items | Carry more loot on foot |
| 🏎️ Getaway Engine | 45 → 110 mph | Faster car, plus new paint, a spoiler, racing stripes and underglow |
| 🧳 Trunk Space | 4 → 25 items | Bigger car trunk |
| 📦 Warehouse Space | 10 → 50 slots | More shelves means more passive income |
| 🏃 Treadmill | 2 → 34 XP/s | Your treadmill trains you faster (see below) |

If your warehouse is full, depositing better loot automatically sells your cheapest item to make room. You can also sell — or take back — any shelf item yourself in **📦 STORAGE** (hold E on it).

### 🏃 Your treadmill

Every garage has its own treadmill out front, to the left of the loading dock. A **YOUR TREADMILL** sign floats over yours.

- **Walk onto the belt** and your character starts running by itself. Your movement keys switch off, so you can go AFK and keep getting faster.
- Press **ESCAPE**, **Space**, or **A** on a gamepad to hop off beside it. Walk back on to run again.
- Each speed level adds **+1 walk speed**, from 16 up to 66 at max level.
- You upgrade the treadmill itself, either at the market stall in the yard or by holding **E** at its console. Its trim gets flashier with every level, and only you can use or upgrade yours.

| Treadmill level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Speed XP per second | 2 | 3 | 5 | 8 | 12 | 17 | 24 | 34 |
| Price | free | $300 | $1,200 | $4,000 | $12,000 | $35,000 | $90,000 | $220,000 |
| Walk speed 16 → 66 from scratch | ~24 min | ~16 min | ~10 min | ~6 min | ~4 min | ~3 min | ~2 min | ~1.4 min |

![A warehouse treadmill](docs/preview-treadmill.png)

> Roblox itself disconnects anyone who gives no input for about 20 minutes. That's a platform rule a game can't turn off, but progress is saved when they leave.

![Mansion interior](docs/preview-cutaway.png)

## 💾 Saving progress

Progress saves with DataStores: cash, upgrades, speed, warehouse items, trunk contents and your Loot Index. Loot you're *carrying* doesn't save, so stash it! (Saves from before the Loot Index start with the items they already own unlocked.)

DataStores only work in a **published** game:

1. **File → Publish to Roblox**.
2. **Game Settings → Security → Enable Studio Access to API Services** (to test saving inside Studio).

Unpublished, the game still runs normally and shows a small "progress won't be saved" message.

> The yard has **6 garages**, so set **Max Players = 6** when you publish (Game Settings → Places). If more people join, they can still play: their loot is sold for cash at any deposit pad.

## 🛠️ Customizing

Every number lives in **[`src/shared/Config.luau`](src/shared/Config.luau)**: upgrade prices and values (including the treadmill's XP per second), guard speeds, lockpick times, how long the night and daytime last (and the sky colours), income rate, car handling and sounds.

- **The street:** `Config.Houses` lists every house in order, with its name, difficulty tier and guard. `Config.Guards` names the guards. The map builder reads both, so rebuild after changing them.
- **Add or change loot:** [`src/shared/Items.luau`](src/shared/Items.luau). Each item belongs to one house and is a small model built from parts, so no uploads are needed.
- **Guard looks:** [`src/shared/Guards.luau`](src/shared/Guards.luau) builds the cats and dogs from parts. Every dog breed is the same builder with different proportions, ears, tail and markings.
- **Skip to daytime while testing:** during Play, switch the command bar to the server and run `require(game.ServerScriptService.Server.DayNight).advance()`.
- **The yard:** the garages are laid out by `YARD_PLOTS` in [`tools/map_builder.py`](tools/map_builder.py), which also draws the cliffs around the spawn — edit them together if you move things.
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
    Plots.luau               personal warehouses, shelves, deposit pad, storage window back end
    Market.luau              the 💰 SELL POINT: list what you're carrying, sell one or all
    DayNight.luau            the 4-minute clock: 3½ min night, 30 s daytime (houses close + restock)
    Houses.luau              doors, per-house loot, alarms, guard cats/dogs/drones, lasers, busting
    Vehicles.luau            getaway car (hover physics, seats, trunk, dock unloading)
    Treadmills.luau          personal treadmills: AFK speed training, console upgrades
    Economy.luau             income ticks + upgrade purchases
    Notify.luau              toast notifications
  client/                  → StarterPlayerScripts.Client
    init.client.luau         builds the UI, listens to the server
    Hud / Shop / Notifications / BustedScreen / UI.luau
    Storage.luau             the warehouse window: take items off the shelves or sell them
    SellPoint.luau           the trader's window: sell your bag (and your trunk)
    LootIndex.luau           the collection book (3D pictures, ??? until stolen)
    DayNight.luau            fades the sky between night and daytime
    VehicleController.luau   driving
    TreadmillController.luau auto-running on your treadmill, ESCAPE / Space to hop off
    WorldEffects.luau        sirens, treadmill belts, loot auras, "your warehouse" marker
  shared/                  → ReplicatedStorage.Shared
    Config.luau  Items.luau  ItemModels.luau  Guards.luau  Format.luau
tools/
  build_place.py           builds StealAnItem.rbxlx from src/ + the generated map
  map_builder.py           procedural town (the house design, cube cliffs, Mansion, the yard + garages, roads)
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
python3 tools/run_luau_tests.py --database database.json      # 71 tests (needs the `luau` CLI)
luau-lsp analyze --settings .vscode/settings.json --platform roblox \
  --sourcemap sourcemap.json --definitions=@roblox=globalTypes.d.luau src   # type-check
```

- `database.json` is Rojo's API dump ([rbx-dom](https://github.com/rojo-rbx/rbx-dom/blob/master/rbx_dom_lua/src/database.json)). `luau` and `luau-lsp` come from their GitHub releases.
- The integration tests run the real server and client scripts against a small mock of the Roblox engine. That mock loads the real generated map and rejects invalid properties, just like Roblox does. They play through joining, lockpicking, stealing (and discovering items), getting busted by a cat, escaping, depositing, earning, upgrading, AFK treadmill training (including hopping off with Space), driving, managing storage (taking an item off a shelf, selling it, a full-bag refusal), selling carried loot and a parked trunk at the sell point, the Loot Index UI, the loot auras, a full daytime (houses locking, everyone shown out, every house restocking), and saving then loading.
- **Rojo (optional):** open `StealAnItem.rbxlx` in Studio, run `rojo serve`, and connect the Rojo plugin to live-sync `src/` while you edit.
