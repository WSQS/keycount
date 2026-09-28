"""Probe: can we hook global keyboard events on this machine?"""
import sys, time, threading
from collections import Counter
from pynput import keyboard

hits = Counter()
stop = threading.Event()

def on_press(key):
    try:
        name = key.char if key.char else str(key)
    except AttributeError:
        name = str(key)
    hits[name] += 1
    print("PRESS", name, flush=True)

listener = keyboard.Listener(on_press=on_press)
listener.start()
print("listener started; waiting 8s for injected keys...", flush=True)
time.sleep(8)
listener.stop()
print("TOTAL", sum(hits.values()), dict(hits), flush=True)
