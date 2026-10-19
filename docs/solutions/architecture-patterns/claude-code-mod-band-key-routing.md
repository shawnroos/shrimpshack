---
title: "Which keys a mod's band above the prompt can receive"
date: 2026-10-19
module: plugins
problem_type: architecture_pattern
component: tooling
severity: medium
category: architecture-patterns
tags:
  - claude-code
  - mods
  - abovePrompt
  - keyboard
  - focus
applies_when:
  - "designing keyboard control for a mod band (ui.render AbovePrompt)"
  - "wanting Tab, Shift-Tab or arrow keys to drive a mod's own actions"
  - "choosing between a Client surface module and Buttons with hotkeys"
---

## Context

We wanted "Tab = next task, arrows = steps" in a band above the prompt. We
tested it in a real Claude Code 2.1.303 session inside tmux, with a throwaway
mod. The band held three Buttons (hotkeys a, b, g) and one `Client` whose
`onKey` logged every key. Hooks on `ui.focus` and `ui.press` logged too.

## What happened

| How the band got focus | Tab, Shift-Tab, arrows | Reached `onKey`? |
|---|---|---|
| Not focused | Tab and arrows stay with the prompt. Shift-Tab cycles the permission mode. Left opens the agents list. | No |
| ctrl+x tab, band has Buttons | The engine's focus ring moves. Tab, Right and Down go to the next Button. Shift-Tab, Left and Up go to the previous one. It wraps at the end. | No |
| ctrl+x tab, band has only a Client | Nothing in the band takes the keys. Shift-Tab cycled the permission mode. | No |
| Click on band text or empty band space | The band takes focus with the ring on the first Button. Then the same as ctrl+x tab. | No |
| Click on a Button | The Button is pressed. The band does not take focus. | No |
| Click on the Client's own region | Each key arrives as its own event: `tab`, `tab`+shift, `up`, `down`, `left`, `right`. Letters and Enter (`return`) arrive too. The ring does not move. Escape gives focus back to the prompt. | Yes |

Letter hotkeys on Buttons (`a`, `g`) pressed their Button after ctrl+x tab.
While the Client holds the keyboard, the Client takes every key: `a` reached
`onKey` and did not press the `a` Button. Client focus and Button hotkeys do
not work at the same time.

## Guidance

- Distinct Tab and arrow keys need a `Client`, and only after a click on the
  Client's own region. ctrl+x tab never gives the Client the keyboard.
- The `ui.focus` hook cannot tell Tab from Down, or Shift-Tab from Up. It only
  sees which Button the ring is moving to.
- For keyboard use after ctrl+x tab, use Buttons with letter or digit hotkeys.
  Treat Tab and the arrows as "next Button" and "previous Button".
- Mouse needs the terminal to report it. The probe ran in fullscreen, where
  Claude Code turns mouse reporting on.

## Probe

Throwaway mod and logs were in the session scratchpad, not in the repo. The
key evidence lines:

```
{"src":"ui.focus","component":"AbovePrompt","element":"alpha","origin":{"kind":"person"}}   ctrl+x tab
{"src":"ui.focus","component":"AbovePrompt","element":"gamma","origin":{"kind":"person"}}   Right
{"via":"client","src":"onKey","key":"tab","shift":true}                                    Shift-Tab after Client click
{"via":"client","src":"onKey","key":"up"}                                                  Up after Client click
```
