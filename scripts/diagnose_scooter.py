#!/usr/bin/env python3
"""Diagnose why the scooter's data stream stalls, from a Mac, without the phone.

The iPhone log showed the stream stopping dead (no frames for 10+ seconds) while the Bluetooth link stayed up.
Re-sending the start frame never revived it; reconnecting always did (and the scooter beeps when it reconnects).
This script talks to the scooter the same way the app does and runs controlled experiments to find out *what
triggers* a stall and *which recovery step works*, and it records everything for later analysis.

SETUP (once)
    python3 -m venv .venv && .venv/bin/pip install bleak
    # Terminal (or your editor) needs Bluetooth permission: System Settings > Privacy & Security > Bluetooth.

BEFORE EVERY REAL RUN
    * Switch the scooter on and keep it standing still (the lock-state read assumes standstill).
    * Close Erup on the phone or turn the phone's Bluetooth off. Only one device can be connected at a time.
    * Expect beeps: the scooter beeps every time a connection is made, and some experiments reconnect on purpose.

USAGE
    .venv/bin/python scripts/diagnose_scooter.py --list
    .venv/bin/python scripts/diagnose_scooter.py run --scenarios baseline,bridge,at,recovery
    .venv/bin/python scripts/diagnose_scooter.py run --scenarios all --quick
    .venv/bin/python scripts/diagnose_scooter.py run --scenarios soak --soak-mode app --duration 300
    .venv/bin/python scripts/diagnose_scooter.py analyze ~/Downloads/Erup-diagnostics-2026-10-18T16-02-12Z.txt
    .venv/bin/python scripts/diagnose_scooter.py selftest
    .venv/bin/python scripts/diagnose_scooter.py run --simulate --scenarios bridge,recovery --quick   # no scooter

OUTPUT (diagnostics-<date>/)
    REPORT.md      what was measured and what it points to
    summary.json   the same, machine readable
    events.jsonl   every connect, write, gap, reply and verdict with timestamps
    frames.csv     every telemetry frame with its decoded values

This script only reads state and sends the same keep-alive, AT query and read-only bridge frames the app sends.
It never writes registers, speed limits or firmware.
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import datetime as dt
import json
import platform
import random
import re
import statistics
import sys
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------------------------------------------
# Protocol (mirrors Sources/ScooterProtocol)
# ---------------------------------------------------------------------------------------------------------------

BASE_UUID = "0000{:04x}-0000-1000-8000-00805f9b34fb"
DATA_WRITE, DATA_NOTIFY = BASE_UUID.format(0xF1F1), BASE_UUID.format(0xF1F2)
CMD_WRITE, CMD_NOTIFY = BASE_UUID.format(0xF2F1), BASE_UUID.format(0xF2F2)
NAME_PREFIX = "ZYD_"

START = bytes([0xA5, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5A])
KEEPALIVE = bytes([0xA5, 0x02, 0xFD, 0x5A])
ENTER_BRIDGE = bytes([0xA5, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x5A])
LEAVE_BRIDGE = START
KEEPALIVE_INTERVAL = 0.3
FRAMES_PER_KEEPALIVE = 5


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def with_crc(payload: bytes) -> bytes:
    crc = crc16_modbus(payload)
    return payload + bytes([crc & 0xFF, crc >> 8])


def crc_ok(frame: bytes) -> bool:
    return len(frame) >= 3 and frame[-2:] == with_crc(frame[:-2])[-2:]


READ_CONTROL_WORD = with_crc(bytes([0x01, 0x03, 0x00, 0x00, 0x00, 0x05]))
AT_QUERIES = [b"AT+TYPE?", b"AT+DEVICE?"]


@dataclass
class Frame:
    kind: int  # 1 = live values, 2 = limits
    raw: bytes
    fields: dict


def parse_frame(raw: bytes) -> Frame:
    u16 = lambda i: raw[i] << 8 | raw[i + 1]
    s16 = lambda i: u16(i) - 0x10000 if u16(i) & 0x8000 else u16(i)
    if raw[1] == 0x00:
        return Frame(1, raw, {
            "gear": raw[4], "battery": raw[5], "speed_raw": max(u16(6), u16(8)),
            "voltage": u16(10) / 10, "current": s16(12) / 64,
            "ctrl_temp": raw[14] - 256 if raw[14] > 127 else raw[14],
            "motor_temp": raw[15] - 256 if raw[15] > 127 else raw[15],
            "trip_km": u16(16) / 10, "total_km": (raw[18] << 16 | raw[19] << 8 | raw[20]) / 10,
            "register0": u16(21),
        })
    return Frame(2, raw, {"flags": u16(10)})


class StreamDecoder:
    """Reassembles 25-byte telemetry frames from notification fragments, skipping anything else."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.dropped = 0

    def feed(self, data: bytes) -> list[tuple[str, object]]:
        self.buffer.extend(data)
        out: list[tuple[str, object]] = []
        while self.buffer:
            if self.buffer[0] == 0xAB:
                if len(self.buffer) < 25:
                    break
                candidate = bytes(self.buffer[:25])
                if candidate[1] in (0, 1) and candidate[2] == 0x19 and crc_ok(candidate):
                    out.append(("telemetry", parse_frame(candidate)))
                    del self.buffer[:25]
                    continue
            del self.buffer[0]
            self.dropped += 1
        return out


