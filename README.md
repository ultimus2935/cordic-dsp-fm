# cordic-dsp-fm
Hardware-accelerated DSP implementing CORDIC-based frequency modulation on realtime audio signals, allowing dynamic control over modulation parameters.

The current design is made for and tested on the Avnet Zedboard. Constraints (.xdc) file will have to be edited accordingly to run on other devices.

## Board switches and outputs

| Control | Function |
|---|---|
| BTNR | Reset |
| SW0 | LEDs: 0 = keypad status, 1 = VU meter (mic level) |
| SW1 | Message source: 0 = internal test tone at fm, 1 = microphone |
| SW2 | Audio RAM storage: 0 = circular continuous record, 1 = freeze buffer (Scope 4) |
| SW7 | DA2 channels: 0 = A modulated / B mic, 1 = A mic / B modulated |

Pmods: KYPD on JA, DA2 on JC, MIC3 on JD (top row of pins). The DA2 has no jack:
use a small amp / powered speaker or a scope on VOUTA / VOUTB.

In mic mode the mic's DC offset is removed (running mean, ~30 Hz high-pass) and
a full-scale mic swing gives the full FM deviation beta*fm; turn the gain pot on
the MIC3 up if the effect is weak.

## Keypad controls (PMOD KYPD on JA)

```
[ 1 ][ 2 ][ 3 ][ A ]    0-9  type a value          A    next parameter
[ 4 ][ 5 ][ 6 ][ B ]    D    enter (apply)         B    modulation type
[ 7 ][ 8 ][ 9 ][ C ]    C    clear typed digits    E/F  step up/down (hold = repeat)
[ 0 ][ F ][ E ][ D ]
```

| # | Parameter | Typed as | Step | Range | Default |
|---|---|---|---|---|---|
| 0 | Carrier freq `fc_hz` | Hz | 50 | 100–12000 | 1000 |
| 1 | Modulating freq `fm_hz` (mic mode: deviation scale) | Hz | 5 | 1–1000 | 50 |
| 2 | Modulation index `beta_x10` | tenths (25 = 2.5) | 0.5 | 0–10 | 2.0 |
| 3 | Amplitude `amp_pct` | % | 5 | 0–100 | 80 |

LEDs (SW0 off): LD0–LD3 = selected parameter (one-hot), LD4 unused, LD5–LD6 = modulation type
(00 FM, 01 PM, 10 AM, 11 carrier only), LD7 = status (slow blink typing, short flash applied,
fast blink value clamped). Key map lives in the `KEY_*` localparams in `param_ctrl.v`.

Ready-to-use NCO phase increments are provided in `top_module.v`: `fc_fcw`, `fm_fcw`
and `dev_fcw` (= beta·fm), all `f · 2^32 / fs` with fs = 32 MHz / 667. `param_update`
pulses for one cycle whenever any parameter changes.

Full-system simulation (all Pmods modelled):
`iverilog -g2012 -o tb_top src/simulation/tb_top.v src/simulation/models/clk_wiz_0_sim.v src/design/*.v && vvp tb_top`
(do not add `models/clk_wiz_0_sim.v` to the Vivado project).

Keypad-only simulation: `iverilog -g2012 src/simulation/tb_keypad.v src/design/pmod_kypd.v src/design/param_ctrl.v && vvp a.out`

## Live debugging with VIO (optional)

1. With the Vivado project open, run `source src/ip/create_vio.tcl` in the Tcl console. It creates `vio_0` and sets the `USE_VIO` define.
2. Generate the bitstream and program the board (Vivado loads the `.ltx` probes file too). Open the **hw_vio_1** tab, add all probes, and set them to unsigned decimal.

| Probe | Signal | What to check |
|---|---|---|
| in0 | `mic_audio_data` (12 b) | ~2048 in silence, swings when you speak |
| in1 | `vu_level` | VU bar pattern |
| in2–in5 | `fc_hz`, `fm_hz`, `beta_x10`, `amp_pct` | parameter values |
| in6 | `{mod_type, sel_param}` | [2:0] selected param, [4:3] mode |
| in7 | `entry_value` | digits being typed |
| in8 | `{key_held, key_code}` | last key pressed, held flag |
| in9 | `fc_fcw` | carrier phase increment |
| in10 | `{sys_rst, clk_locked}` | expect reset 0, locked 1 |
| out0 / out1 / out2 | `vio_key` / `vio_press` / `vio_en` | with `vio_en` = 1, set a key and toggle `vio_press` 0→1→0 to inject one press |

VIO refreshes every few hundred ms, so `mic_audio_data` shows snapshots, not a waveform. Use an ILA for waveforms and single-cycle pulses. To build without VIO, clear the define: `set_property verilog_define {} [current_fileset]`.
