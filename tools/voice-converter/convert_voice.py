#!/usr/bin/env python3
"""Turns a downloaded RVC v2 voice (a .pth file, or a .zip with one inside) into a Swoopy voice folder.

  python3 convert_voice.py MODEL.pth [--name NAME] [--pitch high|medium|low|HZ] [--voices-dir DIR] [--app APP]
                           [--ahead-ms 700]

Writes DIR/<id>/ (default DIR: ~/Library/Application Support/Pitch Shift/Voices):
  voice.json      the voice's name, its Natural mode settings (from --pitch) and its AI voice; credits = the file name
  <id>.mlmodelc   the AI voice, Core ML with 8-bit weights, made for Swoopy's AI voice ("Faster <-> More real")
Swoopy's own speech reader (contentvec_ahead.mlmodelc, inside the app) is used with it, so it is not copied.

The AI voice is made in the look-ahead shape of Swoopy 3.1 (as research/voicechanger/convert/convert_generator.py
--context-ms 1000 --ahead-ms 700 --right-ms 40): one file serves every look-ahead from 0 to 700 ms; the window is
1.92 s (T 192 frames), the flow runs over all of it and the decoder only on the 31 frames the app picks (input
"pick"). --ahead-ms 0 makes the first shape instead (Swoopy 3.0, contentvec.mlmodelc; no look-ahead).

Accepts RVC v2 voices made at 32, 40 or 48 kHz (RVC WebUI, Applio and their forks). Refuses RVC v1 voices and
voices made without pitch. Usually run by tools/convert-voice.sh, which sets up Python and the packages first.

The model code below is re-written from RVC-Project/Retrieval-based-Voice-Conversion-WebUI (tag 2.2.231006,
infer/lib/infer_pack/*.py, MIT License, Copyright (c) 2023 liujing04, 源文雨, Ftps), inference only: masks dropped
(every frame of the fixed window is used), weight norm folded into plain weights, the NSF sine/noise source moved out
of the model (the app makes it, keeping the phase exact across pieces), the speaker baked in, and only some frames
decoded (as RVC's real-time code does). Keep the window layout and the model's inputs in step with
Sources/Voice/VoiceModel.mm and the app's contentvec_ahead.mlmodelc.
"""
import argparse
import json
import math
import os
import re
import shutil
import sys
import tempfile
import time
import typing
import zipfile

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# ------------------------------------------------------------------------------------------- the window layout

# All in 10 ms frames. The app's built-in voices use a 160 ms hop with 1 s of past sound, plus (look-ahead shape,
# Swoopy 3.1) up to 700 ms of look-ahead in the same window, and 40 ms decoded after each piece and dropped
# (context 1710 ms after rounding T to an even number: T 192). The window is read from the app's speech reader
# (contentvec_ahead.mlmodelc) when it can be found.
HOP_MS, XFADE_MS, SOLA_MS, MARGIN_MS, DEFAULT_CONTEXT_MS = 160, 40, 10, 60, 1000
DEFAULT_AHEAD_MS, RIGHT_MS = 700, 40


def window_layout(hop_ms=HOP_MS, context_ms=DEFAULT_CONTEXT_MS, xfade_ms=XFADE_MS, sola_ms=SOLA_MS, margin_ms=MARGIN_MS,
                  ahead_ms=0, right_ms=RIGHT_MS):
    """ahead_ms 0: the first shape (the flow on the last DEC + 24 frames, the decoder on the last DEC). ahead_ms > 0:
    the window grows by ahead_ms, the flow covers all of it (FLOW = T) and the decoder runs on DEC = M + H + X + S + R
    frames the app picks (as research/voicechanger/convert/convert_generator.py --ahead-ms)."""
    H, C, X, S, M, A = hop_ms // 10, context_ms // 10, xfade_ms // 10, sola_ms // 10, margin_ms // 10, ahead_ms // 10
    C += A
    T = C + X + S + H
    if T % 2:
        C += 1
        T += 1
    if A:
        R = right_ms // 10
        assert T - A - (H + X + S) - M >= 0, "look-ahead too big for the window"
        return dict(T=T, H=H, C=C, X=X, S=S, M=M, A=A, R=R, DEC=M + H + X + S + R, FLOW=T)
    return dict(T=T, H=H, C=C, X=X, S=S, M=M, A=0, R=0, DEC=H + X + S + M, FLOW=H + X + S + M + 24)


def app_window_frames(app, reader="contentvec_ahead.mlmodelc"):
    """T (10 ms frames) of the app's speech reader, from <reader>/model.mil ("audio" is [1, T*160]), and the app."""
    for base in [app, "/Applications/Swoopy.app", os.path.expanduser("~/Applications/Swoopy.app"),
                 "/Applications/Pitch Shift.app", os.path.expanduser("~/Applications/Pitch Shift.app")]:
        if not base:
            continue
        mil = os.path.join(base, "Contents/Resources/Voices", reader, "model.mil")
        if not os.path.isfile(mil):
            continue
        with open(mil, "r", errors="replace") as f:
            head = f.read(4000)
        m = re.search(r"tensor<fp\d+, \[1, (\d+)\]> audio", head)
        if m and int(m.group(1)) % 160 == 0:
            return int(m.group(1)) // 160, base
    return None, None