class BridgeDecoder:
    """Bridge replies, framed exactly like the app's BridgeReplyDecoder:
    slave 0x01, function, address (2 bytes), byte count, payload, CRC (low byte first).
    Errors are 5 bytes: slave, function | 0x80, code, CRC. Writes are acknowledged with 8 bytes."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.dropped = 0

    def reset(self) -> None:
        self.buffer.clear()

    def feed(self, data: bytes) -> list[tuple[str, bytes]]:
        self.buffer.extend(data)
        out: list[tuple[str, bytes]] = []
        while len(self.buffer) >= 2:
            if self.buffer[0] != 0x01:
                del self.buffer[0]
                self.dropped += 1
                continue
            function = self.buffer[1]
            if function >= 0x80:
                length, kind = 5, "bridge_error"
            elif function == 0x10:
                length, kind = 8, "bridge_ack"
            elif function in (0x03, 0x07, 0x08):
                if len(self.buffer) < 5:
                    break
                length, kind = 5 + self.buffer[4] + 2, "bridge"
            else:
                del self.buffer[0]
                self.dropped += 1
                continue
            if len(self.buffer) < length:
                break
            candidate = bytes(self.buffer[:length])
            if crc_ok(candidate):
                out.append((kind, candidate))
                del self.buffer[:length]
            else:
                del self.buffer[0]
                self.dropped += 1
        return out


def bridge_payload(frame: bytes) -> bytes:
    return frame[5:-2]


def fake_bridge_reply(control_word: int = 0x0801) -> bytes:
    return with_crc(bytes([0x01, 0x03, 0x00, 0x00, 0x0A, control_word >> 8, control_word & 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]))


# ---------------------------------------------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------------------------------------------

class Recorder:
    """Writes every event and frame as it happens, so a crash or Ctrl-C still leaves usable data."""

    def __init__(self, outdir: Path) -> None:
        self.outdir = outdir
        outdir.mkdir(parents=True, exist_ok=True)
        self.t0 = time.monotonic()
        self.events_file = open(outdir / "events.jsonl", "w", buffering=1)
        self.frames_file = open(outdir / "frames.csv", "w", newline="", buffering=1)
        self.frames_csv = csv.writer(self.frames_file)
        self.frames_csv.writerow(["t", "kind", "hex", "battery", "speed_kmh", "voltage", "current", "register0"])
        self.events: list[dict] = []

    def now(self) -> float:
        return time.monotonic() - self.t0

    def event(self, kind: str, /, **detail) -> dict:
        entry = {"t": round(self.now(), 3), "wall": dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds"),
                 "kind": kind, **detail}
        self.events.append(entry)
        self.events_file.write(json.dumps(entry) + "\n")
        return entry

    def frame(self, frame: Frame) -> None:
        f = frame.fields
        speed = f"{f['speed_raw'] / 1000:.2f}" if frame.kind == 1 else ""
        self.frames_csv.writerow([
            round(self.now(), 3), frame.kind, frame.raw.hex(" "), f.get("battery", ""), speed,
            f.get("voltage", ""), f.get("current", ""), f"0x{f['register0']:04x}" if frame.kind == 1 else "",
        ])

    def close(self) -> None:
        self.events_file.close()
        self.frames_file.close()


# ---------------------------------------------------------------------------------------------------------------
# Link to the scooter (real or simulated)
# ---------------------------------------------------------------------------------------------------------------

GAP_SECONDS = 1.0       # a healthy stream never had a gap of even 2 s in the phone log
STALL_SECONDS = 4.0     # what the app treats as a stall


class Link:
    """One connection to the scooter with an app-like keep-alive and full recording."""

    def __init__(self, rec: Recorder, args, client_factory) -> None:
        self.rec = rec
        self.args = args
        self.client_factory = client_factory
        self.client = None
        self.decoder = StreamDecoder()
        self.bridge_decoder = BridgeDecoder()
        self.keepalive_mode = "both"      # both | frames | timer | none
        self.keepalive_interval = KEEPALIVE_INTERVAL
        self.connected = False
        self.frame_times: list[float] = []     # telemetry frame 1 arrival times
        self.last_frame = None
        self.frames_since_keepalive = 0
        self.keepalive_task = None
        self.keepalive_in_flight = False
        self.bridge_open = False
        self.last_other_tx = None             # (label, t)
        self.replies: list[tuple[float, str, bytes]] = []
        self.bridge_replies: list[tuple[float, bytes]] = []
        self.gaps: list[dict] = []
        self.keepalives_sent = 0
        self.keepalive_times: list[float] = []
        self.samples: list[tuple[float, dict]] = []      # (t, decoded values of frame 1)
        self.chunks: list[tuple[float, int]] = []        # every data notification: (t, size)
        self.command_chunks = 0
        self.write_latencies: list[float] = []
        self.zero_speed_since: float | None = None
        self.callback_errors = 0
        self.response_writes = bool(getattr(args, "response_writes", False))
        self.connect_times: list[float] = []
        self.first_frame_times: list[float] = []
        self.rssi = getattr(args, "scan_rssi", None)
        self.connections = 0
        self.disconnect_events = 0

    # -- connecting ---------------------------------------------------------------------------------------------

    async def connect(self, wait_for_frames: bool = True) -> dict:
        started = time.monotonic()
        self._close_open_gap("reconnect")
        self.client = await self.client_factory(self._on_disconnect)
        try:
            await self.client.connect()
        except Exception as error:  # noqa: BLE001 - a stale cached device: scan again once
            self.rec.event("connect_failed", error=f"{type(error).__name__}: {error}")
            self.args.cached_device = None
            self.client = await self.client_factory(self._on_disconnect)
            await self.client.connect()
        connect_s = time.monotonic() - started
        self.connected = True
        self.connections += 1
        self.decoder = StreamDecoder()
        self.bridge_decoder = BridgeDecoder()
        self.last_frame = None
        self.frames_since_keepalive = 0
        self.bridge_open = False
        await self.client.start_notify(DATA_NOTIFY, self._on_data)
        await self.client.start_notify(CMD_NOTIFY, self._on_command)
        await self.write_data(START, "start frame")
        self.restart_keepalive()   # the app starts its keep-alive loop right after the start frame
        first, retried = None, False
        if wait_for_frames:
            first = await self.wait_for_frame(since=started, timeout=2.5)
            if first is None:
                # Experiment: does a second start frame get a stream that did not begin going?
                retried = True
                self.rec.event("start_retry", detail="no frame 2.5 s after the first start frame")
                await self.write_data(START, "start frame (retry)")
                first = await self.wait_for_frame(since=started, timeout=3.5)
        info = {"connect_s": round(connect_s, 3),
                "first_frame_s": None if first is None else round(first - started, 3),
                "start_retried": retried}
        self.connect_times.append(connect_s)
        if first is not None:
            self.first_frame_times.append(first - started)
        self.rec.event("connected", **info)
        return info

    async def disconnect(self) -> None:
        self.stop_keepalive()
        if self.client is not None and self.connected:
            try:
                await self.client.disconnect()
            except Exception as error:  # noqa: BLE001 - recording the error is the point
                self.rec.event("disconnect_error", error=str(error))
        self.connected = False
        self.rec.event("disconnected_by_script")

    def _on_disconnect(self, _client) -> None:
        if self.connected:
            self.disconnect_events += 1
            idle = None if self.zero_speed_since is None else round(time.monotonic() - self.zero_speed_since, 1)
            silent = None if self.last_frame is None else round(time.monotonic() - self.last_frame, 1)
            self.rec.event("link_lost", detail="the scooter or the OS ended the link", seconds_since_last_frame=silent,
                           seconds_at_zero_speed=idle,
                           possible_auto_off=bool(idle is not None and idle > 60 and silent is not None and silent > 5))
        self.connected = False

    async def reconnect(self) -> dict:
        self.rec.event("reconnect_begin")
        await self.disconnect()
        await asyncio.sleep(1.0)
        return await self.connect()

    async def resubscribe(self) -> None:
        self.rec.event("resubscribe", detail="notifications off and on, link stays up")
        await self.client.stop_notify(DATA_NOTIFY)
        await self.client.start_notify(DATA_NOTIFY, self._on_data)

    # -- receiving ----------------------------------------------------------------------------------------------

    def _on_data(self, _sender, data: bytearray) -> None:
        try:
            self._handle_data(data)
        except Exception as error:  # noqa: BLE001 - a bug here must be visible in the report, not lost in the callback
            self.callback_errors += 1
            self.rec.event("callback_error", where="data", error=f"{type(error).__name__}: {error}")

    def _handle_data(self, data: bytearray) -> None:
        now = time.monotonic()
        raw = bytes(data)
        self.chunks.append((now, len(raw)))
        if self.bridge_open:
            # Like the app: while a bridge exchange is open every notification belongs to the bridge decoder.
            self.rec.event("raw_during_bridge", hex=raw.hex(" "))
            for kind, frame in self.bridge_decoder.feed(raw):
                self.bridge_replies.append((now, frame))
                self.rec.event("bridge_reply", reply=kind, hex=frame.hex(" "), error=kind == "bridge_error")
            return
        for kind, item in self.decoder.feed(raw):
            if kind == "telemetry":
                self.rec.frame(item)
                if item.kind == 1:
                    self._telemetry_arrived(now)
                    self.samples.append((now, dict(item.fields)))
                    speed = item.fields["speed_raw"] / 1000
                    if speed > 0.5:
                        self.zero_speed_since = None
                    elif self.zero_speed_since is None:
                        self.zero_speed_since = now

    def _close_open_gap(self, ended_by: str) -> None:
        """A stall that ends in a reconnect never sees a frame resume, so count it here."""
        if self.last_frame is None:
            return
        length = time.monotonic() - self.last_frame
        if length > GAP_SECONDS:
            other = None
            if self.last_other_tx:
                label, at = self.last_other_tx
                other = {"label": label, "seconds_before_gap_start": round(self.last_frame - at, 3)}
            gap = {"t": round(self.rec.now(), 3), "length_s": round(length, 3), "last_other_tx": other,
                   "bridge_open": self.bridge_open, "ended_by": ended_by}
            self.gaps.append(gap)
            self.rec.event("gap", **gap)
        self.last_frame = None

    def _telemetry_arrived(self, now: float) -> None:
        if self.last_frame is not None and now - self.last_frame > GAP_SECONDS:
            other = None
            if self.last_other_tx:
                label, at = self.last_other_tx
                other = {"label": label, "seconds_before_gap_start": round(self.last_frame - at, 3)}
            gap = {"t": round(now - self.rec.t0, 3), "length_s": round(now - self.last_frame, 3), "last_other_tx": other,
                   "bridge_open": self.bridge_open}
            self.gaps.append(gap)
            self.rec.event("gap", **gap)
        self.last_frame = now
        self.frame_times.append(now)
        self.frames_since_keepalive += 1
        if self.keepalive_mode in ("both", "frames") and self.frames_since_keepalive >= FRAMES_PER_KEEPALIVE:
            self.frames_since_keepalive = 0
            asyncio.ensure_future(self._send_keepalive())

    def _on_command(self, _sender, data: bytearray) -> None:
        try:
            now = time.monotonic()
            self.command_chunks += 1
            text = bytes(data).decode("utf-8", "replace").strip()
            self.replies.append((now, text, bytes(data)))
            self.rec.event("at_reply", text=text)
        except Exception as error:  # noqa: BLE001
            self.callback_errors += 1
            self.rec.event("callback_error", where="command", error=f"{type(error).__name__}: {error}")

    def speed_kmh(self) -> float | None:
        return round(self.samples[-1][1]["speed_raw"] / 1000, 1) if self.samples else None

    async def wait_for_frame(self, since: float, timeout: float) -> float | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.frame_times and self.frame_times[-1] > since:
                return next(t for t in self.frame_times if t > since)
            await asyncio.sleep(0.02)
        return None

    # -- sending ------------------------------------------------------------------------------------------------

    async def write_data(self, data: bytes, label: str, keepalive: bool = False) -> None:
        if not self.connected:
            return
        began = time.monotonic()
        try:
            await self.client.write_gatt_char(DATA_WRITE, data, response=self.response_writes)
        except Exception as error:  # noqa: BLE001
            self.rec.event("write_error", label=label, error=str(error))
            return
        self.write_latencies.append(time.monotonic() - began)
        if keepalive:
            self.keepalives_sent += 1
            self.keepalive_times.append(time.monotonic())
        else:
            self.last_other_tx = (label, time.monotonic())
            self.rec.event("tx", label=label, hex=data.hex(" "))

    async def write_command(self, data: bytes, label: str) -> None:
        if not self.connected:
            return
        try:
            await self.client.write_gatt_char(CMD_WRITE, data, response=self.response_writes)
        except Exception as error:  # noqa: BLE001
            self.rec.event("write_error", label=label, error=str(error))
            return
        self.last_other_tx = (label, time.monotonic())
        self.rec.event("tx", label=label, hex=data.hex(" "), text=data.decode("utf-8", "replace"))

    async def _send_keepalive(self) -> None:
        if self.keepalive_in_flight or self.bridge_open or not self.connected:
            return
        self.keepalive_in_flight = True
        try:
            await self.write_data(KEEPALIVE, "keep-alive", keepalive=True)
        finally:
            self.keepalive_in_flight = False

    async def _timer_loop(self) -> None:
        while True:
            await asyncio.sleep(self.keepalive_interval)
            await self._send_keepalive()

    def restart_keepalive(self) -> None:
        self.stop_keepalive()
        if self.keepalive_mode in ("both", "timer"):
            self.keepalive_task = asyncio.ensure_future(self._timer_loop())

    def stop_keepalive(self) -> None:
        if self.keepalive_task:
            self.keepalive_task.cancel()
            self.keepalive_task = None

    def set_keepalive(self, mode: str, interval: float = KEEPALIVE_INTERVAL) -> None:
        self.keepalive_mode, self.keepalive_interval = mode, interval
        self.rec.event("keepalive_mode", mode=mode, interval=interval)
        self.restart_keepalive()

    # -- bridge exchange (the sequence the app uses to read the lock state) ------------------------------------------

    async def bridge_read(self, variant: str = "app") -> dict:
        """Enter bridge mode, read the control word, leave. Variants differ only in how the exchange is closed."""
        began = time.monotonic()
        self.bridge_open = True
        self.bridge_decoder.reset()
        self.rec.event("bridge_begin", variant=variant)
        reply = None
        mark = len(self.bridge_replies)
        await self.write_data(ENTER_BRIDGE, "enter-bridge frame")
        await asyncio.sleep(0.2)
        await self.write_data(READ_CONTROL_WORD, "bridge read: control word")
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline and len(self.bridge_replies) == mark:
            if variant == "keepalive-during":
                await self.write_data(KEEPALIVE, "keep-alive (during bridge)", keepalive=True)
            await asyncio.sleep(0.05)
        if len(self.bridge_replies) > mark:
            reply = self.bridge_replies[-1][1]
        left = time.monotonic()
        await self.write_data(LEAVE_BRIDGE, "leave-bridge (start) frame")
        if variant == "leave-twice":
            await asyncio.sleep(0.1)
            await self.write_data(LEAVE_BRIDGE, "leave-bridge (start) frame, second")
        if variant == "leave-then-delay":
            await asyncio.sleep(0.5)
        if variant == "delay-250":
            await asyncio.sleep(0.25)
        if variant == "hold-400":
            # What Erup does since the fix: no keep-alive for 400 ms after the leave frame.
            await asyncio.sleep(0.4)
        self.bridge_open = False
        self.decoder = StreamDecoder()   # the app also resets its telemetry decoder when it leaves the bridge
        self.frames_since_keepalive = 0
        if variant == "leave-burst":
            for _ in range(3):
                await asyncio.sleep(0.1)
                await self._send_keepalive()
        await self._send_keepalive()
        resumed = await self.wait_for_frame(since=left, timeout=2.5)
        burst_revived = burst_latency = None
        if resumed is None:
            # The app's quiet recovery step: does a keep-alive burst bring the stream back without a reconnect?
            burst_started = time.monotonic()
            for index in range(3):
                self.keepalive_in_flight = False
                await self._send_keepalive()
                if index < 2:
                    await asyncio.sleep(0.1)
            back = await self.wait_for_frame(since=burst_started, timeout=3.5)
            burst_revived = back is not None
            burst_latency = None if back is None else round(back - burst_started, 3)
        result = {"variant": variant, "exchange_s": round(left - began, 3), "got_reply": reply is not None,
                  "stream_resumed": resumed is not None,
                  "resume_latency_s": None if resumed is None else round(resumed - left, 3),
                  "speed_kmh": self.speed_kmh()}
        if burst_revived is not None:
            result.update({"burst_revived": burst_revived, "burst_latency_s": burst_latency})
        if reply is not None and len(bridge_payload(reply)) >= 2:
            payload = bridge_payload(reply)
            result["control_word"] = f"0x{payload[0] << 8 | payload[1]:04x}"
        self.rec.event("bridge_end", **result)
        return result


# ---------------------------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------------------------

def frame_stats(times: list[float]) -> dict:
    if len(times) < 3:
        return {"frames": len(times)}
    intervals = [b - a for a, b in zip(times, times[1:])]
    ordered = sorted(intervals)
    pick = lambda q: ordered[min(len(ordered) - 1, int(q * len(ordered)))]
    span = times[-1] - times[0]
    return {"frames": len(times), "seconds": round(span, 1), "frames_per_second": round(len(times) / span, 2) if span else None,
            "interval_median_ms": round(statistics.median(intervals) * 1000), "interval_p95_ms": round(pick(0.95) * 1000),
            "interval_p99_ms": round(pick(0.99) * 1000), "interval_max_ms": round(max(intervals) * 1000),
            "gaps_over_1s": sum(1 for i in intervals if i > GAP_SECONDS)}


async def healthy(link: Link, seconds: float = 3.0) -> bool:
    """Waits until frames flow steadily, reconnecting once if they do not."""
    for attempt in range(2):
        since = time.monotonic()
        await asyncio.sleep(seconds)
        if len([t for t in link.frame_times if t > since]) >= 5:
            return True
        link.rec.event("not_healthy", attempt=attempt)
        await link.reconnect()
    return False


async def silence_for(link: Link, limit: float) -> float | None:
    """Waits until frames stop; returns how long after the call they stopped, or None if they never did."""
    began = time.monotonic()
    while time.monotonic() - began < limit:
        await asyncio.sleep(0.1)
        if link.frame_times and time.monotonic() - link.frame_times[-1] > STALL_SECONDS:
            return round(link.frame_times[-1] - began, 2)
    return None


async def sc_baseline(link: Link, args) -> dict:
    """Streaming with the app's keep-alive and nothing else. The control: does the stream stay up by itself?"""
    link.set_keepalive("both")
    await healthy(link)
    start = time.monotonic()
    gaps_before = len(link.gaps)
    await asyncio.sleep(args.duration)
    times = [t for t in link.frame_times if t >= start]
    stats = frame_stats(times)
    stalled = bool(link.frame_times) and time.monotonic() - link.frame_times[-1] > STALL_SECONDS
    return {**stats, "new_gaps": len(link.gaps) - gaps_before, "stalled_at_end": stalled,
            "verdict": "STALLED with keep-alives only: the stall needs no trigger from the app" if stalled or stats.get("gaps_over_1s")
            else "stable with keep-alives only: stalls need a trigger"}


