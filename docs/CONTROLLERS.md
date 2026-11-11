# MIDI controllers and the Armed LED

A MIDI controller can do two things with TC Trigger:

1. **Buttons:** Arm/Disarm Toggle, Arm, Disarm, Fire Next Cue and Panic, set up with **Learn** in
   **Settings → MIDI control**.
2. **Armed light:** under **Settings → Armed LED feedback**, TC Trigger sends a MIDI message
   whenever the armed state changes, at launch, and when the controller reconnects, so a
   light on the controller always shows the true state.

There are two ways to set the light message (**LED message**):

| Option | Sends | Use it when |
|---|---|---|
| **Echo the learned button** | the learned button's own note or CC: 127 armed, 0 disarmed | the controller lights a button when it receives that button's own message (e.g. Korg nanoKONTROL2 with LED Mode = External) |
| **Custom messages** | any Note, CC or Program Change you choose, separately for armed and disarmed (or nothing) | the controller wants a different message (Morningstar), or uses values as colours (Launchpad, APC) |

**Send Now** sends the current state, which is handy while setting up.

## Morningstar MC8 Pro (also MC6 / MC10)

The Morningstar controllers fit this well. Each switch has its own screen and colour LED, and
two **toggle positions**, each with its own name and colour. According to Morningstar's
[MC8 Pro manual](https://help.morningstar.io/en/article/mc8-pro-user-manual-1yqqr1r/) (MIDI
implementation), on the controller's own MIDI channel:
- **CC 2** with value *n* ("Engage Toggle") puts switch *n* into **position 2**
- **CC 3** with value *n* ("Disengage Toggle") puts it back into **position 1**
- *n* = 0 for switch A, 1 for B, and so on up to 23 for X

TC Trigger has a **Fill In** button for exactly this. Position 1 = **disarmed**, position 2 =
**armed**.

> Tested with a simulated controller that receives exactly these messages. Not yet tried on a
> real MC8 Pro, so the first time, click **Send Now** and check the switch flips.

### 1. Connect

1. Connect the MC8 Pro to the Mac with USB. It appears as a MIDI device.
2. Note the MC8's **MIDI Channel**. It's set on the controller under E+H → Global Config, or in
   the Morningstar Editor under Controller Settings → General Configuration.

### 2. Program the ARM switch (Morningstar Editor)

Pick a switch (this guide uses **A**) in the bank you'll leave open during services.
1. Turn **Toggle Mode** on for the switch.
2. **Position 1:** name it **DISARMED** with a red or dim colour. Add a message: *Press → CC
   20, value 127* on any channel. This is "Arm".
3. **Position 2:** name it **ARMED** with green. Add a message: *Press → CC 21, value 127* on
   the same channel. This is "Disarm".
4. Optionally, add plain (non-toggle) switches for **Fire Next** (e.g. *Press → CC 22, value
   127*) and **Panic** (*Press → CC 23, value 127*).

The switch then always shows the current state, and pressing it does the opposite.

Use any free CC numbers; 20–23 are just examples. Avoid the MC8's own channel for these
messages if other gear listens on it.

### 3. Set up TC Trigger

1. **Settings → MIDI control → Controller input:** choose the MC8 Pro.
2. **Learn → Arm**, press switch A (it sends CC 20). The switch moves to position 2.
3. **Learn → Disarm**, press switch A again (it sends CC 21). It moves back to position 1.
4. Learn **Fire Next Cue** and **Panic** on their switches, if you made them.
5. **Armed LED feedback → Feedback output:** choose the MC8 Pro.
6. **LED message:** choose **Custom messages**.
7. In the **Morningstar MC6/MC8/MC10** row, choose **Switch A** and the MC8's channel, then click
   **Fill In**. "When armed" becomes CC 2 = 0 and "When disarmed" becomes CC 3 = 0 on that
   channel.
8. Click **Send Now**. Switch A should show **DISARMED**, or **ARMED** if TC Trigger is armed.

### 4. Test

- Click **Arm** in TC Trigger. Switch A should flip to **ARMED** without being pressed.
- Press switch A. TC Trigger should disarm, and the switch should show **DISARMED**.
- Unplug and replug the MC8. After it reconnects, the switch shows the right state again.
- The Logs tab shows each press (`midi.control`). With Verbose on, it also shows each message
  sent to the MC8 (`midi.out`).

### Things to know

- **Toggle states belong to the current bank.** Leave the ARM switch's bank open during services,
  or put the same ARM switch at the same letter in every bank. If you scroll banks and the
  state looks wrong, click **Send Now** or arm/disarm once.
- In the Morningstar Editor, turning on **Remember Toggle States** (Controller Settings) keeps
  positions when you scroll through banks.

## Other controllers

These are typical setups. Check your controller's manual for the exact values.

- **Korg nanoKONTROL2:** in Korg Kontrol Editor, set **LED Mode** to **External**. Use **Echo the
  learned button**.
- **Novation Launchpad / Akai APC mini** (in a custom or programmer mode): note velocity selects a
  colour. Use **Custom messages**, with the pad's note at a green velocity when armed and a red
  (or 0 = off) velocity when disarmed. Some APC models also use the MIDI channel for brightness
  or blinking.
- **Behringer X-Touch Mini / X-Touch One** (standard mode): button LEDs follow incoming Note On.
  Some modes use 1 = on and 2 = blink, so use **Custom messages** with the values your mode
  expects.
- **Elgato Stream Deck with Bitfocus Companion:** add Companion's generic MIDI module, send
  TC Trigger's armed message to it, and use Companion feedback to colour a key ARMED/DISARMED.
  Map a key to send the Arm/Disarm message back to TC Trigger.
- **Controllers that only take SysEx** for their lights aren't supported. TC Trigger sends notes,
  CCs and program changes.
