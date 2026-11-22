"""Places one GPT-Live call from this Mac the way the app does, to time the vendor side.

Builds the session the host would (`tools.voice_live.build_session_config` from HERMES_SRC), plays two
spoken questions into the call (greeting at 3 s, a calendar request at 30 s, room noise between), answers
any delegation as Hermes would after HERMES_DELAY seconds, and prints every event with its time: when the
voice starts and stops talking, delegations, transcripts and `session.closed` with its reason.
Run it through scripts/fork/voice-live-probe, which makes the speech and the Python environment.
"""
import asyncio, json, os, sys, time, fractions, wave
import numpy as np
from aiortc import RTCPeerConnection, RTCSessionDescription, MediaStreamTrack
from av import AudioFrame
sys.path.insert(0, os.path.expanduser(os.environ.get("HERMES_SRC", "~/.hermes/hermes-agent")))
HERMES_DELAY = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
TOTAL = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
def load(p):
    w = wave.open(p); return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
SPEECH = os.environ["PROBE_SPEECH_DIR"]
SCRIPT = [(3.0, "greeting", load(os.path.join(SPEECH, "greeting.wav"))),
          (30.0, "calendar request", load(os.path.join(SPEECH, "request.wav")))]
start = time.time()
def log(*a): print("%6.1fs" % (time.time() - start), *a, flush=True)
class Mic(MediaStreamTrack):
    kind = "audio"
    def __init__(self): super().__init__(); self.pts = 0; self.t0 = None; self.queue = list(SCRIPT); self.cur = None; self.pos = 0
    async def recv(self):
        if self.t0 is None: self.t0 = time.time()
        wait = self.t0 + self.pts / 48000 - time.time()
        if wait > 0: await asyncio.sleep(wait)
        n = 960; now = self.pts / 48000
        if self.cur is None and self.queue and now >= self.queue[0][0]:
            _, name, self.cur = self.queue.pop(0); self.pos = 0; log("MIC  speaking", name)
        if self.cur is not None:
            chunk = self.cur[self.pos:self.pos+n]; self.pos += n
            if len(chunk) < n: chunk = np.pad(chunk, (0, n-len(chunk)))
            if self.pos >= len(self.cur): self.cur = None; log("MIC  done speaking")
            data = chunk.reshape(1, n)
        else:
            data = (np.random.randn(1, n) * 30).astype(np.int16)  # room noise
        f = AudioFrame.from_ndarray(data, format="s16", layout="mono"); f.sample_rate = 48000
        f.pts = self.pts; f.time_base = fractions.Fraction(1, 48000); self.pts += n
        return f
async def listen(track):
    loud = False
    while True:
        try: fr = await track.recv()
        except Exception: return
        a = fr.to_ndarray().astype(np.float32); rms = float(np.sqrt((a**2).mean())) / 32768
        if rms > 0.01 and not loud: loud = True; log("VOICE starts talking")
        elif rms < 0.003 and loud: loud = False; log("VOICE stops")
async def main():
    from tools import voice_live
    pc = RTCPeerConnection(); pc.addTrack(Mic())
    @pc.on("track")
    def t(track): asyncio.ensure_future(listen(track))
    @pc.on("connectionstatechange")
    def cs(): log("PC", pc.connectionState)
    ch = pc.createDataChannel("oai-events"); done = asyncio.Event(); n = [0]; text = {}
    def send(typ, content, did):
        n[0] += 1; ch.send(json.dumps({"type": typ, "event_id": "e%d" % n[0], "delegation_id": did, "content": content}))
    async def hermes(did):
        await asyncio.sleep(min(2, HERMES_DELAY)); send("session.thinking.append", "Hermes is working: calendar. Not done yet.", did); log("SENT thinking")
        await asyncio.sleep(max(0, HERMES_DELAY - 2)); send("session.commentary.append", "明天上午十點有團隊週會，下午三點要看牙醫。", did); log("SENT answer")
    @ch.on("message")
    def m(msg):
        e = json.loads(msg); typ = e.get("type")
        if typ.endswith("transcript.delta"):
            k = typ.split(".")[1]; text[k] = text.get(k, "") + e.get("delta", e.get("text", "")); return
        for k in list(text): log("TEXT", k, text.pop(k))
        log("EVT", typ, json.dumps({k: v for k, v in e.items() if k not in ("type",)}, ensure_ascii=False)[:200])
        if typ == "session.delegation.created": asyncio.ensure_future(hermes(e.get("delegation_id") or e.get("id") or (e.get("delegation") or {}).get("id")))
        if typ == "session.closed": done.set()
    await pc.setLocalDescription(await pc.createOffer())
    voice_live._voice_section = lambda: {}
    import urllib.request
    body = json.dumps({"session": voice_live.build_session_config(None), "transport": {"type": "webrtc", "sdp": pc.localDescription.sdp}}).encode()
    req = urllib.request.Request(voice_live.DEFAULT_LIVE_BASE_URL.rstrip("/") + "/live/sessions", data=body, method="POST",
        headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"], "Content-Type": "application/json"})
    r = json.loads(await asyncio.to_thread(lambda: urllib.request.urlopen(req, timeout=30).read()))
    log("session created")
    await pc.setRemoteDescription(RTCSessionDescription(r["transport"]["sdp"], "answer"))
    try: await asyncio.wait_for(done.wait(), TOTAL)
    except asyncio.TimeoutError: log("still open at", TOTAL)
    for k in list(text): log("TEXT", k, text.pop(k))
    if ch.readyState == "open": ch.send(json.dumps({"type": "session.close"}))
    await asyncio.sleep(1); await pc.close()
asyncio.run(main())
