class_name RulesVersion
extends RefCounted

## Bumped whenever game rules or card data (data/cards/*.json) change in a way
## that makes an old client's idea of the rules differ from the server's.
## Ranked matches run on the server (see specs/003-authoritative-ranked-server);
## a client whose version differs is told to update before it can queue.
## Bump rule: any change to scripts/game/{game_state,player_state,minion,abilities}.gd
## behavior, or to data/cards/*.json costs/stats/abilities/effects, increments this.
## 2: Junk Blockade (b_010) gained on_play_recon_if_fewer_cards - its card
##    text promised a conditional Recon that nothing implemented.
## 3: Sludgewalker Scout gains Recon; Ancient Abominable becomes 11/11
##    and Gate Yeti becomes 3/3.
## 4: Headshot card batch, damage-triggered Rummage, permanent card stats,
##    returned-card draw identity, and removal of Crypt Chapel.
## 5: Plated Soldier becomes 2/3; Frontier Medic becomes 1/3.
## 6: Dump Scummer becomes 2/4; Debris Hauler loses unintended Cloaked.
## 7: Human ranked second-player opening choice; named bot games keep baseline.
## 8: Moon bots use the same opening choice in ranked, ranked AI and simulations.
## 9: Patch 0.0.2 eight-card buff batch; Icewhip buffs before Challenge.
## 10: Remaining Orange 0.0.2 buffs, Rush Morph Drones and board-wide Carbon Mesh.
## 11: Stinkpile/Rust Grenade nerfs and Decaying Junkling's symmetric on-play damage.
## 12: Twin Fang attack reduced from 3 to 2.
## 13: Four-mana Serene Yeti becomes Ambusher Yeti 3/4; Requisitioner becomes 3/5.
const RULES_VERSION := 13
