#!/usr/bin/env python3
"""Stream audio to the Cmod A7 bring-up design over the FT2232 UART.

The FPGA expects signed 16-bit little-endian mono samples at 48 kHz at
2 Mbaud, and plays them on both Pmod I2S2 channels.

    python3 scripts/send_audio.py --tone 440 --seconds 3
    python3 scripts/send_audio.py clip.wav
    python3 scripts/send_audio.py clip.wav --out /tmp/clip.raw   # no hardware

Needs pyserial (pip install pyserial) unless --out is used.
"""
import argparse
import array
import glob
import math
import sys
import time
import wave

RATE = 48_000
BAUD = 2_000_000
CHUNK_SAMPLES = 240      # 5 ms per write
LEAD_S = 0.040           # how far ahead of real time the FIFO is kept filled


def load_wav(path):
    """Return mono float samples in [-1, 1] and the source sample rate."""
    with wave.open(path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width == 1:
        vals = [(b - 128) / 128 for b in raw]
    elif width == 2:
        a = array.array("h")
        a.frombytes(raw)
        if sys.byteorder == "big":
            a.byteswap()
        vals = [v / 32768 for v in a]
    elif width in (3, 4):
        scale = 2 ** (8 * width - 1)
        vals = [int.from_bytes(raw[i:i + width], "little", signed=True) / scale
                for i in range(0, len(raw), width)]
    else:
        sys.exit(f"unsupported sample width: {width} bytes")
    if ch > 1:
        vals = [sum(vals[i:i + ch]) / ch for i in range(0, len(vals) - ch + 1, ch)]
    return vals, rate


def resample(x, src_rate, dst_rate):
    """Linear-interpolation resampler (fine for a bring-up test, not hi-fi)."""
    if src_rate == dst_rate or not x:
        return x
    n_out = int(len(x) * dst_rate / src_rate)
    step = src_rate / dst_rate
    out = []
    for i in range(n_out):
        pos = i * step
        j = int(pos)
        frac = pos - j
        nxt = x[j + 1] if j + 1 < len(x) else x[j]
        out.append(x[j] * (1 - frac) + nxt * frac)
    return out


def to_pcm16(x, volume):
    out = array.array("h", (max(-32768, min(32767, round(v * volume * 32767))) for v in x))
    if sys.byteorder == "big":
        out.byteswap()
    return out.tobytes()


def find_port():
    # The Cmod A7's FT2232 exposes JTAG (channel A) and UART (channel B).
    # On macOS they show up as cu.usbserial-<serial>0 and ...1.
    ports = sorted(glob.glob("/dev/cu.usbserial-*") + glob.glob("/dev/ttyUSB*"))
    if not ports:
        sys.exit("no USB serial port found; pass --port")
    return ports[-1] if len(ports) > 1 else ports[0]


def stream(port, pcm):
    import serial  # imported here so --out works without pyserial

    n_samples = len(pcm) // 2
    with serial.Serial(port, BAUD) as ser:
        t0 = time.monotonic()
        for start in range(0, n_samples, CHUNK_SAMPLES):
            end = min(start + CHUNK_SAMPLES, n_samples)
            due = t0 + end / RATE - LEAD_S
            delay = due - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            ser.write(pcm[2 * start:2 * end])
        ser.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav", nargs="?", help="WAV file (any rate/channels; converted to 48 kHz mono)")
    ap.add_argument("--tone", type=float, metavar="HZ", help="send a sine tone instead of a file")
    ap.add_argument("--seconds", type=float, default=3.0, help="tone length (default 3)")
    ap.add_argument("--volume", type=float, default=0.25,
                    help="linear gain, 1.0 = full scale (default 0.25; start low with headphones)")
    ap.add_argument("--port", help="serial port (default: auto-detect)")
    ap.add_argument("--out", help="write the raw 16-bit stream to this file instead of the serial port")
    args = ap.parse_args()

    if args.tone is not None:
        n = int(args.seconds * RATE)
        x = [math.sin(2 * math.pi * args.tone * i / RATE) for i in range(n)]
    elif args.wav:
        x, rate = load_wav(args.wav)
        x = resample(x, rate, RATE)
    else:
        ap.error("give a WAV file or --tone HZ")

    if not 0 < args.volume <= 1:
        ap.error("--volume must be in (0, 1]")
    pcm = to_pcm16(x, args.volume)
    print(f"{len(pcm) // 2} samples, {len(pcm) / 2 / RATE:.2f} s at {RATE} Hz")

    if args.out:
        with open(args.out, "wb") as f:
            f.write(pcm)
        return
    port = args.port or find_port()
    print(f"streaming to {port} at {BAUD} baud")
    stream(port, pcm)


if __name__ == "__main__":
    main()
