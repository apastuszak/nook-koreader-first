-- KOReader custom key map (koreader/settings/event_map.lua), merged into KOReader's own
-- at start-up. Android key codes on the left, KOReader key names on the right.
-- Makes the four page buttons of the Nook GlowLight 4 and 4 Plus turn pages: the upper buttons on
-- both sides go forward, the lower ones back.
--
-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
   [139] = "LPgBack", -- Nook Left Page Back (left lower button)
   [140] = "LPgFwd",  -- Nook Left Page Forward (left upper button)
   [141] = "LPgFwd",  -- Nook Right Page Forward (right upper button)
   [142] = "LPgBack", -- Nook Right Page Back (right lower button)
}
