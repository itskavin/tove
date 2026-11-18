# Hermes orb

The live voice orb (redesign spec §5.1, §6.1, §6.2, §7.3, §8.2). Import
`orb.dart`.

```dart
HermesOrb(
  state: OrbState.assistantSpeaking, // idle, connecting, listening, userSpeaking,
                                     // thinking, assistantSpeaking, muted, ended, error
  size: Sz.orbCentered(width),       // rest diameter D = layout box
  levels: call.levels,               // ValueListenable<AudioLevels>, or
  // level: someEnergy,              // ValueListenable<double> 0..1 (one or the other)
  docked: hasContent,                // 0.41 × in 260 ms; or dock: 0..1 to drive it yourself
  engine: orbEngine,                 // optional: keeps motion continuous across moves
  active: visible,                   // false stops the ticker (hidden/offscreen)
)
```

- **Levels.** `levels` (raw WebRTC) is normalised with `min(1, sqrt(x × 3.2))`;
  input drives user reactions, output Hermes' reactions. `level` is one 0..1
  energy read per state (user in idle/listening/userSpeaking, Hermes in
  assistantSpeaking/muted). Smoothing (attack τ 60 ms, release τ 350 ms) is in
  `OrbEngine`, not the shader. Unknown levels are silence; speech is never faked.
- **Dock.** The widget only shrinks the circle around its box centre. Move the
  box yourself in sync (`OrbEngine.dockDuration` / `dockCurve`, and
  `undockDuration` / `undockCurve`), or animate both from one controller and
  pass `dock:`.
- **Renderer.** `OrbRenderer.resolve` picks the shader (`shaders/orb.frag`)
  only on native platforms, when `RenderPolicyScope.shaderOrb` allows it,
  motion is not reduced and the program has loaded. Otherwise it uses the gradient
  painter (`orb_fallback.dart`). A load failure calls `RenderPolicy.shaderFailed()`.
  Call `OrbShader.precache()` early (from `main`); `OrbShader.status` and
  `HermesOrbState.usesShader` say what is in use.
- **Frames.** One ticker, only while `active`, not muted by `TickerMode`, motion
  not reduced, and until the `ended` fade (220 ms) finishes. Each tick repaints
  only the orb's `RepaintBoundary` (the painter listens to the engine); no widget
  rebuilds, no save layers, no backdrop filters.
- **Reduced motion** (`Motion.reduced` or `reduceMotion:`): a still gradient
  sphere; state changes step instantly; audio shows as a 2 dp ring. No frames
  are scheduled.
- **Demo.** `OrbDemoPage` (`orb_demo.dart`) cycles every state with a fake level,
  with toggles for dock, painter and reduced motion.
- **Choreography** (`orb_choreography.dart`): `OrbChoreographer` moves the orb between `OrbStage.centred` and
  `OrbStage.docked` poses (`OrbChoreography.pose`) with springs tuned to the measured dock timings, adds speaker
  nudges (`react`) and an interruption flinch. Set `engine.choreographer = c`: the orb's single ticker steps it,
  and the engine takes its dock factor from it. The caller positions the orb box from `c.centre` / `c.pulse` at
  paint time (live mode uses a `Flow`). Set `c.reduced` for reduced motion (snap, no nudges).
