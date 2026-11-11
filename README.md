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