async def sc_writetype(link: Link, args) -> dict:
    """The official Android app writes WITH response; Erup wrote without. On the phone, writes without response
    left the send buffer full for seconds and the scooter stopped streaming. Which way keeps the stream steady?"""
    table = []
    original = link.response_writes
    for label, response, interval in [("without response, keep-alive every 0.3 s (old Erup)", False, 0.3),
                                      ("without response, keep-alive every 1 s", False, 1.0),
                                      ("WITH response, keep-alive every 0.3 s", True, 0.3),
                                      ("WITH response, keep-alive every 1 s (new Erup)", True, 1.0)]:
        if not await healthy(link, 2.0):
            table.append({"config": label, "error": "no stream"})
            continue
        link.response_writes = response
        link.set_keepalive("both", interval)
        start, gaps_before, writes_before = time.monotonic(), len(link.gaps), len(link.write_latencies)
        await asyncio.sleep(args.step_seconds * 2)
        times = [t for t in link.frame_times if t >= start]
        latencies = link.write_latencies[writes_before:]
        stats = frame_stats(times)
        died = bool(link.frame_times) and time.monotonic() - link.frame_times[-1] > STALL_SECONDS
        table.append({"config": label, "frames_per_second": stats.get("frames_per_second"),
                      "interval_p95_ms": stats.get("interval_p95_ms"), "interval_max_ms": stats.get("interval_max_ms"),
                      "gaps_over_1s": len(link.gaps) - gaps_before, "stream_died": died,
                      "writes": len(latencies),
                      "write_time_ms_p50": round(percentile(latencies, 0.5) * 1000, 1) if latencies else None,
                      "write_time_ms_max": round(max(latencies) * 1000, 1) if latencies else None})
        if died:
            await link.reconnect()
    link.response_writes = original
    link.set_keepalive("both")
    bad = [row["config"] for row in table if row.get("stream_died") or row.get("gaps_over_1s")]
    return {"table": table, "verdict": ("gaps or stalls with: " + "; ".join(bad)) if bad else "every write style kept the stream steady on this link"}


