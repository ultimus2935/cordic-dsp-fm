# Hardware Control Scheme & Interface Guide

### 1. Keypad Controls (PMOD KYPD on JA)

The 16-key keypad (`[0]–[9]`, `[A]–[F]`) controls parameter entry, parameter selection, modulation mode, and step tuning:

```
[ 1 ][ 2 ][ 3 ][ A ]     0-9 : Type numeric value for selected parameter
[ 4 ][ 5 ][ 6 ][ B ]     A   : Cycle selected parameter (fc -> fm -> beta -> amp -> fc ...)
[ 7 ][ 8 ][ 9 ][ C ]     B   : Cycle modulation scheme (FM -> PM -> AM -> CARRIER ...)
[ 0 ][ F ][ E ][ D ]     C   : Clear typed digits
                         D   : Enter / Apply typed value (with range clamping)
                         E/F : Step selected parameter UP / DOWN (hold to auto-repeat)
```

| Key | Function / What it changes | Details |
| :---: | :--- | :--- |
| **`0` – `9`** | **Digit Entry** | Types digits (up to 5 digits) for the currently selected parameter. |
| **`A`** | **Cycle Selected Parameter** | Cycles sequentially through parameters: <br> `fc` (Carrier Freq) $\rightarrow$ `fm` (Tone Freq) $\rightarrow$ `beta` (Modulation Index) $\rightarrow$ `amp` (Amplitude) $\rightarrow$ `fc`... |
| **`B`** | **Cycle Modulation Mode** | Cycles modulation scheme: <br> `FM` $\rightarrow$ `PM` $\rightarrow$ `AM` $\rightarrow$ `Carrier Only` (unmodulated) $\rightarrow$ `FM`... |
| **`C`** | **Clear** | Clears typed digits without modifying active parameters. |
| **`D`** | **Enter / Apply** | Clamps and applies the typed value to the active parameter. |
| **`E`** | **Step UP** | Increments the selected parameter by its step size (supports auto-repeat on hold: 400 ms delay, 100 ms interval). |
| **`F`** | **Step DOWN** | Decrements the selected parameter by its step size (supports auto-repeat on hold: 400 ms delay, 100 ms interval). |

#### Controllable Parameters & Ranges

| Index | Parameter | Description / Units | Step Size | Allowed Range | Default Value | Notes |
| :---: | :--- | :--- | :---: | :---: | :---: | :--- |
| **0** | **`fc`** | Carrier Frequency ($\text{Hz}$) | $50\text{ Hz}$ | $100\text{ Hz} - 12{,}000\text{ Hz}$ | $1000\text{ Hz}$ | NCO phase increment: $f_c \cdot 2^{32} / f_s$ |
| **1** | **`fm`** | Modulating Frequency ($\text{Hz}$) | $5\text{ Hz}$ | $1\text{ Hz} - 1{,}000\text{ Hz}$ | $50\text{ Hz}$ | Acts as deviation scale when mic source is selected |
| **2** | **`beta`** | Modulation Index in tenths | $5\text{ (0.5)}$ | $0 - 100\text{ (0.0 to 10.0)}$ | $20\text{ (2.0)}$ | Typed as tenths (e.g. typing $25 \rightarrow 2.5$) |
| **3** | **`amp`** | Output Amplitude percentage | $5\%$ | $0\% - 100\%$ | $80\%$ | Output scalar attenuation factor |

---

### 2. Slide Switches Functionality

The board slide switches control system operational modes, signal routing, data source selection, and diagnostic freezing:

| Switch | Signal Name | Pin (ZedBoard) | Default (`0`) | Active (`1`) | Detailed Description |
| :---: | :---: | :---: | :---: | :---: | :--- |
| **`SW0`** | `led_func` | `F22` | **Keypad UI Mode** | **VU Meter Mode** | Selects the display multiplexer for on-board LEDs `LD7:LD0`. When `0`, LEDs show keypad UI state, parameter selection, and modulation mode. When `1`, LEDs act as a real-time audio volume peak meter. |
| **`SW1`** | `msg_src_sw` | `G22` | **Internal Test Tone** | **Live Microphone** | Selects the modulating message source $m[n]$. When `0`, an internal DDS/CORDIC sine wave generator running at frequency $f_m$ drives modulation. When `1`, digitized acoustic audio from PMOD MIC3 (with DC offset removed) is used as the message. |
| **`SW2`** | `freeze_sw` | `H22` | **Live Recording** | **Buffer Freeze / Playback** | Controls the 2048-sample 7-series Block RAM circular audio buffer. When `0`, the buffer continuously records incoming `{mic, modulated}` sample pairs. When `1`, write recording is frozen and the captured 2048-sample audio buffer plays back in a continuous loop through PMOD DA2 for static oscilloscope inspection. |
| **`SW7`** | `da2_func` | `M15` | **Normal Channel Mapping** | **Swapped Channel Mapping** | Selects analog output assignment on dual-channel DAC (PMOD DA2). <br> • **`0`**: `VOUTA` = Modulated Signal, `VOUTB` = Original Mic Audio. <br> • **`1`**: `VOUTA` = Original Mic Audio, `VOUTB` = Modulated Signal. |

