#!/usr/bin/env bash
# Play 1 kHz tones (L only, R only, both) through the default sink; measure with the internal mics.
# A working channel reads well above the "silence" baseline.
set -euo pipefail
D=$(mktemp -d); cd "$D"
python3 -I - <<'PY'
import wave,struct,math
for name,ch in (('L',0),('R',1),('S',None)):
    w=wave.open(f'tone_{name}.wav','wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    fr=bytearray()
    for i in range(96000):
        v=int(12000*math.sin(2*math.pi*1000*i/48000))
        fr+=struct.pack('<hh',v if ch in (0,None) else 0, v if ch in (1,None) else 0)
    w.writeframes(bytes(fr)); w.close()
PY
for t in silence L R S; do
  pw-record --rate 48000 --channels 2 --format s16 rec_$t.wav & P=$!
  if [ $t = silence ]; then python3 -c 'import time;time.sleep(2)'; else pw-play tone_$t.wav; fi
  kill $P; wait $P 2>/dev/null || true
done
python3 -I - <<'PY'
import wave,struct,math
for t in ('silence','L','R','S'):
    w=wave.open(f'rec_{t}.wav'); d=w.readframes(w.getnframes())
    s=struct.unpack(f'<{len(d)//2}h',d); s=s[len(s)//4:]
    rms=lambda x: math.sqrt(sum(v*v for v in x)/len(x))
    print(f'{t:8s} mic rms {rms(s):8.1f}')
PY
rm -r "$D"
