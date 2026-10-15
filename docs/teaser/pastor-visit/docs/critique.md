# Critique log: pastor-visit

Note on brand score: the brief explicitly asks for the screens the prototypes lack to be designed in their
own components and flagged (see ../../JOURNEYS-NEW-SCREENS.md), so designed states are not scored as invented UI.

## Round 1
| hook | read | motion | variety | brand | sync | min |
|  5   |  6   |   7    |    7    |   8   |  8   |  5  |

Worst three (most damaging first):
1. [beat 0-1, all] Frame 0 is a laptop sliding in with no type; the headline only starts at beat 0.65 -> nothing tells a scroller what this is -> start the kicker/headline at beat -0.6 and the laptop at -1 so frame 0 already reads "A pastoral visit".
2. [beats 48, 58, all] The soft wipe between the three answers peaks at full opacity, so one frame shows an empty white phone -> reads as a glitch -> cap the wipe at 0.5 and shorten it to 0.25 beats.
3. [beats 66-83, 16x9 + 9x16] Outcome cards are unreadable at phone size (board at zoom 1.35; 9:16 window only 900 px tall) -> zoom to the active card (1.8 / 2.0 / 1.8) and make the 9:16 window 1100 px tall.

Also: end card's first frame is empty (logo spring starts at 0) -> pre-roll the logo 0.35 beats; beats 92-100 hold one static split for 5 s -> add a slow push on both devices.

Checks failed: hook frame; longest gap 92-100 (5 s, no new event).
Verdict: ANOTHER ROUND

## Round 2
| hook | read | motion | variety | brand | sync | min |
|  7   |  8   |   8    |    8    |   8   |  8   |  7  |

Worst three:
1. [beat 0, all] Title is on frame 0 now, but its second line is still mid-rise and reads as clipped -> pre-roll the caption to beat -1.1.
2. [beats 92-100, 16x9] The final laptop view sits on empty board space under the confirmed card -> refocus to (900, 470).
3. [beats 72-77, 16x9] The declined view shows a lot of sidebar; acceptable because the card and its red note are fully legible, so left as is.

Checks failed: none (longest gap now 92-100 with the push and a slow push-in).
Verdict: ANOTHER ROUND (round 3 is the minimum)

## Round 3
| hook | read | motion | variety | brand | sync | min |
|  8   |  8   |   8    |    8    |   8   |  9   |  8  |

Worst three (remaining, minor):
1. [beat 0, 16x9] Title now fully landed on frame 0 in every format.
2. [laptop shots, 16x9] Whole-board views are small at phone size; every action shot zooms to the field or card being changed, which is what carries the story.
3. [16x9] Headline column capped at 600 px so long titles never touch the laptop.

Sync: 40-48 hits within 20 ms of an onset (median about 2 ms); the rest are deliberate off-beat accents. Mix -14.1 LUFS, true peak <= -1.1 dBTP.
Checks failed: none.
Verdict: READY
