# Iris assistant protocol

**This document lives in publik, not here.**

<https://github.com/Blueturboguy07/publik/blob/main/docs/iris-assistant-protocol.md>

It is the contract between the publik backend and every client in this
repository — transports, grounding, sessions, identity, privacy, the watch-loop
model budget, the autopilot fix protocol. The backend implements one side of it
and the clients here implement the other, so it belongs with the side that can
change unilaterally.

A copy came across in the split and was replaced with this pointer the same day.
Two copies of a contract is how the contract stops being one.

Note that it was last substantially revised on 2026-08-08 and says nothing about
maintain mode, Tier C, the on-demand edit loop or the verification ladder — the
four largest subsystems in `iris-macos/`, all built after it.
