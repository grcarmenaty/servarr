# 16 — Self-Hosted AI Assistant + Local Voice

An authenticated chat assistant at `http://chat.home.lan`, an
authenticated **OpenAI-compatible API endpoint** for scripts and apps,
and **local speech-to-text + text-to-speech** for a fully offline Home
Assistant voice assistant — all inference on your own hardware, nothing
leaves the house.

Stack (all in one VM):

- [Ollama](https://ollama.com) (MIT) — LLM inference
- [Open WebUI](https://github.com/open-webui/open-webui) — auth, RBAC,
  API keys, the chat UI
- [Whisper](https://github.com/rhasspy/wyoming-faster-whisper) +
  [Piper](https://github.com/rhasspy/wyoming-piper) — voice, spoken to
  Home Assistant over the Wyoming protocol

## CPU-first by design (no dedicated GPU needed)

This runs on **CPU** by default, and that's the recommended shape:

- The VM is a **normal migratable, HA-enrolled guest** like everything
  else — a node dies, it restarts on a survivor. No passthrough, no
  node pinning, no "run this only on the GPU node" caveats.
- A Ryzen-class node runs 7–8B models at a usable **~5–10 tokens/sec** —
  fine for a household assistant, drafting, summarizing, and Home
  Assistant voice. It's about capability, not raw speed.
- 12 GB RAM / 12 vCPU (`cluster.env`) is the starting allocation; bump
  `AI_MEMORY_MB` if you run bigger models.

| Item | Value |
|------|-------|
| VM | `ai` (207), 10.0.0.27, 12 vCPU / 12 GB — **HA-enrolled** |
| Chat | `http://chat.home.lan` (authenticated) |
| API | `http://chat.home.lan/api` (per-user keys) |
| Voice | Whisper `:10300`, Piper `:10301` (Wyoming, for Home Assistant) |
| Models | 300 G thin disk, backup-excluded (re-downloadable) |

## Deploy

```bash
# on ANY node (no GPU, so no special placement):
bash /root/scripts/16-create-ai-vm.sh

# then:
scp -r ai cloud@10.0.0.27:~ && ssh cloud@10.0.0.27
cd ai && sudo bash bootstrap.sh        # CPU path: single pass
# re-login for the docker group, then:
docker compose up -d
docker exec ollama ollama pull qwen3:8b
```

### Authentication setup (the important 5 minutes)

1. `http://chat.home.lan` → **Sign up** — the **first account created
   becomes admin**. Do it immediately after `up -d`.
2. `.env`: `ENABLE_SIGNUP=false` → `docker compose up -d`. Now only you
   create users (*Admin Panel → Users*).
3. Family members: role *user* — chat, not settings.

### Using the API

Each user makes a key under *Settings → Account → API keys*, then:

```bash
curl http://chat.home.lan/api/chat/completions \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"hello"}]}'
```

Anything OpenAI-compatible (scripts, IDE plugins, Karakeep's AI tagging
in docs/10, Home Assistant's conversation agent) points at
`http://chat.home.lan/api` with that key. Ollama's raw authless port
never leaves the VM's loopback.

## Local voice for Home Assistant

Whisper (speech→text) and Piper (text→speech) come up with the stack,
speaking the **Wyoming protocol** on `:10300`/`:10301`. In Home
Assistant (docs/09): *Settings → Devices → Add Integration → Wyoming*,
add `10.0.0.27:10300` (Whisper) and `10.0.0.27:10301` (Piper). Build a
voice assistant under *Settings → Voice assistants* using them plus the
Ollama conversation agent — a **fully local "Hey Jarvis"** with no
cloud, no Google, no Alexa. Language/voice are set in `.env`
(`WHISPER_LANGUAGE`, `PIPER_VOICE` — [voice samples](https://rhasspy.github.io/piper-samples/)).

## Model menu (CPU)

| `ollama pull …` | Speed on CPU | Good for |
|-----------------|--------------|----------|
| `llama3.2:3b` | fast (~15 tok/s) | voice assistant, quick tasks |
| `qwen3:8b` | usable (~5–10 tok/s) | the daily driver |
| `gemma3:12b` | slower | writing, multilingual, when quality matters |
| `nomic-embed-text` | instant | embeddings / RAG |

Bigger than ~14B on CPU gets impractical; that's the ceiling this VM
targets. RAM budget: a model needs roughly its file size resident, so
keep `AI_MEMORY_MB` comfortably above your largest model.

## Appendix — optional GTX 960 acceleration

The GTX 960 (4 GB) on `GPU_NODE` can accelerate **small** models
(≤3–4B fully on-GPU; Ollama splits bigger ones GPU+CPU). It's optional
and comes with a real trade-off: **passthrough pins the VM to that node
and removes its HA.** Only worth it if snappier small-model responses
matter more than failover for this one service.

⚠ These steps are **GPU-node-only** (the node physically holding the
960 — set `GPU_NODE` in `cluster.env`; the scripts enforce it):

```bash
# on GPU_NODE:
lspci -nn | grep -i nvidia                       # e.g. 01:00.0
bash /root/scripts/26-prepare-gpu-passthrough.sh 01:00
# migrate its guests off, reboot GPU_NODE, verify vfio-pci, then:
bash /root/scripts/16-create-ai-vm.sh --gpu 01:00
```

Then bootstrap becomes two-pass (driver install → VM reboot → rerun),
and start with the GPU overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

`20-enable-ha.sh` detects the attached GPU and automatically skips
HA-enrolling this VM. Software honesty: Maxwell (960) is on NVIDIA's
final 580 driver branch / CUDA 12, and the NVIDIA driver is the one
proprietary component in the platform (docs/12) — Nouveau has no CUDA.
Given 4 GB VRAM, the CPU-only default is genuinely the better call for
most people; this appendix is here only because the card exists.

## Alternative: run it as an LXC instead of a VM

The AI service is the one Docker workload worth running as a **native
LXC** (`scripts/17-create-ai-lxc.sh`) instead of the Docker VM
(`scripts/16`). Pick **one** — they share the IP `10.0.0.27` and the
`chat.home.lan` hostname. Comparison:

| | Docker VM (16) | Native LXC (17) |
|--|----------------|-----------------|
| Overhead | full guest kernel (~0.5–1 GB) | near-zero (shares host kernel) |
| Updates | `docker compose pull` (easy) | per-service: `ollama` self-updates, Open WebUI `pip install -U`, voice pip |
| GPU | vfio passthrough — whole card, VM pinned | **bind-mount `/dev/nvidia*`** — card **shared** with host/other CTs, simpler |
| Isolation | stronger (separate kernel) | weaker (shared kernel) — fine for a trusted LAN service |
| HA (no GPU) | yes (opt-in) | yes (opt-in) |

Why the LXC wins specifically for GPU: no exclusive vfio binding, so the
960 stays available to the host (and could also help Jellyfin), and
there's no `26-prepare-gpu-passthrough.sh` / vfio dance. The cost is
hand-maintaining three services instead of one compose file.

**CPU (any node), idempotent:**
```bash
bash /root/scripts/17-create-ai-lxc.sh          # add --ha to enroll now
pct exec 108 -- ollama pull qwen3:8b
```

**With the GTX 960** (⚠ GPU-node-only; **do NOT** run
`26-prepare-gpu-passthrough.sh` — that's the VM/vfio path; the LXC needs
the host to *keep* the driver):
```bash
# on GPU_NODE — the script installs the host NVIDIA driver if missing:
bash /root/scripts/17-create-ai-lxc.sh --gpu 01:00
# → reboot the node once when it asks (loads the module), then re-run the
#   same command; it bind-mounts the device nodes into the container.
pct exec 108 -- nvidia-smi          # confirm the card is visible inside
```

GPU-in-LXC caveat (honest): the container's NVIDIA **userspace libraries
must match the host driver version**. The provisioner installs Debian's
`libnvidia-ml1`, which usually matches; if `nvidia-smi` inside the CT
fails, Ollama simply runs **CPU-only** until the versions line up — it
never breaks, just doesn't accelerate. `20-enable-ha.sh` detects the
bind-mount and skips HA for the GPU case, same as the VM.

Everything else — authentication, the API endpoint, the voice
integration, the model menu — is identical to the VM; only the
packaging differs.

## Day-2

**VM variant:**
- Update: `docker compose pull && docker compose up -d` (models
  unaffected). New models `ollama pull`, remove with `ollama rm`.
- Loaded models: `docker exec ollama ollama ps`.
- Model disk grows: `qm disk resize 207 scsi1 +100G` +
  `xfs_growfs /mnt/models`.

**LXC variant:**
- Update: `pct exec 108 -- bash -c 'curl -fsSL https://ollama.com/install.sh | sh'`
  for Ollama; `pct exec 108 -- /opt/open-webui/venv/bin/pip install -U open-webui &&
  pct exec 108 -- systemctl restart open-webui` for the UI.
- Loaded models: `pct exec 108 -- ollama ps`.
- Model disk is the `/mnt/models` mountpoint — grow it in the CT's
  *Resources* tab.
