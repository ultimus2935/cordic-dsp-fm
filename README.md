# cordic-dsp-fm
Hardware-accelerated DSP implementing CORDIC-based frequency modulation on realtime audio signals, allowing dynamic control over modulation parameters.

The current design is made for and tested on the Avnet Zedboard. Constraints (.xdc) file will have to be edited accordingly to run on other devices.

## Keypad controls (PMOD KYPD on JA)

```
[ 1 ][ 2 ][ 3 ][ A ]    0-9  type a value          A    next parameter
[ 4 ][ 5 ][ 6 ][ B ]    D    enter (apply)         B    modulation type
[ 7 ][ 8 ][ 9 ][ C ]    C    clear typed digits    E/F  step up/down (hold = repeat)
[ 0 ][ F ][ E ][ D ]    BTNC freeze/unfreeze display
```

| # | Parameter | Typed as | Step | Range | Default |
|---|---|---|---|---|---|
| 0 | Carrier freq `fc_hz` | Hz | 50 | 100–12000 | 1000 |
| 1 | Modulating freq `fm_hz` | Hz | 5 | 1–3000 | 50 |
| 2 | Modulation index `beta_x10` | tenths (25 = 2.5) | 0.5 | 0–20 | 2.0 |
| 3 | Amplitude `amp_pct` | % | 5 | 0–100 | 80 |
| 4 | VGA timebase `tb_log2` | 1,2,4…64 | ×2 | 1–64 | 1 |

LEDs (SW0 off): LD0–LD4 = selected parameter (one-hot), LD5–LD6 = modulation type
(00 FM, 01 PM, 10 AM, 11 bypass), LD7 = status (slow blink typing, short flash applied,
fast blink value clamped). Key map lives in the `KEY_*` localparams in `param_ctrl.v`.

Ready-to-use NCO phase increments are provided in `top_module.v`: `fc_fcw`, `fm_fcw`
and `dev_fcw` (= beta·fm), all `f · 2^32 / fs` with fs = 32 MHz / 667. `param_update`
pulses for one cycle whenever any parameter changes.

Simulate: `iverilog -g2012 src/simulation/tb_keypad.v src/design/pmod_kypd.v src/design/param_ctrl.v && vvp a.out`

## Live debugging with VIO (optional)

1. With the Vivado project open, run `source src/ip/create_vio.tcl` in the Tcl console. It creates `vio_0` and sets the `USE_VIO` define.
2. Generate the bitstream and program the board (Vivado loads the `.ltx` probes file too). Open the **hw_vio_1** tab, add all probes, and set them to unsigned decimal.

| Probe | Signal | What to check |
|---|---|---|
| in0 | `mic_audio_data` (12 b) | ~2048 in silence, swings when you speak |
| in1 | `vu_level` | VU bar pattern |
| in2–in5 | `fc_hz`, `fm_hz`, `beta_x10`, `amp_pct` | parameter values |
| in6 | `{tb_log2, mod_type, sel_param}` | [2:0] selected param, [4:3] mode, [7:5] timebase |
| in7 | `entry_value` | digits being typed |
| in8 | `{key_held, key_code}` | last key pressed, held flag |
| in9 | `fc_fcw` | carrier phase increment |
| in10 | `{disp_freeze, sys_rst, clk_locked}` | expect freeze toggling, reset 0, locked 1 |
| out0 / out1 / out2 | `vio_key` / `vio_press` / `vio_en` | with `vio_en` = 1, set a key and toggle `vio_press` 0→1→0 to inject one press |

VIO refreshes every few hundred ms, so `mic_audio_data` shows snapshots, not a waveform. Use an ILA for waveforms and single-cycle pulses. To build without VIO, clear the define: `set_property verilog_define {} [current_fileset]`.
