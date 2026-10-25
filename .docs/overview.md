# Project Overview

A Hearthstone-style card game built in **Godot 4.3** (GDScript). Single-player vs AI plus online multiplayer, 1920×1080, Forward Plus renderer.

## Tech Stack

- **Engine:** Godot 4.3 (GDScript)
- **Networking:** custom Node.js WebSocket relay (`server/relay.js`) — accounts, lobbies, ranked matchmaking, currency/shop (not Nakama). Ranked matches can run their rules on the server instead of on a player's client, in a headless Godot "match host" the relay spawns (behind `RANKED_AUTHORITATIVE`, off by default — see [Authoritative Server](authoritative-server.md))
- **Card data:** JSON files per color faction

## Game Design

- **5 colors:** GREEN, CRIMSON, BLACK, ORANGE, TEAL
- **Deck building:** 30 cards, 1–2 colors per deck
- **Card types:** CREATURE (played to battlefield), STRATAGEM (instant spell effect), and LOCATION (played to a battlefield slot; health only, never attacks, gives a passive buff until destroyed)
- **Keywords:** Guardian/Taunt (must be attacked first), Rush/Charge (can attack immediately), Reinforce
- **Turn structure:** Hearthstone-style — gain 1 mana crystal per turn (max 10), draw 1 card, take actions in any order, end turn
- **Win condition:** Reduce opponent hero to 0 HP (both start at 30)
- **Board limit:** Max 7 creatures per side

## Running the Game

Open the project in Godot 4.3 and press **F5** (or the Play button). There is no CLI build step — all development happens inside the Godot editor.

Main scene: `res://scenes/game/Main.tscn`