---

### 3. LED Behavior and Patterns (`LD7` – `LD0`)

The 8 on-board green LEDs display either Keypad Control Status or Audio VU Peak Meter based on switch **`SW0`** (`led_func`):

```
                      +-----------------------------+
       SW0 = 0 -----> | Keypad UI Status (kp_leds)  | ----+
                      +-----------------------------+     |
                                                          +---> [ LD7 .. LD0 ]
                      +-----------------------------+     |
       SW0 = 1 -----> | Audio VU Meter  (vu_level)  | ----+
                      +-----------------------------+
```

#### Mode A: Keypad UI Status (`SW0 = 0`)

$$\text{LEDs: } \underbrace{\text{LD7}}_{\text{Status}} \quad \underbrace{\text{LD6 \quad LD5}}_{\text{Modulation Mode}} \quad \underbrace{\text{LD4}}_{0\text{ (Unused)}} \quad \underbrace{\text{LD3 \quad LD2 \quad LD1 \quad LD0}}_{\text{Selected Parameter (One-Hot)}}$$

* **Selected Parameter Indicator (`LD3:LD0`)**: Active parameter highlighted in a 1-of-4 one-hot code:
  * `LD0` ON (`0001`): Carrier frequency **`fc`** selected.
  * `LD1` ON (`0010`): Modulating frequency **`fm`** selected.
  * `LD2` ON (`0100`): Modulation index **`beta`** selected.
  * `LD3` ON (`1000`): Output amplitude **`amp`** selected.
* **Unused Bit (`LD4`)**:
  * Permanently driven to `0` (OFF).
* **Modulation Scheme Indicator (`LD6:LD5`)**:
  * `00` (`LD6` OFF, `LD5` OFF): **Frequency Modulation (FM)**
  * `01` (`LD6` OFF, `LD5` ON) : **Phase Modulation (PM)**
  * `10` (`LD6` ON,  `LD5` OFF): **Amplitude Modulation (AM)**
  * `11` (`LD6` ON,  `LD5` ON) : **Carrier Only** (Unmodulated tone at $f_c$)
* **UI Status Indicator (`LD7`)**:
  * **OFF**: Normal / Idle state.
  * **Slow Blink (~2 Hz)**: Value entry in progress (user is actively typing digits).
  * **Solid ON (~200 ms pulse)**: Parameter successfully updated and applied (`D` pressed).
  * **Fast Blink (~8 Hz, 1 sec duration)**: Input clamped to valid range, digit overflow ($> 5$ digits), or step reached limit.

#### Mode B: Audio VU Meter (`SW0 = 1`)

When `SW0 = 1`, all 8 LEDs operate as an audio peak thermometer (bar-graph) meter driven by incoming microphone audio after DC offset removal. The VU meter features instantaneous peak capture and exponential decay ($333\ \mu\text{s}$ per step):

$$\text{Level Bar: } \text{LD7} \longleftarrow \text{LD6} \longleftarrow \text{LD5} \longleftarrow \text{LD4} \longleftarrow \text{LD3} \longleftarrow \text{LD2} \longleftarrow \text{LD1} \longleftarrow \text{LD0}$$

| LED Indicator | AC Amplitude Threshold (12-bit Peak Level) | Acoustic Intensity Range |
| :---: | :---: | :---: |
| **`LD0`** | $> 16$ | Minimal ambient sound detected |
| **`LD1`** | $> 32$ | Very low audio level |
| **`LD2`** | $> 64$ | Low audio level |
| **`LD3`** | $> 128$ | Moderate / conversational level |
| **`LD4`** | $> 256$ | Medium audio level |
| **`LD5`** | $> 512$ | Loud audio level |
| **`LD6`** | $> 1024$ | High audio level |
| **`LD7`** | $> 1536$ | Peak / full-scale microphone swing |

---

### Appendix: Pushbutton Functionality

| Button | Name / Label | Pin (ZedBoard) | Logic Level | Detailed Functionality |
| :---: | :---: | :---: | :---: | :--- |
| **`BTNR`** | Reset Button | `R18` | Active HIGH | **Master Synchronous System Reset** <br> • Generates an immediate asynchronous reset assert coupled with `~clk_locked` from the MMCM clock wizard (`clk_wiz_0`). <br> • De-assertion is passed through a 3-stage synchronizer clocked at $32\text{ MHz}$ (`sys_rst`), guaranteeing glitch-free, synchronized release across all synchronous submodules. <br> • Restores all modulation parameters (`fc = 1000 Hz`, `fm = 50 Hz`, `beta = 2.0`, `amp = 80%`), sets mode back to `FM` (`00`), resets NCO phase accumulators, flushes keypad typed buffers, resets RAM playback pointers, and re-initializes SPI controller states. |
