# 16 — Self-Hosted AI Assistant (GPU tier)

An authenticated chat assistant at `http://chat.home.lan`, plus an
authenticated **OpenAI-compatible API endpoint** for scripts and apps —
all inference local, nothing leaves the house.

Stack: [Ollama](https://ollama.com) (MIT) serving models on the GPU,
fronted by [Open WebUI](https://github.com/open-webui/open-webui)
(multi-user auth, RBAC, API keys). Runs in a dedicated VM with the GPU
passed through.

## The two GPUs, honestly

| Card | VRAM | Reality |
|------|------|---------|
| **Tesla P40** (Pascal) | 24 GB | *The* budget homelab LLM card — runs 14B models comfortably, 30B-class quantized. This is the assistant's GPU. |
| **GTX 960** (Maxwell — there is no "RTX 960") | 2–4 GB | Not an LLM card. Good second lives: NVENC transcoding or a desktop VM (see bottom). |

**P40 physical checklist** (server card — read before buying/installing):

- **No fan.** It expects server chassis airflow — in a desktop case you
  must strap a blower/fan shroud to it (3D-printed + 40–75mm fan is the
  standard mod) or it will thermal-throttle and die early.
- **Power: 8-pin EPS (CPU-style) connector, NOT PCIe 8-pin.** Adapters
  exist; miswiring this kills cards. 250 W draw — check the PSU.
- **BIOS on that node**: enable *Above 4G Decoding* (and *Resizable
  BAR* if offered) or the card won't initialize.
- **No display output** — it's compute-only, which is fine here.

**Software honesty**: Pascal (P40) and Maxwell (960) are end-of-line —
NVIDIA's 580 driver branch is their last, and CUDA 12 the last CUDA.
Everything here works today on Debian 13's packaged driver, and Ollama
still ships Pascal support; expect to pin versions rather than chase
latest, and treat a future used-3090 upgrade (24 GB, modern) as the
eventual successor. Also honest: the NVIDIA driver + CUDA are the one
**proprietary** software component in the whole platform (docs/12) —
Nouveau can't do CUDA, so there is no FOSS path to GPU inference on
NVIDIA hardware.

## Architecture & security model

```
 chat.home.lan (Caddy) ──► Open WebUI :3000   ← login required (bcrypt local accounts)
                              │  /api/*        ← per-user API keys (Bearer)
                              ▼
                           Ollama :11434       ← NO auth → bound to 127.0.0.1 ONLY
                              ▼
                           Tesla P40 (passthrough)
```

- The VM is **pinned to the GPU node** (PCI passthrough blocks
  migration) → deliberately **not HA-enrolled**. Node dies = assistant
  down until the node returns. Every other service keeps its HA story.
- Remote use: through WireGuard, like everything else. The endpoint is
  never port-forwarded.

## Deploy

⚠ **Location matters in this doc more than anywhere else in the repo.**
Unlike every other VM (creatable from any node), the GPU steps are tied
to one physical machine. First, declare which node holds the P40 in
`scripts/cluster.env`:

```bash
# on each node, find the card:
lspci -nn | grep -i nvidia
# then in scripts/cluster.env:
GPU_NODE="node3"        # ← the node where the P40 actually sits
```

Where each step runs — the scripts also enforce this (16 refuses on the
wrong node; 26 asks):

| Step | Runs on | Why there |
|------|---------|-----------|
| 1. BIOS: Above 4G Decoding | **GPU node** (physical console) | board setting of the machine holding the card |
| 2. `26-prepare-gpu-passthrough.sh` + reboot | **GPU node only** | binds *that node's* PCI device to vfio-pci |
| 3. `16-create-ai-vm.sh` | **GPU node only** | `hostpci` passthrough only works where the device is |
| 4. `ai/bootstrap.sh` (×2) + `docker compose` | **inside the AI VM** (10.0.0.27) | guest-side driver + stack |
| 5. Account setup | any browser | it's just the web UI |

Everything below repeats these locations inline.

### 1. Host prep — ⚠ GPU node only, once

On the **GPU node's** BIOS: *Above 4G Decoding* on. Then, SSH **to the
GPU node** (`ssh root@<GPU node>` — not node1 unless the card is there):

```bash
lspci -nn | grep -i nvidia                      # note the address, e.g. 01:00.0
bash /root/scripts/26-prepare-gpu-passthrough.sh 01:00
# migrate guests off THIS node (docs/06), reboot THIS node, then verify:
lspci -nnks 01:00                               # Kernel driver in use: vfio-pci
```

The reboot is of the **GPU node** — HA moves its guests to the other
two meanwhile.

### 2. Create the VM — ⚠ GPU node only

Still on the **GPU node** (the script exits with an error on any other
node):

```bash
bash /root/scripts/16-create-ai-vm.sh 01:00
```

(q35 + OVMF + the GPU as `hostpci0`, ballooning off, 300 G model disk
excluded from backups — models re-download.)

### 3. Bootstrap — inside the AI VM (two passes; driver needs a reboot)

These run **in the VM** (10.0.0.27), not on any node — the `ssh` target
changes here:

```bash
scp -r ai cloud@10.0.0.27:~ && ssh cloud@10.0.0.27
cd ai && sudo bash bootstrap.sh      # pass 1: NVIDIA driver → sudo reboot
ssh cloud@10.0.0.27                  # (only the VM reboots, not the node)
cd ai && sudo bash bootstrap.sh      # pass 2: disk, docker, GPU runtime
# re-login, then:
docker compose up -d
docker exec ollama ollama pull qwen3:14b
```

`nvidia-smi` inside the VM must show the P40 before pass 2 proceeds.

### 4. Authentication setup (the important 5 minutes)

1. Open `http://chat.home.lan` → **Sign up** — the **first account
   created becomes the admin**. Do this immediately after `up -d`.
2. Edit `.env`: `ENABLE_SIGNUP=false` → `docker compose up -d`.
   From now on only you can create users (*Admin Panel → Users*); any
   stray signup attempt lands as "pending" anyway.
3. Family members: create their accounts as role *user* — they get
   chat, not settings.

## Using the endpoint

**Chat**: `http://chat.home.lan` — model picker top-left, chat
histories per user, file upload/RAG built in.

**API** (OpenAI-compatible, authenticated): each user generates a key
under *Settings → Account → API keys*. Then from anywhere on
LAN/WireGuard:

```bash
curl http://chat.home.lan/api/chat/completions \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3:14b", "messages": [{"role": "user", "content": "hello"}]}'
```

Anything that speaks the OpenAI API (scripts, Home Assistant's
conversation integration, IDE plugins) points at
`http://chat.home.lan/api` with that key. The raw Ollama port never
leaves the VM's loopback.

## Model menu for a P40 (24 GB)

| Model (`ollama pull …`) | Fits | Good at |
|------------------------|------|---------|
| `qwen3:14b` | comfortably | the default daily driver |
| `llama3.1:8b` | easily, fast | quick tasks, drafts |
| `gemma3:12b` | comfortably | writing, multilingual |
| `qwen3:32b` (Q4) | tight but works | harder reasoning, slower |
| `nomic-embed-text` | trivial | embeddings for RAG |

Rule of thumb: parameter-count × ~0.6 GB (Q4 quant) + a few GB for
context must fit in 24 GB. Expect ~10–20 tok/s on 14B — P40s are
about capacity, not speed.

## The GTX 960's second life

It's in a *different* node, so it can't help the AI VM. Two options:

- **Desktop/experiment VM** (recommended): run
  `26-prepare-gpu-passthrough.sh` **on the 960's own node** (the script
  will notice it isn't `GPU_NODE` and ask — answering yes is correct
  here), then attach the card to a desktop VM created **on that same
  node** (`qm set <vmid> --hostpci0 0000:XX:00,pcie=1`,
  `--machine q35 --bios ovmf` at creation). Light CUDA, retro gaming,
  a second tiny Ollama (3B models) — its VM is pinned like the AI VM.
- **Jellyfin NVENC**: pass it to the servarr VM instead for hardware
  transcoding. Works (Maxwell NVENC does H.264 + 8-bit HEVC), **but**
  it pins the media VM to that node and removes its HA — docs/08
  already argues direct play makes transcoding rarely matter, so only
  do this if transcoding is actually a daily pain.

## Day-2

- Update: `docker compose pull && docker compose up -d` (models are
  unaffected). New models: `docker exec ollama ollama pull <name>`;
  prune old ones with `ollama rm`.
- VRAM/load check: `nvidia-smi` in the VM; loaded models:
  `docker exec ollama ollama ps`.
- The 300 G model disk grows like every other: `qm disk resize 207
  scsi1 +100G` + `xfs_growfs /mnt/models`.
