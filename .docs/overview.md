# Project Overview

A Hearthstone-style card game built in **Godot 4.3** (GDScript). Single-player vs AI, 1280×720, Forward Plus renderer. Future plans include online multiplayer via Nakama.

## Tech Stack

- **Engine:** Godot 4.3 (GDScript)
- **Future networking:** Nakama game server
- **Card data:** JSON files per color faction

## Game Design

- **5 colors:** GREEN, CRIMSON, BLACK, ORANGE, TEAL
- **Deck building:** 30 cards, 1–2 colors per deck
- **Card types:** CREATURE (played to battlefield) and STRATAGEM (instant spell effect)
- **Keywords:** Guardian/Taunt (must be attacked first), Rush/Charge (can attack immediately), Reinforce
- **Turn structure:** Hearthstone-style — gain 1 mana crystal per turn (max 10), draw 1 card, take actions in any order, end turn
- **Win condition:** Reduce opponent hero to 0 HP (both start at 30)
- **Board limit:** Max 7 creatures per side

## Running the Game

Open the project in Godot 4.3 and press **F5** (or the Play button). There is no CLI build step — all development happens inside the Godot editor.

Main scene: `res://scenes/game/Main.tscn`