async def sc_no_keepalive(link: Link, args) -> dict:
    """What happens without keep-alives (a suspended app)? How long does the scooter keep streaming?"""
    await healthy(link)
    link.set_keepalive("none")
    lifetime = await silence_for(link, 30)
    results = {"stream_lifetime_without_keepalive_s": lifetime}
    if lifetime is not None:
        since = time.monotonic()
        await link.write_data(KEEPALIVE, "single keep-alive", keepalive=True)
        results["revived_by_single_keepalive"] = await link.wait_for_frame(since, 3.0) is not None
    link.set_keepalive("both")
    results["verdict"] = ("the scooter ends the stream about %.1f s after the last keep-alive" % lifetime) if lifetime is not None \
        else "the stream continued for 30 s without keep-alives (they are not required)"
    return results


async def sc_cadence(link: Link, args) -> dict:
    """Which keep-alive cadence keeps the stream up? (A suspended app sends them late.)"""
    table = []
    for label, mode, interval in [("every 5th frame only", "frames", 0), ("timer 0.3 s only", "timer", 0.3),
                                  ("timer 1 s", "timer", 1.0), ("timer 2 s", "timer", 2.0), ("timer 3 s", "timer", 3.0)]:
        if not await healthy(link, 2.0):
            table.append({"cadence": label, "error": "no stream"})
            continue
        link.set_keepalive(mode, interval or KEEPALIVE_INTERVAL)
        start = time.monotonic()
        gaps_before = len(link.gaps)
        await asyncio.sleep(args.step_seconds)
        died = time.monotonic() - link.frame_times[-1] > STALL_SECONDS if link.frame_times else True
        times = [t for t in link.frame_times if t >= start]
        table.append({"cadence": label, "frames": len(times), "gaps": len(link.gaps) - gaps_before, "stream_died": died})
        if died:
            await link.reconnect()
    link.set_keepalive("both")
    died = [row["cadence"] for row in table if row.get("stream_died")]
    return {"table": table, "verdict": ("stream died with: " + ", ".join(died)) if died else "every cadence kept the stream up"}


async def sc_at(link: Link, args) -> dict:
    """Do AT commands (the app's settings reads) disturb the stream? Measures reply time and gaps after each one."""
    link.set_keepalive("both")
    await healthy(link)
    rounds = []
    for index in range(args.rounds):
        for query in AT_QUERIES:
            before_gaps, before_replies, sent = len(link.gaps), len(link.replies), time.monotonic()
            await link.write_command(query, f"AT command {query.decode()}")
            await asyncio.sleep(args.step_seconds)
            reply = link.replies[before_replies] if len(link.replies) > before_replies else None
            died = bool(link.frame_times) and time.monotonic() - link.frame_times[-1] > STALL_SECONDS
            rounds.append({"round": index + 1, "command": query.decode(),
                           "reply_s": None if reply is None else round(reply[0] - sent, 3),
                           "reply": None if reply is None else reply[1],
                           "gaps_after": len(link.gaps) - before_gaps, "stream_died": died})
            if died:
                await link.reconnect()
    bad = [r for r in rounds if r["gaps_after"] or r["stream_died"]]
    unanswered = [r for r in rounds if r["reply_s"] is None]
    return {"rounds": rounds, "disturbed": len(bad), "unanswered": len(unanswered),
            "verdict": f"{len(bad)} of {len(rounds)} AT commands were followed by a gap or a stall, {len(unanswered)} got no reply"}


BRIDGE_VARIANTS = ["app", "hold-400", "leave-twice", "leave-then-delay", "delay-250", "leave-burst", "keepalive-during"]


async def sc_bridge(link: Link, args) -> dict:
    """Does the lock-state read (bridge exchange) stop the stream, and how should it be closed?
    'app' is what Erup does today. Each exchange that does not resume gets the app's quiet recovery (a keep-alive
    burst) before a reconnect, so the report also says whether the burst is enough."""
    link.set_keepalive("both")
    table = []
    for variant in BRIDGE_VARIANTS:
        outcomes = []
        for _ in range(args.rounds):
            if not await healthy(link, 3.0):
                outcomes.append({"error": "no stream"})
                continue
            outcome = await link.bridge_read(variant)
            outcomes.append(outcome)
            if not outcome["stream_resumed"] and not outcome.get("burst_revived"):
                await link.reconnect()
        good = [o for o in outcomes if "error" not in o]
        resumed = sum(1 for o in good if o["stream_resumed"])
        burst = sum(1 for o in good if o.get("burst_revived"))
        latencies = [o["resume_latency_s"] for o in good if o.get("resume_latency_s") is not None]
        exchanges = [o["exchange_s"] for o in good]
        table.append({"variant": variant, "rounds": len(good), "resumed_by_itself": resumed,
                      "revived_by_keepalive_burst": burst,
                      "needed_reconnect": len(good) - resumed - burst,
                      "median_resume_s": round(statistics.median(latencies), 3) if latencies else None,
                      "median_exchange_s": round(statistics.median(exchanges), 3) if exchanges else None,
                      "replies": sum(1 for o in good if o["got_reply"])})
    safe = [row["variant"] for row in table if row["rounds"] and row["resumed_by_itself"] == row["rounds"]]
    app_row = table[0]
    failed = app_row["rounds"] - app_row["resumed_by_itself"]
    return {"table": table,
            "verdict": (f"the app's sequence did not resume by itself in {failed} of {app_row['rounds']} exchanges "
                        f"({app_row['revived_by_keepalive_burst']} fixed by a keep-alive burst, {app_row['needed_reconnect']} needed a reconnect)"
                        if failed else "the app's bridge sequence resumed every time")
                       + ("; always resumed by itself: " + ", ".join(safe) if safe else "; no variant always resumed by itself")}


async def sc_suspend(link: Link, args) -> dict:
    """Simulates a suspended app: no writes at all for N seconds, then keep-alives resume. How long can it be?"""
    table = []
    for pause in [1, 2, 3, 5, 8]:
        link.set_keepalive("both")
        if not await healthy(link, 2.0):
            table.append({"pause_s": pause, "error": "no stream"})
            continue
        link.set_keepalive("none")
        link.rec.event("suspend_begin", pause_s=pause)
        await asyncio.sleep(pause)
        resumed_at = time.monotonic()
        link.set_keepalive("both")
        await link._send_keepalive()
        back = await link.wait_for_frame(resumed_at, 5.0)
        table.append({"pause_s": pause, "survived": back is not None,
                      "resume_latency_s": None if back is None else round(back - resumed_at, 2)})
        if back is None:
            await link.reconnect()
    dead = [row["pause_s"] for row in table if row.get("survived") is False]
    return {"table": table, "verdict": ("the stream did not survive a %s s pause without keep-alives" % dead[0]) if dead
            else "the stream survived every pause up to 8 s"}


async def sc_recovery(link: Link, args) -> dict:
    """After a stall, which recovery step works? The ladder avoids the beep as long as it can."""
    runs = []
    for run in range(args.rounds):
        link.set_keepalive("both")
        if not await healthy(link, 3.0):
            runs.append({"error": "no stream"})
            continue
        link.set_keepalive("none")
        lifetime = await silence_for(link, 30)
        if lifetime is None:
            runs.append({"error": "could not induce a stall without keep-alives"})
            link.set_keepalive("both")
            continue
        link.set_keepalive("both")
        steps = []
        revived_by = None
        ladder = [("three keep-alives", lambda: asyncio.gather(*[link.write_data(KEEPALIVE, "recovery keep-alive", keepalive=True) for _ in range(3)])),
                  ("start frame", lambda: link.write_data(START, "recovery start frame")),
                  ("resubscribe + start frame", None),
                  ("reconnect (beeps)", None)]
        for name, action in ladder:
            began = time.monotonic()
            if name == "resubscribe + start frame":
                await link.resubscribe()
                await link.write_data(START, "recovery start frame")
            elif name.startswith("reconnect"):
                await link.reconnect()
            else:
                await action()
            back = await link.wait_for_frame(began, 3.5 if not name.startswith("reconnect") else 6.0)
            steps.append({"step": name, "revived": back is not None,
                          "latency_s": None if back is None else round(back - began, 2)})
            if back is not None:
                revived_by = name
                break
        runs.append({"stalled_after_s": lifetime, "steps": steps, "revived_by": revived_by})
    first = Counter(run.get("revived_by") for run in runs if "revived_by" in run)
    return {"runs": runs, "revived_by": dict(first),
            "verdict": "recovery that worked: " + ", ".join(f"{name} x{count}" for name, count in first.items()) if first else "nothing revived the stream"}


