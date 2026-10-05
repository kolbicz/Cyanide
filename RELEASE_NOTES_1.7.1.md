# Cyanide 1.7.1

Polish and stability for the Process Viewer.

## Fixes

- Fixed the main cause of a **black screen on launch** after using the Process Viewer. If you still hit one, please report it with a log.
- The **large title** no longer shrinks and re-centers when you open the viewer.
- The list no longer **jumps down** when the process count appears.

## Improvements

- **Force Quit starts faster**, and the first kill's "finishing kill" banner now sits at the top and only shows for that first, slower kill — no more flicker on quick ones.
- Cyanide now **releases the privileged session on its own** about ten seconds after a kill.
- **Verbose logging** moved to Settings → Launch Options (it now also covers exploit runs and tweak applies, and it sticks across launches).

## About A18 / M4

On A18 / M4 devices a run has about a 50/50 chance of rebooting the device (a
kernel "panic") instead of succeeding — a known limit of these chips that can't
be fully fixed. It's a coin flip, so if it reboots, just try again; a few
attempts usually gets there. Once a run works, it stays working until your next
restart.

If you keep hitting panics, Settings → Launch Options has four knobs for the
A18 chain — exploit path (pe_v1 / pe_v2), memory shaping, interleaved search
and bounded search. Defaults are unchanged in this release; other combinations
may do better on your device. Each applies to the next fresh run.
