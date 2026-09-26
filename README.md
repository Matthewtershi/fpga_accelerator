# FPGA Audio Transformer Accelerator

A voice-controlled audio effects processor implemented on a Digilent Cmod A7-35T FPGA. The system captures a short background-noise profile, suppresses stationary noise, classifies a spoken command with a quantized Transformer, and applies the selected audio effect in hardware.

This is a small, task-specific Transformer accelerator—not a general-purpose language model. It uses GPT-style causal attention and fixed-point inference, but its output is one of seven audio-control classes rather than generated text or music.

> **Project status:** architecture and hardware selected; implementation and measurements are in progress. Values marked as targets are not measured results.

## System behavior

1. Press the Cmod button.
2. The FPGA records one second of background noise and estimates its average spectrum.
3. An LED indicates when to speak.
4. The system captures a 1.25-second command.
5. The FPGA suppresses the measured noise and extracts spectral features.
6. An INT8 Transformer classifies the command.
7. The FPGA applies the requested effect and reports the result over USB serial.

```text
Line-level audio
      |
      v
Pmod I2S2 ADC -- 48 kHz, 24-bit I2S
      |
      v
16 kHz decimation and framing
      |
      v
512-point FFT and noise-spectrum subtraction
      |
      v
16-band log-mel features
      |
      v
INT8 causal Transformer
      |
      +--> bypass / short / medium / long / filter
      |
      v
FPGA audio effect --> Pmod I2S2 DAC --> powered speakers
```

## Hardware

| Component | Role |
| --- | --- |
| Digilent Cmod A7-35T | Audio DSP, fixed-point Transformer inference, and effect processing |
| Digilent Pmod I2S2 | Stereo line-level ADC and DAC interface |
| Raspberry Pi Pico H | USB configuration, experiment control, and result logging |
| Windows or Linux computer | Model training, Vivado development, and benchmark collection |
| Custom analog PCB | Future microphone preamplifier, input conditioning, output buffering, and module mounting |

The Pmod I2S2 expects a line-level source. Early tests will use prerecorded commands from a phone or computer, or a microphone routed through a preamplifier/audio interface. A bare microphone cannot connect directly to the Pmod input.

## Command mapping

| Spoken command | FPGA action |
| --- | --- |
| `bypass` | Pass audio without a digital effect |
| `short` | Apply a 50 ms delay |
| `medium` | Apply a 150 ms delay |
| `long` | Apply a 300 ms delay |
| `filter` | Enable the 3 kHz low-pass effect |
| Unknown/noise | Make no change |
| Silence | Make no change |

The unknown and silence classes are required to prevent background audio from changing modes accidentally.

## Signal-processing frontend

The Transformer receives spectral features rather than raw samples.

| Parameter | Initial value |
| --- | ---: |
| Codec stream | 48 kHz, signed 24-bit I2S |
| Classifier sample rate | 16 kHz mono |
| Noise calibration | 1 second |
| Command capture | 1.25 seconds |
| Analysis window | 25 ms Hann window |
| Frame hop | 10 ms |
| FFT | 512 points |
| Feature bands | 16 log-mel bands |
| Sequence length | Approximately 123 frames, padded to 128 |

During calibration, the FPGA averages the power in every FFT bin. During command capture, it performs spectral subtraction:

```text
clean_power[k] = max(command_power[k] - alpha * noise_power[k],
                     beta * noise_power[k])
```

`alpha` controls subtraction strength and `beta` preserves a noise floor. These constants will be tuned in software and then frozen for the FPGA implementation.

Because classification only needs spectral features, the design does not reconstruct a cleaned waveform with an inverse FFT. The cleaned power spectrum feeds the mel filter bank directly.

This approach targets stationary noise such as fans, hum, and steady static. It is not active noise cancellation and is not expected to remove changing speech, music, or sudden impacts reliably.

## Transformer target

| Parameter | Initial target |
| --- | ---: |
| Architecture | Decoder-only causal Transformer classifier |
| Input | `128 x 16` feature matrix |
| Model dimension | 32 |
| Attention heads | 2 |
| Transformer blocks | 2 |
| Feed-forward dimension | 64 |
| Output classes | 7 |
| Weights and activations | INT8 |
| Accumulators | Wider fixed-point integers, selected by simulation |
| Estimated parameters | Approximately 20,000–25,000 |

The final frame representation is mapped to seven class logits. Reducing the number of output classes would save very little memory; sequence length and model dimension dominate attention cost.

## Training data

Each example consists of a labeled command recording and a separate one-second recording of its background noise. The initial personalized dataset should include:

- Five command words from at least two speakers.
- At least 50 takes per speaker per command across three or more sessions.
- Different speaking speeds, volumes, and source distances.
- Fans, hum, static, music, unrelated speech, and room noise.
- Unknown words, silence, and noise-only recordings.

Clean commands will also be mixed with recorded noise at controlled signal-to-noise ratios, initially 20, 10, 5, and 0 dB. A different segment of the same noise source will provide the calibration profile.