# ------------------------------------------------------------------------------------------- reading RVC files

class Refused(Exception):
    """A file this converter can't use; the message is for the user."""


def fold_weight_norm(sd):
    """Plain weights from weight norm: X.weight_g + X.weight_v (old PyTorch) or X.parametrizations.weight.original0
    + original1 (newer PyTorch, Applio), normalised over every dimension but the first."""
    out = {}
    for k, v in sd.items():
        if k.endswith("weight_g") or k.endswith("parametrizations.weight.original0"):
            if k.endswith("weight_g"):
                base, vk = k[:-len("weight_g")], k[:-len("weight_g")] + "weight_v"
            else:
                base = k[:-len("parametrizations.weight.original0")]
                vk = base + "parametrizations.weight.original1"
            vv = sd[vk].float()
            g = v.float()
            dims = tuple(range(1, vv.dim()))
            out[base + "weight"] = vv * (g / vv.norm(dim=dims, keepdim=True))
        elif k.endswith("weight_v") or k.endswith("parametrizations.weight.original1"):
            continue
        else:
            out[k] = v.float()
    return out


def load_checkpoint(path):
    """(state dict, params) of an RVC v2 voice with pitch, or Refused with a plain reason."""
    try:
        with torch.serialization.safe_globals([typing.OrderedDict]):
            c = torch.load(path, map_location="cpu", weights_only=True)
    except Exception as e:  # not a PyTorch file, or one that would need to run code to open
        raise Refused("%s can't be read as an RVC voice (%s)." % (os.path.basename(path), str(e).split("\n")[0][:120]))
    if not isinstance(c, dict) or not ("weight" in c or "model" in c):
        raise Refused("%s isn't an RVC voice model (no voice weights inside)." % os.path.basename(path))
    sd = c.get("weight") if "weight" in c else c["model"]
    if not isinstance(sd, dict) or "enc_p.emb_phone.weight" not in sd or "emb_g.weight" not in sd:
        raise Refused("%s isn't an RVC voice model this converter knows." % os.path.basename(path))
    version = str(c.get("version", "")).lower()
    if version == "v1" or sd["enc_p.emb_phone.weight"].shape[1] == 256:
        raise Refused("%s is an RVC v1 voice. Swoopy needs RVC v2 voices (most voices made since mid-2023 are v2): "
                      "look for a v2 version of this voice." % os.path.basename(path))
    if sd["enc_p.emb_phone.weight"].shape[1] != 768:
        raise Refused("%s has an unusual speech input (%d values); Swoopy needs a standard RVC v2 voice."
                      % (os.path.basename(path), sd["enc_p.emb_phone.weight"].shape[1]))
    if str(c.get("f0", 1)) in ("0", "False") or "enc_p.emb_pitch.weight" not in sd:
        raise Refused("%s was made without pitch (an RVC \"no f0\" voice). Swoopy needs a voice made with pitch."
                      % os.path.basename(path))
    vocoder = str(c.get("vocoder", "HiFi-GAN"))
    if vocoder not in ("HiFi-GAN", "hifigan", ""):
        raise Refused("%s uses the %s sound maker; Swoopy only runs RVC's standard one (HiFi-GAN)." % (os.path.basename(path), vocoder))
    embedder = str(c.get("embedder_model", "contentvec")).lower()
    if embedder not in ("contentvec", "hubert", "hubert_base", "custom", ""):
        raise Refused("%s was made with the %s speech reader; Swoopy's reader is ContentVec (RVC's standard)."
                      % (os.path.basename(path), embedder))
    cfg = c.get("config")
    sr = c.get("sr")
    if isinstance(sr, str):
        sr = {"32k": 32000, "40k": 40000, "48k": 48000}.get(sr.lower(), None) or (int(sr) if sr.isdigit() else None)
    if isinstance(cfg, (list, tuple)) and len(cfg) >= 18:
        sr = sr or int(cfg[17])
        ups, upk, init_ch = list(cfg[12]), list(cfg[14]), int(cfg[13])
        rks, rds = list(cfg[10]), [list(d) for d in cfg[11]]
        std = dict(inter=cfg[2], hidden=cfg[3], filt=cfg[4], heads=cfg[5], layers=cfg[6], kernel=cfg[7], resblock=str(cfg[9]), gin=cfg[16])
        if std != dict(inter=192, hidden=192, filt=768, heads=2, layers=6, kernel=3, resblock="1", gin=256):
            raise Refused("%s has an unusual model size (%s); Swoopy needs a standard RVC v2 voice." % (os.path.basename(path), std))
    else:  # a base model ({'model'}): sizes from the first upsampler
        k0 = sd.get("dec.ups.0.weight_v", sd.get("dec.ups.0.parametrizations.weight.original1")).shape[2]
        sr = sr or {24: 48000, 20: 32000, 16: 40000}.get(k0)
        ups = {48000: [12, 10, 2, 2], 40000: [10, 10, 2, 2], 32000: [10, 8, 2, 2]}.get(sr)
        upk = {48000: [24, 20, 4, 4], 40000: [16, 16, 4, 4], 32000: [20, 16, 4, 4]}.get(sr)
        init_ch, rks, rds = 512, [3, 7, 11], [[1, 3, 5]] * 3
    if sr not in (32000, 40000, 48000):
        raise Refused("%s was made at %s Hz; Swoopy can use voices made at 32, 40 or 48 kHz." % (os.path.basename(path), sr))
    if int(np.prod(ups)) != sr // 100:
        raise Refused("%s has an unusual sound maker (%s for %d Hz)." % (os.path.basename(path), ups, sr))
    params = dict(inter_channels=192, hidden_channels=192, filter_channels=768, n_heads=2, n_layers=6, kernel_size=3,
                  upsample_rates=ups, upsample_kernel_sizes=upk, upsample_initial_channel=init_ch,
                  resblock_kernel_sizes=rks, resblock_dilation_sizes=rds, gin_channels=256,
                  spk_embed_dim=sd["emb_g.weight"].shape[0], sr=sr)
    info = {k: c[k] for k in ("version", "sr", "info", "f0") if k in c}
    return sd, params, info