async def sc_reconnect(link: Link, args) -> dict:
    """Connection loss and reconnect, repeated: how long until the connection and the first frame, how reliable?"""
    cycles = []
    for index in range(args.rounds):
        began = time.monotonic()
        info = await link.reconnect()
        cycles.append({"cycle": index + 1, **info, "total_s": round(time.monotonic() - began - 1.0, 2)})
    ok = [c for c in cycles if c["first_frame_s"] is not None]
    return {"cycles": cycles, "frames_after_reconnect": f"{len(ok)} of {len(cycles)}",
            "median_first_frame_s": round(statistics.median([c["first_frame_s"] for c in ok]), 2) if ok else None,
            "verdict": f"frames returned after {len(ok)} of {len(cycles)} reconnects"}


async def sc_soak(link: Link, args) -> dict:
    """Leaves the connection idle for a while. 'app' mode repeats what the app sends after connecting (settings
    reads, then the lock-state bridge read) so stalls can be tied to that traffic; 'quiet' sends keep-alives only."""
    link.set_keepalive("both")
    await healthy(link)
    start = time.monotonic()
    gaps_before = len(link.gaps)
    schedule: list[tuple[float, str]] = []
    if args.soak_mode == "app":
        schedule = [(1.5, "at"), (4.0, "at"), (12.0, "bridge")]
        if args.bridge_every > 0:
            schedule += [(12.0 + n * args.bridge_every, "bridge") for n in range(1, int(args.duration // args.bridge_every) + 1)]
    stalls_triggered: list[dict] = []
    done = 0
    while time.monotonic() - start < args.duration:
        elapsed = time.monotonic() - start
        if done < len(schedule) and elapsed >= schedule[done][0]:
            _, what = schedule[done]
            done += 1
            if what == "at":
                await link.write_command(AT_QUERIES[done % 2], "AT command (settings read)")
            else:
                outcome = await link.bridge_read(args.bridge_variant)
                if not outcome["stream_resumed"]:
                    stalls_triggered.append({"t": round(elapsed, 1), "cause": f"bridge read ({args.bridge_variant})",
                                             "burst_revived": outcome.get("burst_revived")})
                    if not outcome.get("burst_revived"):
                        await link.reconnect()
        await asyncio.sleep(0.1)
        if link.frame_times and time.monotonic() - link.frame_times[-1] > STALL_SECONDS:
            stalls_triggered.append({"t": round(time.monotonic() - start, 1), "cause": link.last_other_tx[0] if link.last_other_tx else "unknown"})
            await link.reconnect()
    times = [t for t in link.frame_times if t >= start]
    return {"mode": args.soak_mode, **frame_stats(times), "stalls": stalls_triggered, "new_gaps": len(link.gaps) - gaps_before,
            "verdict": f"{len(stalls_triggered)} stall(s) in {args.duration:.0f} s with mode '{args.soak_mode}'"}


def telemetry_summary(samples: list[tuple[float, dict]], since: float) -> dict:
    rows = [f for t, f in samples if t >= since]
    if not rows:
        return {}
    speeds = [r["speed_raw"] / 1000 for r in rows]
    pick = lambda key: [r[key] for r in rows]
    return {"frames": len(rows),
            "speed_kmh": {"min": round(min(speeds), 1), "mean": round(statistics.mean(speeds), 1), "max": round(max(speeds), 1)},
            "moving_fraction": round(sum(1 for v in speeds if v > 1.0) / len(speeds), 2),
            "current_a": {"min": round(min(pick("current")), 1), "max": round(max(pick("current")), 1)},
            "voltage_v": {"min": round(min(pick("voltage")), 1), "max": round(max(pick("voltage")), 1)},
            "battery_percent": {"first": rows[0]["battery"], "last": rows[-1]["battery"]},
            "controller_temp_c": {"min": min(pick("ctrl_temp")), "max": max(pick("ctrl_temp"))},
            "motor_temp_c": {"min": min(pick("motor_temp")), "max": max(pick("motor_temp"))}}


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def link_metrics(link: Link) -> dict:
    """Everything about how the scooter and Bluetooth stack deliver data, over the whole run."""
    metrics: dict = {}
    chunk_times = [t for t, _ in link.chunks]
    if len(chunk_times) > 3:
        gaps = [b - a for a, b in zip(chunk_times, chunk_times[1:])]
        bursts, current = [], 1
        for gap in gaps:
            if gap < 0.015:
                current += 1
            else:
                bursts.append(current)
                current = 1
        bursts.append(current)
        span = chunk_times[-1] - chunk_times[0]
        metrics["notifications"] = {
            "count": len(chunk_times), "per_second": round(len(chunk_times) / span, 1) if span else None,
            "sizes": dict(Counter(size for _, size in link.chunks).most_common(6)),
            "gap_ms": {"p50": round(percentile(gaps, 0.5) * 1000, 1), "p95": round(percentile(gaps, 0.95) * 1000, 1),
                       "max": round(max(gaps) * 1000)},
            "burst_sizes": dict(Counter(bursts).most_common(6)),
            "note": "notifications that arrive within 15 ms of each other are counted as one burst (one connection event)"}
    frames1 = len(link.frame_times)
    all_frames = sum(1 for _ in open(link.rec.outdir / "frames.csv")) - 1
    metrics["frames"] = {"frame1": frames1, "frame2": max(0, all_frames - frames1),
                         "decoder_dropped_bytes": link.decoder.dropped + link.bridge_decoder.dropped}
    if link.write_latencies:
        metrics["write_latency_ms"] = {"count": len(link.write_latencies),
                                       "p50": round(percentile(link.write_latencies, 0.5) * 1000, 2),
                                       "p95": round(percentile(link.write_latencies, 0.95) * 1000, 2),
                                       "max": round(max(link.write_latencies) * 1000, 1)}
    if len(link.keepalive_times) > 3:
        spacing = [b - a for a, b in zip(link.keepalive_times, link.keepalive_times[1:])]
        metrics["keepalive_spacing_ms"] = {"p50": round(percentile(spacing, 0.5) * 1000), "p95": round(percentile(spacing, 0.95) * 1000),
                                           "max": round(max(spacing) * 1000), "sent": len(link.keepalive_times)}
    if link.connect_times:
        metrics["connections"] = {"count": len(link.connect_times),
                                  "connect_s_median": round(statistics.median(link.connect_times), 2),
                                  "connect_s_max": round(max(link.connect_times), 2),
                                  "first_frame_s_median": round(statistics.median(link.first_frame_times), 2) if link.first_frame_times else None,
                                  "first_frame_failed": len(link.connect_times) - len(link.first_frame_times),
                                  "start_retries": sum(1 for e in link.rec.events if e["kind"] == "start_retry")}
    metrics["rssi_at_scan_dbm"] = link.rssi
    metrics["command_notifications"] = link.command_chunks
    return metrics


SCENARIOS = {
    "writetype": (sc_writetype, "writes with vs without response, at two keep-alive speeds: frame rate, gaps and write time"),
    "baseline": (sc_baseline, "streaming with keep-alives only (the control)"),
    "nokeepalive": (sc_no_keepalive, "how long the stream lasts without keep-alives"),
    "cadence": (sc_cadence, "which keep-alive cadence keeps the stream up"),
    "at": (sc_at, "do AT commands disturb the stream"),
    "bridge": (sc_bridge, "does the lock-state read stop the stream, and which sequence is safe"),
    "suspend": (sc_suspend, "how long can writes pause (a suspended app) before the stream dies"),
    "recovery": (sc_recovery, "which recovery step revives a stalled stream (avoids the beep)"),
    "reconnect": (sc_reconnect, "repeated connection loss and reconnect: timing and reliability"),
    "soak": (sc_soak, "idle for a while, app-like traffic or keep-alives only (--soak-mode)"),
}
ALL_ORDER = ["writetype", "baseline", "nokeepalive", "cadence", "at", "bridge", "suspend", "recovery", "reconnect", "soak"]


# ---------------------------------------------------------------------------------------------------------------
# Simulated scooter (tests the script itself, and reproduces the stall behaviour seen on the phone)
# ---------------------------------------------------------------------------------------------------------------

def telemetry_frame(kind: int, tick: int, speed_raw: int = 0) -> bytes:
    body = bytearray(23)
    body[0], body[1], body[2] = 0xAB, kind, 0x19
    if kind == 0:
        body[4], body[5] = 1, 98
        body[6:8] = speed_raw.to_bytes(2, "big")
        body[8:10] = speed_raw.to_bytes(2, "big")
        body[10:12] = (398).to_bytes(2, "big")
        body[21:23] = (0x0801).to_bytes(2, "big")
    return with_crc(bytes(body))


class FakeClient:
    """Just enough of BleakClient. Reproduces the log: no keep-alive ends the stream, start frames and resubscribing
    do not revive it, a bridge exchange or an AT command can kill it, and only a reconnect revives it."""

    def __init__(self, disconnected_callback, behaviour: dict) -> None:
        self.callback = disconnected_callback
        self.behaviour = behaviour
        self.rng = random.Random(behaviour.get("seed", 7))
        self.handlers: dict[str, object] = {}
        self.is_connected = False
        self.streaming = False
        self.dead = False
        self.dead_reason = ""
        self.last_keepalive = 0.0
        self.in_bridge = False
        self.task = None

    async def connect(self) -> None:
        await asyncio.sleep(0.4)
        self.is_connected, self.dead = True, False

    async def disconnect(self) -> None:
        self.is_connected = False
        self.streaming = False
        if self.task:
            self.task.cancel()

    async def start_notify(self, uuid: str, handler) -> None:
        self.handlers[uuid] = handler

    async def stop_notify(self, uuid: str) -> None:
        self.handlers.pop(uuid, None)

    def _emit(self, uuid: str, data: bytes) -> None:
        handler = self.handlers.get(uuid)
        if handler:
            for i in range(0, len(data), 20):  # real notifications arrive in 20 byte pieces
                handler(None, bytearray(data[i:i + 20]))

    async def _stream(self) -> None:
        tick = 0
        while self.is_connected:
            await asyncio.sleep(0.2)
            if self.dead or self.in_bridge or not self.streaming:
                continue
            if time.monotonic() - self.last_keepalive > self.behaviour.get("keepalive_timeout", 3.0):
                self.dead, self.dead_reason = True, "timeout"
                continue
            tick += 1
            self._emit(DATA_NOTIFY, telemetry_frame(0, tick, self.behaviour.get("speed_raw", 0)))
            self._emit(DATA_NOTIFY, telemetry_frame(1, tick))

    async def write_gatt_char(self, uuid: str, data: bytes, response: bool = False) -> None:
        data = bytes(data)
        if uuid == CMD_WRITE:
            text = data.decode()
            if self.behaviour.get("stall_on_at") and self.rng.random() < self.behaviour["stall_on_at"]:
                self.dead, self.dead_reason = True, "at"
            reply = {"AT+TYPE?": b"OK+TYPE:B", "AT+DEVICE?": b"OK+DEVICE[807688 ]"}.get(text)
            if reply and not self.dead:
                await asyncio.sleep(0.08)
                self._emit(CMD_NOTIFY, reply)
            return
        if data == KEEPALIVE:
            self.last_keepalive = time.monotonic()
            if self.dead and self.dead_reason == "timeout":
                self.dead = False   # like the real scooter: keep-alives revive a stream that timed out
        elif data == START:
            self.last_keepalive = time.monotonic()
            if self.in_bridge:
                self.in_bridge = False
                if self.behaviour.get("stall_after_bridge"):
                    self.dead, self.dead_reason = True, "bridge"
            elif not self.streaming:
                self.streaming = True
                if not self.task:
                    self.task = asyncio.ensure_future(self._stream())
        elif data == ENTER_BRIDGE:
            self.in_bridge = True
        elif data == READ_CONTROL_WORD and self.in_bridge:
            await asyncio.sleep(0.1)
            self._emit(DATA_NOTIFY, fake_bridge_reply())


# ---------------------------------------------------------------------------------------------------------------
# Running and reporting
# ---------------------------------------------------------------------------------------------------------------

async def make_factory(args):
    if args.simulate:
        behaviour = {"stall_after_bridge": True, "stall_on_at": 0.0, "keepalive_timeout": 3.0, "seed": args.seed,
                     "speed_raw": 8000 if args.throttle else 0}

        async def factory(callback):
            return FakeClient(callback, behaviour)
        return factory

    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        sys.exit("bleak is not installed. Run:  python3 -m venv .venv && .venv/bin/pip install bleak")

    async def factory(callback):
        device = getattr(args, "cached_device", None)
        if device is None:
            print("Scanning for the scooter ...")

            def wanted(candidate, advert) -> bool:
                name = candidate.name or advert.local_name or ""
                found = (candidate.address == args.address) if args.address else name.startswith(args.name_prefix)
                if found:
                    args.scan_rssi = advert.rssi
                return found

            device = await BleakScanner.find_device_by_filter(wanted, timeout=15)
            if device is None:
                sys.exit("No scooter found. Is it on, and is the phone's Bluetooth off / Erup closed?")
            print(f"Found {device.name or 'scooter'}")
            args.cached_device = device
        return BleakClient(device, disconnected_callback=callback)
    return factory


def environment(args) -> dict:
    info = {"python": platform.python_version(), "platform": platform.platform(), "machine": platform.machine(),
            "started": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "simulated": args.simulate}
    try:
        import bleak
        info["bleak"] = getattr(bleak, "__version__", "?")
    except ImportError:
        info["bleak"] = None
    return info


async def status_loop(link: Link, args) -> None:
    """Prints a line every 10 s so you can see the run is alive, and reminds you to keep the throttle held."""
    last_count, last_t = 0, time.monotonic()
    while True:
        await asyncio.sleep(10)
        now = time.monotonic()
        count = len(link.frame_times)
        rate = (count - last_count) / (now - last_t)
        age = "never" if not link.frame_times else f"{now - link.frame_times[-1]:.1f} s ago"
        speed = link.speed_kmh()
        print(f"   [{link.rec.now():6.0f} s] {rate:4.1f} frames/s, last frame {age}, speed {speed} km/h, gaps {len(link.gaps)}, "
              f"connected {link.connected}")
        if args.throttle and speed is not None and speed < 0.5 and link.zero_speed_since and now - link.zero_speed_since > 40:
            print("   ! speed has been 0 for a while: the scooter may switch itself off. Hold the throttle (wheel off the ground).")
        last_count, last_t = count, now


async def run(args) -> int:
    chosen = ALL_ORDER if args.scenarios == "all" else [s.strip() for s in args.scenarios.split(",") if s.strip()]
    unknown = [s for s in chosen if s not in SCENARIOS]
    if unknown:
        sys.exit(f"Unknown scenario(s): {', '.join(unknown)}. Use --list.")
    if args.quick:
        args.duration, args.step_seconds, args.rounds = min(args.duration, 12.0), 4.0, 2
    if not args.simulate and not args.yes:
        print("The scooter beeps on every connection and some experiments reconnect on purpose.")
        print("Keep it on and standing still, and close Erup / turn the phone's Bluetooth off.")
        if input("Continue? [y/N] ").strip().lower() != "y":
            return 1

    outdir = Path(args.out or f"diagnostics-{dt.datetime.now():%Y%m%d-%H%M%S}")
    rec = Recorder(outdir)
    link = Link(rec, args, await make_factory(args))
    summary = {"environment": environment(args), "scenarios": {}, "order": chosen}
    rec.event("run_begin", scenarios=chosen, simulated=args.simulate)
    try:
        if args.throttle:
            print("Throttle mode: keep the throttle held with the rear wheel OFF THE GROUND (or the scooter fixed in place),\n"
                  "so it stays awake. Speed is recorded with every result, so stalls can be compared moving vs. standing.")
        info = await link.connect()
        summary["first_connection"] = info
        print(f"Connected: {info}")
        status = asyncio.ensure_future(status_loop(link, args))
        for name in chosen:
            func, description = SCENARIOS[name]
            print(f"\n== {name}: {description}")
            rec.event("scenario_begin", name=name)
            began = time.monotonic()
            try:
                if not link.connected:
                    await link.reconnect()
                result = await func(link, args)
            except Exception as error:  # noqa: BLE001 - keep going, record why
                result = {"error": f"{type(error).__name__}: {error}"}
            result["seconds"] = round(time.monotonic() - began, 1)
            result["telemetry"] = telemetry_summary(link.samples, began)
            summary["scenarios"][name] = result
            rec.event("scenario_end", name=name, verdict=result.get("verdict"), error=result.get("error"))
            print(f"   -> {result.get('verdict') or result.get('error')}")
    except KeyboardInterrupt:
        print("\nInterrupted, writing what was collected.")
    finally:
        try:
            status.cancel()
        except NameError:
            pass
        await link.disconnect()
        summary["totals"] = {"connections": link.connections, "link_losses": link.disconnect_events,
                             "gaps_over_1s": len(link.gaps), "frames": len(link.frame_times),
                             "keepalives_sent": link.keepalives_sent, "decoder_dropped_bytes": link.decoder.dropped,
                             "callback_errors": link.callback_errors}
        summary["metrics"] = link_metrics(link)
        summary["gaps"] = link.gaps
        summary["link_losses_detail"] = [e for e in rec.events if e["kind"] == "link_lost"]
        summary["gap_causes"] = dict(Counter((g["last_other_tx"] or {}).get("label", "none within the session") for g in link.gaps))
        (outdir / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
        (outdir / "REPORT.md").write_text(render_report(summary))
        rec.close()
    print(f"\nWrote {outdir}/REPORT.md, summary.json, events.jsonl and frames.csv")
    return 0


def render_report(summary: dict) -> str:
    env, totals = summary["environment"], summary.get("totals", {})
    lines = ["# Scooter connection diagnostics", "",
             f"Run: {env['started']} ({'SIMULATED scooter' if env['simulated'] else 'real scooter'}); python {env['python']}, "
             f"bleak {env['bleak']}, {env['platform']}", "",
             "## Totals", "",
             f"- Connections: {totals.get('connections')}, link losses seen: {totals.get('link_losses')}",
             f"- Telemetry frames: {totals.get('frames')}, keep-alives sent: {totals.get('keepalives_sent')}",
             f"- Gaps over {GAP_SECONDS:.0f} s: {totals.get('gaps_over_1s')}",
             *( [f"- **Script errors while handling notifications: {totals['callback_errors']}. See events.jsonl (callback_error). Results may be incomplete.**"] if totals.get("callback_errors") else [] ), ""]
    causes = summary.get("gap_causes") or {}
    if causes:
        lines += ["### What the app-style traffic was just before each gap", ""]
        lines += [f"- {label}: {count}" for label, count in sorted(causes.items(), key=lambda kv: -kv[1])]
        lines.append("")
    metrics = summary.get("metrics") or {}
    if metrics:
        lines += ["## Metrics", "", "How the scooter and the Bluetooth stack delivered data over the whole run.", "",
                  "```json", json.dumps(metrics, indent=2, default=str), "```", ""]
    auto_off = [e for e in summary.get("link_losses_detail", []) if e.get("possible_auto_off")]
    if auto_off:
        lines += [f"**{len(auto_off)} link loss(es) happened after more than a minute at zero speed with no frames: "
                  "the scooter probably switched itself off. Hold the throttle during long tests.**", ""]
    lines += ["## Findings", ""]
    for name in summary["order"]:
        result = summary["scenarios"].get(name)
        if result:
            lines.append(f"- **{name}**: {result.get('verdict') or result.get('error')}")
    lines.append("")
    for name in summary["order"]:
        result = summary["scenarios"].get(name)
        if not result:
            continue
        lines += [f"## {name}", "", f"{SCENARIOS[name][1]}. Took {result.get('seconds')} s.", "", "```json",
                  json.dumps({k: v for k, v in result.items() if k not in ('seconds',)}, indent=2, default=str), "```", ""]
    lines += ["## How to read this", "",
              "- A stall that happens in **baseline** with keep-alives only is the scooter's own behaviour.",
              "- A stall right after **at** or **bridge** traffic means the app's own reads trigger it. Set 'Pause automatic reads' in Erup's Debug screen to confirm.",
              "- **recovery** shows the cheapest step that revives the stream. Only the reconnect step beeps.",
              "- **suspend** shows how late a keep-alive may be, which is what iOS suspension does to the app.", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------------
# Analysing an export from the app
# ---------------------------------------------------------------------------------------------------------------

EVENT_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z) (fg|bg) (\w+): (.*)$")
FRAME_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:]+Z) (RX|TX) (frame 1|frame 2|AT|control|lock[^ ]*) ?(.*)$")


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def beep_section(events: list) -> list[str]:
    """The scooter beeps every time a connection is made, so every 'link established' is a beep. Explains each one."""
    beeps = []
    for index, event in enumerate(events):
        if event[2] == "connection" and event[3].startswith("link established"):
            cause = "first connection of this app run"
            for earlier in reversed(events[:index]):
                text = earlier[3]
                if "ropping the link to reconnect" in text:
                    cause = "the APP dropped the link on purpose after a stalled stream (avoidable)"
                    break
                if text.startswith("link lost"):
                    detail = text.split(";")[0].replace("link lost: ", "")
                    if "no error (clean disconnect)" in detail:
                        # Radio loss and the scooter closing the link both come with an error. A clean disconnect is the app's own.
                        cause = "the APP dropped the link (clean disconnect, no error from Bluetooth) (avoidable)"
                    else:
                        cause = f"the LINK was lost: {detail}"
                    break
                if "session ended" in text and "stream" in earlier[2]:
                    continue
            beeps.append((event[0], event[1], cause))
    out = ["", "## Beeps (every connection makes the scooter beep)", "", f"- {len(beeps)} connection(s) in this log"]
    if len(beeps) > 1:
        gaps = [(b[0] - a[0]).total_seconds() for a, b in zip(beeps, beeps[1:])]
        out.append(f"- time between beeps: shortest {min(gaps):.0f} s, median {statistics.median(gaps):.0f} s, longest {max(gaps):.0f} s")
    for start, where, cause in beeps:
        out.append(f"- {start:%H:%M:%S} ({where}): {cause}")
    by_cause = Counter("app-initiated reconnect" if "APP dropped" in c else "link lost" if "LINK was lost" in c else "first connection" for _, _, c in beeps)
    if beeps:
        out.append("- summary: " + ", ".join(f"{count} x {name}" for name, count in by_cause.most_common()))
        if by_cause.get("app-initiated reconnect"):
            out.append("  - app-initiated beeps can be reduced by waiting longer before dropping a quiet link")
        if by_cause.get("link lost"):
            out.append("  - 'connection timeout' means the radio link was lost (signal, body shadowing the phone in a pocket); "
                       "'the scooter ended the link' means the scooter closed it; neither can be avoided by the app, only reconnected faster")
    return out


def analyze(path: Path) -> str:
    events, frames = [], []
    for raw in path.read_text().splitlines():
        if match := EVENT_LINE.match(raw):
            events.append((parse_time(match[1]), match[2], match[3], match[4]))
        elif match := FRAME_LINE.match(raw):
            frames.append((parse_time(match[1]), match[2], match[3], match[4]))
    header = [line for line in path.read_text().splitlines()[:16] if ": " in line and not line.startswith("20")]
    out = [f"# Analysis of {path.name}", ""] + [f"- {line}" for line in header] + [""]
    if not events:
        return "\n".join(out + ["No events found in the file."])

    out += [f"## Overview", "", f"- Events: {len(events)} from {events[0][0]:%H:%M:%S} to {events[-1][0]:%H:%M:%S} UTC",
            f"- Foreground / background events: {sum(1 for e in events if e[1] == 'fg')} / {sum(1 for e in events if e[1] == 'bg')}",
            "- By category: " + ", ".join(f"{k} {v}" for k, v in Counter(e[2] for e in events).most_common())]
    links = [e for e in events if "link lost" in e[3]]
    stalls = [e for e in events if "stream stalled" in e[3] or "stalled for" in e[3]]
    quiet_ok = [e for e in events if "frames are back" in e[3]]
    out += [f"- Links lost: {len(links)}, stalls detected: {len(stalls)}, recovered without reconnect: {len(quiet_ok)}", ""]

    out += beep_section(events)

    rx = [f for f in frames if f[1] == "RX" and f[2] == "frame 1"]
    gaps = []
    for a, b in zip(rx, rx[1:]):
        length = (b[0] - a[0]).total_seconds()
        if length >= 2:
            gaps.append((a[0], b[0], length))
    generated = next((parse_time(l.split(" ", 1)[1]) for l in path.read_text().splitlines()[:3] if l.startswith("Generated")), None)
    if rx and generated and (generated - rx[-1][0]).total_seconds() >= 2:
        # The export ended while the stream was silent: the last gap has no frame after it.
        gaps.append((rx[-1][0], generated, (generated - rx[-1][0]).total_seconds()))
    out += ["## Frame gaps (2 s or longer, from the frame log, one-second resolution)", ""]
    if not gaps:
        out.append("None in the frame log.")
    tx = [f for f in frames if f[1] == "TX"]
    bridge_events = [e for e in events if e[2] == "bridge"]
    def readable(f) -> str:
        if f[2] == "AT":
            try:
                return "AT " + bytes.fromhex(f[3]).decode("utf-8", "replace")
            except ValueError:
                return "AT"
        return f"{f[2]} {f[3][:24]}"

    kinds = Counter()
    for start, end, length in gaps:
        near = [readable(f) for f in tx if -1 <= (f[0] - start).total_seconds() <= 4]
        bridge = [e[3] for e in bridge_events if -2 <= (e[0] - start).total_seconds() <= 6]
        ctx = [e for e in events if e[2] in ("app", "connection") and -8 <= (e[0] - start).total_seconds() <= 0][-3:]
        before = [e for e in events if e[0] <= start]
        in_background = bool(before) and before[-1][1] == "bg"
        left_fg = [e for e in before if "left the foreground" in e[3] and (start - e[0]).total_seconds() <= 8] if in_background else []
        bridge_near = [e for e in bridge_events if -2 <= (e[0] - start).total_seconds() <= 6]
        label = ("right after the app left the foreground" if left_fg else
                 "while the app was in the background" if in_background and not bridge_near else
                 "right after a bridge exchange" if bridge_near else
                 "right after AT commands, app in the foreground" if near else "in the foreground with no app traffic nearby")
        kinds[label] += 1
        out.append(f"- {start:%H:%M:%S} to {end:%H:%M:%S} UTC: **{length:.0f} s without frames**, {label}"
                   + (" (still silent when the export was made)" if end == generated else ""))
        out.append(f"  - app sent around the start: {', '.join(near) if near else 'only keep-alives (not in the frame log)'}")
        if bridge:
            out.append(f"  - bridge activity: {'; '.join(bridge)}")
        for e in ctx:
            out.append(f"  - just before: {e[1]} {e[2]}: {e[3]}")
    if gaps:
        out += ["", "## What preceded the gaps", ""] + [f"- {count} gap(s) {label}" for label, count in kinds.most_common()]
    first_attempts = [e for e in stalls if "attempt 1" in e[3] or "quiet restart first" in e[3] or "stream stalled:" in e[3]]
    out += ["", f"## Stall events ({len(first_attempts) or len(stalls)} distinct) and how they ended", ""]
    for e in stalls:
        out.append(f"- {e[0]:%H:%M:%S} {e[1]}: {e[3]}")
    out += ["", "## Connection state timeline", ""]
    out += [f"- {e[0]:%H:%M:%S} {e[1]}: {e[3]}" for e in events if e[2] == "connection" and ("state" in e[3] or "link" in e[3] or "requesting" in e[3])]
    sessions = [e for e in events if "session ended" in e[3]]
    if sessions:
        out += ["", "## Session lengths (frames per session)", ""]
        out += [f"- {e[0]:%H:%M:%S}: {e[3]}" for e in sessions]
    health = [e for e in events if e[3].startswith("stream ok")]
    if health:
        out += ["", "## Stream health lines", ""] + [f"- {e[0]:%H:%M:%S} {e[1]}: {e[3]}" for e in health]
    ats = [f for f in tx if f[2] == "AT"]
    if ats:
        out += ["", "## AT commands sent", ""] + [f"- {f[0]:%H:%M:%S}: {readable(f)}" for f in ats]
    replies = [f for f in frames if f[1] == "RX" and f[2] == "AT"]
    out += ["", "## AT commands", "", f"- sent {len(ats)}, replies {len(replies)}"]
    if ats and len(replies) < len(ats):
        out.append(f"- {len(ats) - len(replies)} AT command(s) never got a reply. Replies stop when the stream is stalled too, "
                   "so this is a second symptom of the same fault.")
    out += ["", "## Reading this", "",
            "- Compare the gap start with the last non-keep-alive write: a gap 0-4 s after AT traffic or a bridge exchange points at the app's own reads.",
            "- A stall with no such write nearby (and with the app in the foreground) points at the scooter.",
            "- 'frames are back after the quiet restart' means the beep-free recovery worked; 'dropping the link' means it did not."]
    result = "\n".join(out) + "\n"
    path.with_suffix(".analysis.md").write_text(result)
    return result


# ---------------------------------------------------------------------------------------------------------------
# Self test (real frames from the phone export, no scooter needed)
# ---------------------------------------------------------------------------------------------------------------

REAL_FRAMES = [
    "ab 00 19 01 01 5b 20 6c 20 6c 01 98 00 0f 14 14 00 02 00 00 33 0c 01 c1 7b",
    "ab 01 19 00 06 0c 15 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 87 cd",
    "ab 00 19 01 01 5b 26 ac 26 ac 01 98 00 09 15 15 00 03 00 00 34 0c 01 a8 1b",
]


def selftest() -> int:
    failures = []

    def check(name: str, condition: bool) -> None:
        print(("ok   " if condition else "FAIL ") + name)
        if not condition:
            failures.append(name)

    for text in REAL_FRAMES:
        check(f"real frame CRC valid: {text[:17]}...", crc_ok(bytes.fromhex(text)))
    check("modbus read-5-registers request is 01 03 00 00 00 05 85 C9", READ_CONTROL_WORD == bytes.fromhex("0103000000058 5c9".replace(" ", "")))
    check("keep-alive bytes", KEEPALIVE == bytes.fromhex("a502fd5a"))
    decoder = StreamDecoder()
    frame = bytes.fromhex(REAL_FRAMES[0])
    out = decoder.feed(frame[:20]) + decoder.feed(frame[20:])
    check("a frame split into 20 + 5 bytes is reassembled", len(out) == 1 and out[0][0] == "telemetry")
    parsed = out[0][1].fields
    check("decodes battery 91 %, 40.8 V, speed 8.3 km/h", parsed["battery"] == 91 and parsed["voltage"] == 40.8 and parsed["speed_raw"] == 0x206C)
    noisy = StreamDecoder().feed(bytes([0x00, 0x05]) + frame + bytes.fromhex(REAL_FRAMES[1]))
    check("garbage in front is skipped, both frames decode", [kind for kind, _ in noisy] == ["telemetry", "telemetry"])
    reply = fake_bridge_reply(0x0A00)
    events = BridgeDecoder().feed(reply[:7]) + BridgeDecoder().feed(reply)
    check("a bridge reply (app framing: 01 03 addr addr count payload crc) decodes", events and events[0][0] == "bridge")
    split = BridgeDecoder()
    parts = split.feed(reply[:7]) + split.feed(reply[7:])
    check("a bridge reply split across two notifications decodes", len(parts) == 1 and bridge_payload(parts[0][1])[:2] == bytes([0x0A, 0x00]))
    both = BridgeDecoder().feed(reply + with_crc(bytes([0x01, 0x10, 0x00, 0x00, 0x00, 0x01])))
    check("a read reply followed by a write acknowledgement decodes as two frames", [k for k, _ in both] == ["bridge", "bridge_ack"])
    stats = frame_stats([0.0, 0.2, 0.4, 3.0, 3.2])
    check("frame stats count a 2.6 s gap", stats["gaps_over_1s"] == 1 and stats["interval_max_ms"] == 2600)
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Diagnose scooter stream stalls from a Mac.")
    sub = parser.add_subparsers(dest="command")
    runner = sub.add_parser("run", help="run experiments against the scooter")
    runner.add_argument("--scenarios", default="baseline,bridge,at,recovery", help="comma separated, or 'all'")
    runner.add_argument("--duration", type=float, default=60, help="seconds for baseline and soak")
    runner.add_argument("--step-seconds", type=float, default=8, help="seconds per step in cadence, at")
    runner.add_argument("--rounds", type=int, default=4, help="repeats in bridge, at, recovery, reconnect")
    runner.add_argument("--soak-mode", choices=["app", "quiet"], default="app")
    runner.add_argument("--quick", action="store_true", help="short durations for a first look")
    runner.add_argument("--address", help="scooter address (CoreBluetooth UUID on a Mac); default: find by name")
    runner.add_argument("--name-prefix", default=NAME_PREFIX)
    runner.add_argument("--out", help="output folder")
    runner.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    runner.add_argument("--response-writes", action="store_true", help="write with response in every scenario (the official app does)")
    runner.add_argument("--throttle", action="store_true", help="you hold the throttle (wheel off the ground) to keep the scooter awake")
    runner.add_argument("--bridge-every", type=float, default=30, help="soak 'app' mode: repeat the bridge read every N seconds (0 = once)")
    runner.add_argument("--bridge-variant", choices=BRIDGE_VARIANTS, default="app", help="how the soak closes its bridge reads")
    runner.add_argument("--simulate", action="store_true", help="use a fake scooter that stalls like the real one")
    runner.add_argument("--seed", type=int, default=7)
    analyzer = sub.add_parser("analyze", help="analyse an Erup diagnostics export")
    analyzer.add_argument("file", type=Path)
    sub.add_parser("selftest", help="check the decoder against real frames")
    parser.add_argument("--list", action="store_true", help="list the scenarios")
    args = parser.parse_args()

    if args.list:
        for name in ALL_ORDER:
            print(f"{name:12} {SCENARIOS[name][1]}")
        return 0
    if args.command == "selftest":
        return selftest()
    if args.command == "analyze":
        print(analyze(args.file))
        return 0
    if args.command == "run":
        return asyncio.run(run(args))
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