Dataset splits must be made by speaker or recording session before augmentation. This prevents altered copies of one utterance from appearing in both training and testing.

## Training and hardware-validation flow

The FPGA does not train the model. Python performs training and reproduces the complete hardware frontend:

```text
WAV + calibration noise
        |
        v
Python model of decimation, FFT, subtraction, mel bands, and normalization
        |
        v
Floating-point Transformer training
        |
        v
INT8 quantization and fixed-point simulation
        |
        v
Export weights, scales, coefficients, and test vectors
        |
        v
RTL simulation and FPGA inference
```

Fixed-point validation is required because rounding, saturation, FFT scaling, coefficient quantization, and overflow can change the classifier output. Identical digital PCM test vectors should produce bit-exact features in Python and RTL simulation. Physical Pmod measurements are compared within a tolerance because the ADC and analog path introduce gain and noise differences.

## Audio effects

The effect engine remains independent of the classifier so it can be tested before machine-learning integration.

- Digital bypass
- 50, 150, and 300 ms block-RAM delay presets
- 50% dry and 50% delayed mix
- Saturating fixed-point arithmetic
- Fixed 3 kHz low-pass filter
- Muted or faded mode transitions to avoid clicks

## Benchmarks

The project will report measurements rather than subjective claims.

### Model quality

- Accuracy, precision, recall, F1 score, and confusion matrix
- Accuracy versus signal-to-noise ratio
- Accuracy with and without spectral subtraction
- False activations during noise-only playback
- Floating-point versus INT8 accuracy loss
- Python versus RTL/FPGA classification agreement

### Hardware performance

- FFT, feature-extraction, and inference latency
- Total response time after command capture
- Maximum clock frequency
- LUT, flip-flop, DSP, and block-RAM utilization
- Estimated or measured power
- Throughput in classifications per second

### Audio performance

- Delay timing
- Bypass gain and clipping level
- Low-pass cutoff and frequency response
- Thirty-minute playback test
- Mode-change and power-cycle reliability

Initial acceptance targets are:

- At least 90% clean software test accuracy.
- No more than a two-percentage-point loss after INT8 quantization.
- At least 85% end-to-end accuracy at 10 dB SNR.
- No more than one false activation during ten minutes of noise-only testing.
- Less than 100 ms of processing after command capture ends.
- Timing closure with each major FPGA resource below 80% utilization.

These are design targets and will be revised if the software feasibility study shows that a target is unsupported.

## Development plan

1. **Software feasibility:** Build the preprocessing pipeline, collect a small dataset, train the floating-point model, and confirm that spectral subtraction improves noisy-command accuracy.
2. **Audio bring-up:** Implement clocks, I2S pass-through, sample-rate conversion, button handling, LEDs, and Pico communication.
3. **Feature extraction:** Implement windowing, FFT, noise profiling, spectral subtraction, mel accumulation, and normalization. Match Python test vectors.
4. **Transformer accelerator:** Implement fixed-point matrix operations, attention, normalization, feed-forward layers, and classification. Load exported INT8 parameters.
5. **Effects integration:** Connect accepted commands to the delay and filter engine with confidence thresholds and safe mode transitions.
6. **System verification:** Run the model, hardware, noise-robustness, and audio benchmarks and publish the measurements.
7. **Future PCB:** Add the microphone and line-level analog interface, power distribution, connectors, test points, and removable module sockets.

## Planned repository layout

```text
fpga_accelerator/
├── README.md
├── data/                 # Dataset instructions and metadata; raw recordings excluded from Git
├── model/                # Training, quantization, and evaluation code
├── reference/            # Fixed-point Python model and exported test vectors
├── rtl/                  # Synthesizable SystemVerilog or VHDL
├── sim/                  # RTL testbenches and Python/RTL comparison tests
├── firmware/             # Raspberry Pi Pico firmware
├── constraints/          # Cmod A7 pin and timing constraints
├── pcb/                  # Future schematic, layout, and manufacturing files
├── scripts/              # Export, build, and benchmark utilities
└── results/              # Reproducible reports, plots, and utilization summaries
```

Large audio files, generated FPGA projects, bitstreams, and training checkpoints should not be committed directly. Store reproducible download or generation instructions instead.

## Current status

- [x] Select FPGA, audio codec module, and controller hardware.
- [x] Define the initial signal-processing and Transformer architecture.
- [x] Define objective model and hardware benchmarks.
- [ ] Validate the audio clock configuration in Vivado.
- [ ] Build the Python preprocessing and training baseline.
- [ ] Bring up Pmod I2S2 pass-through.
- [ ] Implement and verify the FPGA frontend.
- [ ] Implement and verify INT8 Transformer inference.
- [ ] Integrate audio effects and command control.
- [ ] Design and assemble the custom analog PCB.
- [ ] Publish measured results and a demonstration.

## License

No license has been selected yet. Do not assume reuse permission until a license file is added.