# ------------------------------------------------------------------------------------------- the generator

LRELU = 0.1


class _LayerNormC(nn.Module):  # LayerNorm over the channels of (B, C, T)
    def __init__(self, c):
        super().__init__()
        self.gamma = nn.Parameter(torch.ones(c))
        self.beta = nn.Parameter(torch.zeros(c))

    def forward(self, x):
        return F.layer_norm(x.transpose(1, -1), (x.shape[1],), self.gamma, self.beta, 1e-5).transpose(1, -1)


class _RelMHA(nn.Module):
    """Self-attention with relative positions (window 10; the heads share the tables), as in VITS/RVC."""

    def __init__(self, c=192, heads=2, window=10):
        super().__init__()
        self.h = heads
        self.kc = c // heads
        self.w = window
        self.conv_q = nn.Conv1d(c, c, 1)
        self.conv_k = nn.Conv1d(c, c, 1)
        self.conv_v = nn.Conv1d(c, c, 1)
        self.conv_o = nn.Conv1d(c, c, 1)
        self.emb_rel_k = nn.Parameter(torch.zeros(1, 2 * window + 1, self.kc))
        self.emb_rel_v = nn.Parameter(torch.zeros(1, 2 * window + 1, self.kc))

    def _rel_emb(self, e, L: int):
        pad = max(L - (self.w + 1), 0)
        start = max((self.w + 1) - L, 0)
        if pad > 0:
            e = F.pad(e, [0, 0, pad, pad, 0, 0])
        return e[:, start:start + 2 * L - 1]

    @staticmethod
    def _rel_to_abs(x):  # (b, h, l, 2l-1) -> (b, h, l, l)
        b, h, l, _ = x.size()
        x = F.pad(x, [0, 1, 0, 0, 0, 0, 0, 0])
        x = x.view([b, h, l * 2 * l])
        x = F.pad(x, [0, l - 1, 0, 0, 0, 0])
        return x.view([b, h, l + 1, 2 * l - 1])[:, :, :l, l - 1:]

    @staticmethod
    def _abs_to_rel(x):  # (b, h, l, l) -> (b, h, l, 2l-1)
        b, h, l, _ = x.size()
        x = F.pad(x, [0, l - 1, 0, 0, 0, 0, 0, 0])
        x = x.view([b, h, l * l + l * (l - 1)])
        x = F.pad(x, [l, 0, 0, 0, 0, 0])
        return x.view([b, h, l, 2 * l])[:, :, :, 1:]

    def forward(self, x):
        b, d, L = x.shape
        q = self.conv_q(x).view(b, self.h, self.kc, L).transpose(2, 3) / math.sqrt(self.kc)
        k = self.conv_k(x).view(b, self.h, self.kc, L).transpose(2, 3)
        v = self.conv_v(x).view(b, self.h, self.kc, L).transpose(2, 3)
        scores = q @ k.transpose(-2, -1)
        rel = q @ self._rel_emb(self.emb_rel_k, L).unsqueeze(0).transpose(-2, -1)
        scores = scores + self._rel_to_abs(rel)
        p = torch.softmax(scores, dim=-1)
        out = p @ v + self._abs_to_rel(p) @ self._rel_emb(self.emb_rel_v, L).unsqueeze(0)
        return self.conv_o(out.transpose(2, 3).contiguous().view(b, d, L))


class _FFN(nn.Module):
    def __init__(self, c=192, f=768, k=3):
        super().__init__()
        self.k = k
        self.conv_1 = nn.Conv1d(c, f, k)
        self.conv_2 = nn.Conv1d(f, c, k)

    def _pad(self, x):
        return F.pad(x, [(self.k - 1) // 2, self.k // 2, 0, 0, 0, 0])

    def forward(self, x):
        return self.conv_2(self._pad(torch.relu(self.conv_1(self._pad(x)))))


class _TextEncoder(nn.Module):
    def __init__(self, c=192, f=768, heads=2, layers=6, k=3):
        super().__init__()
        self.c = c
        self.emb_phone = nn.Linear(768, c)
        self.emb_pitch = nn.Embedding(256, c)
        self.attn_layers = nn.ModuleList([_RelMHA(c, heads) for _ in range(layers)])
        self.norm_layers_1 = nn.ModuleList([_LayerNormC(c) for _ in range(layers)])
        self.ffn_layers = nn.ModuleList([_FFN(c, f, k) for _ in range(layers)])
        self.norm_layers_2 = nn.ModuleList([_LayerNormC(c) for _ in range(layers)])
        self.proj = nn.Conv1d(c, 2 * c, 1)

    def forward(self, feats50, pitch):
        # emb_phone is linear, so applying it before the x2 repeat equals RVC's repeat-then-project.
        ph = self.emb_phone(feats50)                                                   # (1, T/2, c)
        ph = ph.unsqueeze(2).expand(-1, -1, 2, -1).reshape(ph.shape[0], -1, self.c)    # nearest x2 -> (1, T, c)
        x = (ph + self.emb_pitch(pitch)) * math.sqrt(self.c)
        x = F.leaky_relu(x, 0.1).transpose(1, 2)                                       # (1, c, T)
        for a, n1, f, n2 in zip(self.attn_layers, self.norm_layers_1, self.ffn_layers, self.norm_layers_2):
            x = n1(x + a(x))
            x = n2(x + f(x))
        return self.proj(x)                                                            # (1, 2c, T): m, logs


class _WN(nn.Module):
    def __init__(self, hc=192, k=5, layers=3, gin=256):
        super().__init__()
        self.hc = hc
        self.n = layers
        self.cond_layer = nn.Conv1d(gin, 2 * hc * layers, 1)
        self.in_layers = nn.ModuleList([nn.Conv1d(hc, 2 * hc, k, padding=(k - 1) // 2) for _ in range(layers)])
        self.res_skip_layers = nn.ModuleList([nn.Conv1d(hc, 2 * hc if i < layers - 1 else hc, 1) for i in range(layers)])

    def forward(self, x, g):
        out = torch.zeros_like(x)
        gc = self.gc if hasattr(self, "gc") else self.cond_layer(g)
        for i in range(self.n):
            a = self.in_layers[i](x) + gc[:, i * 2 * self.hc:(i + 1) * 2 * self.hc, :]
            acts = torch.tanh(a[:, :self.hc]) * torch.sigmoid(a[:, self.hc:])
            rs = self.res_skip_layers[i](acts)
            if i < self.n - 1:
                x = x + rs[:, :self.hc]
                out = out + rs[:, self.hc:]
            else:
                out = out + rs
        return out


class _Coupling(nn.Module):
    def __init__(self, c=192, hc=192, gin=256):
        super().__init__()
        self.half = c // 2
        self.pre = nn.Conv1d(self.half, hc, 1)
        self.enc = _WN(hc, 5, 3, gin)
        self.post = nn.Conv1d(hc, self.half, 1)

    def reverse(self, x, g):
        x0, x1 = x[:, :self.half], x[:, self.half:]
        m = self.post(self.enc(self.pre(x0), g))
        return torch.cat([x0, x1 - m], 1)


class _ResBlock1(nn.Module):
    def __init__(self, ch, k, d):
        super().__init__()
        self.convs1 = nn.ModuleList([nn.Conv1d(ch, ch, k, 1, dilation=di, padding=(k * di - di) // 2) for di in d])
        self.convs2 = nn.ModuleList([nn.Conv1d(ch, ch, k, 1, dilation=1, padding=(k - 1) // 2) for _ in d])

    def forward(self, x):
        for c1, c2 in zip(self.convs1, self.convs2):
            x = c2(F.leaky_relu(c1(F.leaky_relu(x, LRELU)), LRELU)) + x
        return x


class _NSFDecoder(nn.Module):
    def __init__(self, ups, upk, init_ch=512, rks=(3, 7, 11), rds=((1, 3, 5),) * 3, gin=256):
        super().__init__()
        self.nk = len(rks)
        self.l_linear = nn.Linear(1, 1)  # m_source.l_linear (harmonic_num 0)
        self.conv_pre = nn.Conv1d(192, init_ch, 7, 1, padding=3)
        self.cond = nn.Conv1d(gin, init_ch, 1)
        self.ups = nn.ModuleList()
        self.noise_convs = nn.ModuleList()
        self.resblocks = nn.ModuleList()
        for i, (u, k) in enumerate(zip(ups, upk)):
            cin = init_ch // 2 ** i
            c = init_ch // 2 ** (i + 1)
            self.ups.append(nn.ConvTranspose1d(cin, c, k, u, padding=(k - u) // 2))
            if i + 1 < len(ups):
                s = int(np.prod(ups[i + 1:]))
                self.noise_convs.append(nn.Conv1d(1, c, kernel_size=s * 2, stride=s, padding=s // 2))
            else:
                self.noise_convs.append(nn.Conv1d(1, c, kernel_size=1))
            for rk, rd in zip(rks, rds):
                self.resblocks.append(_ResBlock1(c, rk, rd))
        self.conv_post = nn.Conv1d(c, 1, 7, 1, padding=3, bias=False)

    def forward(self, z, source, g):
        # source (1, 1, S): sine * voiced + noise, made by the app; l_linear + tanh = RVC's SourceModuleHnNSF merge
        har = torch.tanh(source * self.l_linear.weight[0, 0] + self.l_linear.bias[0])
        x = self.conv_pre(z) + (self.gc if hasattr(self, "gc") else self.cond(g))
        for i in range(len(self.ups)):
            x = self.ups[i](F.leaky_relu(x, LRELU)) + self.noise_convs[i](har)
            xs = self.resblocks[i * self.nk](x)
            for j in range(1, self.nk):
                xs = xs + self.resblocks[i * self.nk + j](x)
            x = xs / self.nk
        return torch.tanh(self.conv_post(F.leaky_relu(x)))  # default slope 0.01 here, as in RVC


class RVCGenerator(nn.Module):
    """features (1, T/2, 768), pitch (1, T) int coarse 1..255, source (1, 1, DEC*upp), noise (1, 192, DEC+24) N(0,1)
    -> audio (1, DEC*upp). The flow runs on the last DEC+24 frames, the decoder on the last DEC frames."""

    def __init__(self, p, sid=0, dec_frames=27, flow_margin=24):
        super().__init__()
        self.upp = int(np.prod(p["upsample_rates"]))
        self.sr = int(p["sr"])
        self.dec_frames = dec_frames
        self.flow_margin = flow_margin
        self.enc_p = _TextEncoder(p["hidden_channels"], p["filter_channels"], p["n_heads"], p["n_layers"], p["kernel_size"])
        self.flows = nn.ModuleList([_Coupling(p["inter_channels"], p["hidden_channels"], p["gin_channels"]) for _ in range(4)])
        self.dec = _NSFDecoder(p["upsample_rates"], p["upsample_kernel_sizes"], p["upsample_initial_channel"],
                               tuple(p["resblock_kernel_sizes"]), tuple(tuple(d) for d in p["resblock_dilation_sizes"]), p["gin_channels"])
        self.register_buffer("g", torch.zeros(1, p["gin_channels"], 1))
        self.sid = sid
        self.noise_scale = 0.66666

    def forward(self, features, pitch, source, noise):
        st = self.enc_p(features, pitch)
        T = st.shape[2]
        nf = self.dec_frames + self.flow_margin
        st = st[:, :, T - nf:]
        c = st.shape[1] // 2
        m, logs = st[:, :c], st[:, c:]
        z = m + torch.exp(logs) * noise * self.noise_scale
        for f in reversed(self.flows):  # RVC: flows = [C0, Flip, C1, Flip, ...]; reversed -> Flip, C3, Flip, C2 ...
            z = torch.flip(z, [1])
            z = f.reverse(z, self.g)
        z = z[:, :, self.flow_margin:]
        return self.dec(z, source, self.g).squeeze(1)

    def load_rvc(self, sd):
        sd = fold_weight_norm(sd)
        own = {}
        for k, v in sd.items():
            if k.startswith("enc_q.") or k.startswith("dec.m_source.l_sin_gen"):
                continue
            if k.startswith("enc_p.encoder."):
                k = "enc_p." + k[len("enc_p.encoder."):]
            elif k.startswith("flow.flows."):
                i = int(k.split(".")[2])
                if i % 2:
                    raise Refused("unusual flow layout in the voice file (%s)" % k)  # odd entries are Flip (no weights)
                k = "flows.%d.%s" % (i // 2, ".".join(k.split(".")[3:]))
            elif k.startswith("dec.m_source.l_linear."):
                k = "dec.l_linear." + k.split(".")[-1]
            elif k == "emb_g.weight":
                self.g.copy_(v[self.sid].view(1, -1, 1))
                continue
            own[k] = v
        missing, unexpected = self.load_state_dict(own, strict=False)
        missing = [m for m in missing if m != "g"]
        if missing or unexpected:
            raise Refused("the voice file's parts don't match RVC v2 (missing %s, unexpected %s)" % (missing[:3], unexpected[:3]))
        self.bake_speaker()
        return self

    @torch.no_grad()
    def bake_speaker(self):
        """The speaker is fixed, so every cond(g) is a constant: store it and drop the 1x1 convs (smaller model; the
        8-bit quantiser never sees cond_layer weights)."""
        for f in self.flows:
            f.enc.register_buffer("gc", f.enc.cond_layer(self.g))
            del f.enc.cond_layer
        self.dec.register_buffer("gc", self.dec.cond(self.g))
        del self.dec.cond


class AheadGenerator(nn.Module):
    """The look-ahead shape (Swoopy 3.1): features (1, T/2, 768), pitch (1, T), source (1, 1, DEC*upp),
    noise (1, 192, T), pick (DEC) consecutive window frame numbers (oldest = 0) -> audio (1, DEC*upp) of the picked
    frames. The text encoder and the flow run over the whole window (cheap), the decoder only on the picked frames, so
    the app chooses per piece how far from the newest end its sound comes (the look-ahead) with one file."""

    def __init__(self, g):
        super().__init__()
        self.g = g

    def forward(self, features, pitch, source, noise, pick):
        g = self.g
        st = g.enc_p(features, pitch)
        c = st.shape[1] // 2
        z = st[:, :c] + torch.exp(st[:, c:]) * noise * g.noise_scale
        for f in reversed(g.flows):
            z = torch.flip(z, [1])
            z = f.reverse(z, g.g)
        return g.dec(torch.index_select(z, 2, pick), source, g.g).squeeze(1)


# ------------------------------------------------------------------------------------------- Core ML

def quantize(mlmodel):
    """8-bit weights with a scale and zero point per output channel (the symmetric mode crashes Core ML's GPU path on
    macOS 26). Weights with a slice (along any axis) that is all zero or nearly flat stay 16-bit: that slice's scale
    would be 0 in 16 bits (community voices often have a few near-dead channels), which breaks the 8-bit values."""
    import coremltools.optimize.coreml as cto
    skip = {}
    for fn in mlmodel._mil_program.functions.values():
        for op in fn.find_ops(op_type="const"):
            v = op.outputs[0].val
            if isinstance(v, np.ndarray) and v.size >= 2048 and v.ndim >= 2 and v.dtype.kind == "f":
                for ax in range(v.ndim):
                    s = np.moveaxis(v, ax, 0).reshape(v.shape[ax], -1).astype(np.float32)
                    if ((s.max(1) - s.min(1)) < 3e-5).any():
                        skip[op.name] = None
                        break
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear", dtype="int8",
                                                                           granularity="per_channel", weight_threshold=2048),
                                 op_name_configs=skip)
    return cto.linear_quantize_weights(mlmodel, config=cfg)


def example_inputs(g, L, seed=0):
    r = np.random.default_rng(seed)
    T, DEC, FLOW = L["T"], L["DEC"], L["FLOW"]
    feats = torch.from_numpy(r.standard_normal((1, T // 2, 768)).astype(np.float32) * 0.3)
    pitch = torch.from_numpy(r.integers(1, 200, (1, T)).astype(np.int64))
    src = torch.from_numpy((0.1 * np.sin(np.arange(DEC * g.upp) * 2 * np.pi * 200 / g.sr)).astype(np.float32)[None, None])
    noise = torch.from_numpy(r.standard_normal((1, 192, FLOW)).astype(np.float32))
    if L["A"]:
        return feats, pitch, src, noise, torch.arange(T - DEC, T, dtype=torch.int64)
    return feats, pitch, src, noise


def check_inputs(g, L, seed=1):
    """Speech-like inputs for the check: slowly changing features and a steady pitch (random features make a chaotic,
    quiet sound that no 16-bit copy follows closely). Look-ahead shape: the frames for 150 ms of look-ahead (the
    app's default)."""
    r = np.random.default_rng(seed)
    T, DEC, FLOW = L["T"], L["DEC"], L["FLOW"]
    feats = np.cumsum(r.standard_normal((1, T // 2, 768)).astype(np.float32) * 0.05, axis=1)
    pitch = np.full((1, T), 60, np.int64)  # coarse bin 60 = about 180 Hz
    src = (0.1 * np.sin(np.arange(DEC * g.upp) * 2 * np.pi * 180 / g.sr)).astype(np.float32)[None, None]
    noise = r.standard_normal((1, 192, FLOW)).astype(np.float32)
    out = [torch.from_numpy(feats), torch.from_numpy(pitch), torch.from_numpy(src), torch.from_numpy(noise)]
    if L["A"]:
        la = min(15, L["A"])
        out.append(torch.arange(T - DEC - la, T - la, dtype=torch.int64))
    return tuple(out)


def convert(g, L, work, compiled_dst):
    """Traces, converts, quantises and compiles the generator into compiled_dst (.mlmodelc). Returns the check's SNR."""
    import coremltools as ct
    model = AheadGenerator(g).eval() if L["A"] else g
    ex = example_inputs(g, L)
    check = check_inputs(g, L)
    with torch.no_grad():
        traced = torch.jit.trace(model, ex)
        reference = model(*check).numpy()
    T, DEC, FLOW = L["T"], L["DEC"], L["FLOW"]
    inputs = [ct.TensorType(name="features", shape=(1, T // 2, 768), dtype=np.float32),
              ct.TensorType(name="pitch", shape=(1, T), dtype=np.int32),
              ct.TensorType(name="source", shape=(1, 1, DEC * g.upp), dtype=np.float32),
              ct.TensorType(name="noise", shape=(1, 192, FLOW), dtype=np.float32)]
    if L["A"]:
        inputs.append(ct.TensorType(name="pick", shape=(DEC,), dtype=np.int32))
    ml = ct.convert(traced, inputs=inputs,
                    outputs=[ct.TensorType(name="audio", dtype=np.float32)],
                    minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT16)
    ml = quantize(ml)
    ml.short_description = "RVC v2 voice for Swoopy, %d Hz, hop %d ms: T %d, DEC %d, FLOW %d%s" % (
        g.sr, L["H"] * 10, T, DEC, FLOW, ", look-ahead up to %d ms" % (L["A"] * 10) if L["A"] else "")
    meta = {"rate": str(g.sr), "upp": str(g.upp), "window_frames": str(T), "dec_frames": str(DEC),
            "flow_frames": str(FLOW), "hop_ms": str(L["H"] * 10), "context_ms": str(L["C"] * 10),
            "sid": "0", "xfade_ms": str(L["X"] * 10), "sola_ms": str(L["S"] * 10), "margin_ms": str(L["M"] * 10)}
    if L["A"]:
        meta.update({"right_ms": str(L["R"] * 10), "max_ahead_ms": str(L["A"] * 10), "pick_frames": str(DEC), "shape": "ahead1"})
    ml.user_defined_metadata.update(meta)
    package = os.path.join(work, "voice.mlpackage")
    ml.save(package)
    # Compile the SAVED package (its metadata is in it) and check it against PyTorch on the CPU.
    saved = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_ONLY)
    if os.path.exists(compiled_dst):
        shutil.rmtree(compiled_dst)
    shutil.copytree(saved.get_compiled_model_path(), compiled_dst)
    feats, pitch, src, noise = check[:4]
    feed = {"features": feats.numpy(), "pitch": pitch.numpy().astype(np.int32), "source": src.numpy(), "noise": noise.numpy()}
    if L["A"]:
        feed["pick"] = check[4].numpy().astype(np.int32)
    out = ct.models.CompiledMLModel(compiled_dst, compute_units=ct.ComputeUnit.CPU_ONLY).predict(feed)["audio"]
    out = np.asarray(out, np.float64).ravel()
    ref = np.asarray(reference, np.float64).ravel()
    if not np.all(np.isfinite(out)) or np.abs(out).max() < 1e-5:
        raise Refused("the converted voice makes no sound (the conversion went wrong)")
    snr = 10 * np.log10(np.sum(ref ** 2) / max(np.sum((ref - out) ** 2), 1e-30))
    if snr < 15:
        raise Refused("the converted voice doesn't match the original closely enough (%.0f dB; the conversion went wrong)" % snr)
    return snr


# ------------------------------------------------------------------------------------------- voice.json

# Natural mode settings (and the pitch the AI voice is given) for each answer to "how high is this voice?".
# Keep in step with Sources/VoiceImport.swift (the app writes the same blocks for "Add Voice…").
WOMAN_LTAS = [-7.02, -1.87, 3.77, 3.16, 0.12, 2.69, 3.77, 3.7, 1.45, -0.14, -1.53, -2.74, -4.5, -6.87, -8.83, -11.38,
              -15.21, -18.28, -19.82, -20.19, -22.41]
MAN_LTAS = [3.34, 2.63, 3.37, 4.46, 4.29, 5.59, 6.76, 4.51, 0.53, -1.43, -1.74, -3.05, -5.58, -7.22, -8.4, -10.64, -15,
            -18.27, -20.78, -23.45, -26.41]
PRESETS = {
    "high": dict(targetHz=220, assumedInputHz=120, intonation=1.4, formant=1.21, breathDb=-30, presenceDb=2.5,
                 sibilanceKeep=0, eqAmount=0.5, ltas=WOMAN_LTAS),
    "medium": dict(targetHz=160, assumedInputHz=140, intonation=1.0, formant=1.0, breathDb=-120, presenceDb=0,
                   sibilanceKeep=0, eqAmount=0, ltas=[0.0] * 21),
    "low": dict(targetHz=112, assumedInputHz=205, intonation=0.75, formant=0.85, breathDb=-120, presenceDb=0,
                sibilanceKeep=0, eqAmount=0.5, ltas=MAN_LTAS),
}


def natural_block(pitch):
    """--pitch high|medium|low|HZ -> the natural block (an exact Hz takes the nearest kind's other settings)."""
    p = str(pitch).strip().lower()
    if p in PRESETS:
        return dict(PRESETS[p])
    try:
        hz = float(p.replace("hz", ""))
    except ValueError:
        raise Refused("--pitch: use high, medium, low or a number of Hz (like 210)")
    if not 60 <= hz <= 400:
        raise Refused("--pitch: a voice's pitch is between 60 and 400 Hz (a typical woman about 200, a man about 115)")
    block = dict(PRESETS["high" if hz >= 185 else "low" if hz <= 135 else "medium"])
    block["targetHz"] = round(hz, 1)
    return block


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s[:40] or "voice"


def voices_readme():
    return """Swoopy voices

Each voice is a folder in here (or a .zip of one you add with Add Voice...). Swoopy lists them in the Voice
changer's voice menu.

A voice folder holds:
- voice.json: the voice's name and settings. Swoopy writes it for you when you add a voice.
- a .mlmodelc folder (optional): the AI voice (Macs with Apple silicon). Without one, the voice
  uses the plain voice changer.

To add a voice:
- Downloaded an RVC v2 voice (a .pth file, or a .zip with one inside)? Turn it into a voice folder with the one line
  under "Your own voices" in Swoopy's README (https://github.com/Gromhogg/swoopy#your-own-voices). The new
  voice lands in here.
- Got a voice folder, or a .zip of one? In Swoopy's Voice changer, click the button next to the voice menu and
  choose Add Voice..., or drop the folder in here.

To remove a voice, choose Remove in the same menu, or move its folder to the Trash.

Voices made from a real person or a character are your own responsibility: only use voices you are allowed to use.
"""


# ------------------------------------------------------------------------------------------- main

def find_pth(path, work):
    """The .pth to convert: the file itself, or the biggest .pth inside a .zip."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            members = [m for m in z.infolist() if m.filename.lower().endswith(".pth") and not m.filename.startswith("__MACOSX")
                       and not os.path.basename(m.filename).startswith("._")]
            if not members:
                raise Refused("%s has no .pth voice file inside." % os.path.basename(path))
            m = max(members, key=lambda m: m.file_size)
            if m.file_size > 2_000_000_000:
                raise Refused("the .pth inside %s is too big to be a voice" % os.path.basename(path))
            dst = os.path.join(work, "voice.pth")
            with z.open(m) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)
            return dst, os.path.basename(m.filename)
    if path.lower().endswith(".onnx"):
        raise Refused("%s is an .onnx voice; this converter needs the .pth file of the voice." % os.path.basename(path))
    if path.lower().endswith(".index"):
        raise Refused("%s is the voice's search index; give the converter the voice's .pth file instead." % os.path.basename(path))
    return path, os.path.basename(path)


def main():
    ap = argparse.ArgumentParser(description="Turns an RVC v2 voice (.pth) into a Swoopy voice folder.")
    ap.add_argument("model", help="the voice's .pth file (or a .zip with one inside)")
    ap.add_argument("--name", help="the name shown in Swoopy (default: the file's name)")
    ap.add_argument("--pitch", default="medium", help="how high the voice is: high (most women's voices), medium, low (most men's voices), or Hz")
    ap.add_argument("--voices-dir", default=os.path.expanduser("~/Library/Application Support/Pitch Shift/Voices"))
    ap.add_argument("--app", default=None, help="Swoopy.app to match (default: the one in Applications)")
    ap.add_argument("--ahead-ms", type=int, default=DEFAULT_AHEAD_MS, choices=range(0, 1001, 10), metavar="MS",
                    help="the most look-ahead the voice can use (700, Swoopy 3.1); 0 = the first shape (Swoopy 3.0)")
    a = ap.parse_args()
    path = os.path.abspath(os.path.expanduser(a.model))
    if not os.path.isfile(path):
        raise Refused("can't find %s" % a.model)
    natural = natural_block(a.pitch)
    work = tempfile.mkdtemp(prefix="pitch-shift-voice-")
    try:
        pth, shown = find_pth(path, work)
        sd, params, info = load_checkpoint(pth)
        reader = "contentvec_ahead.mlmodelc" if a.ahead_ms else "contentvec.mlmodelc"
        T, app = app_window_frames(a.app, reader)
        L = window_layout(ahead_ms=a.ahead_ms)
        if T and T != L["T"]:
            L = window_layout(context_ms=(T - L["X"] - L["S"] - L["H"]) * 10 - a.ahead_ms, ahead_ms=a.ahead_ms)
            if L["T"] != T:
                raise Refused("this Swoopy's speech reader has an unexpected size (%d frames)" % T)
        if not T and a.ahead_ms and app_window_frames(a.app, "contentvec.mlmodelc")[0]:
            print("Note: the app on this Mac is older than 3.1. Install the newest Swoopy to use this voice.")
        name = (a.name or os.path.splitext(os.path.basename(path))[0]).strip()[:60] or "Voice"
        base = slug(name)
        os.makedirs(a.voices_dir, exist_ok=True)
        readme = os.path.join(a.voices_dir, "README.txt")
        if not os.path.exists(readme):
            with open(readme, "w") as f:
                f.write(voices_readme())
        vid, n = base, 2
        while os.path.exists(os.path.join(a.voices_dir, vid)) or vid in ("woman", "man"):
            vid, n = "%s-%d" % (base, n), n + 1
        print("Voice file: %s (RVC %s, %d kHz%s)" % (shown, info.get("version", "v2"), params["sr"] // 1000,
                                                    ", %s" % info["info"] if "info" in info else ""))
        print("Converting (about half a minute)...")
        t0 = time.time()
        g = RVCGenerator(params, sid=0, dec_frames=L["DEC"]).load_rvc(sd).eval()
        stage = os.path.join(work, vid)
        os.makedirs(stage)
        model_name = vid + ".mlmodelc"
        snr = convert(g, L, work, os.path.join(stage, model_name))
        manifest = {
            "id": vid,
            "name": name,
            "version": 1,
            "natural": natural,
            "realistic": {"model": model_name, "encoder": reader, "rate": params["sr"], "eqAmount": 0.5},
            "credits": "Converted from %s with Swoopy's voice converter (RVC v2, %d kHz)." % (shown, params["sr"] // 1000),
        }
        with open(os.path.join(stage, "voice.json"), "w") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
        dst = os.path.join(a.voices_dir, vid)
        shutil.move(stage, dst)
        print("Check: the converted voice matches the original (%.0f dB clear of differences; 15 or more is fine). %.0f s." % (snr, time.time() - t0))
        print("Done: \"%s\" is in %s" % (name, dst))
        print("In Swoopy: Voice changer -> pick \"%s\" in the voice menu, and move Faster ↔ More real right of Faster." % name)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except Refused as e:
        print("Can't convert: %s" % e, file=sys.stderr)
        sys.exit(2)
