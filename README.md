# gufo-cli

A small bash CLI for running local GGUF models through
[Gufo](https://github.com/gufo-org/gufo) — the open-source Strix Halo inference
engine. Each model runs in its own podman container from the official
`gufo-runtime` image, serves an OpenAI-compatible API on `127.0.0.1`, and
(optionally) registers itself in pi's `models.json` so
[pi-webui](https://pi-webui.com) picks it up immediately — no web server
restart needed.

```
$ gufo run qwen3.8-27b-ud-q8
Starting gufo-qwen3-8-27b-ud-q8
  model:  /home/hap/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q8_K_XL.gguf
  spec:   dflash2 (auto): /home/hap/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf
  image:  ghcr.io/gufo-org/toolboxes/gufo-runtime:latest
  port:   127.0.0.1:13306
  Waiting for model load (up to 15 min)...
✔ ready: model id '...' on http://127.0.0.1:13306/v1
✔ registered as provider 'gufo-qwen3-8-27b-ud-q8' in ~/.pi/agent/models.json (backup: .bak)
```

## What it does

- **One container per model** — isolated podman containers, read-only
  `/models` mount, AMD GPU passthrough (`/dev/kfd`, `/dev/dri`) with the right
  group ids, auto-incrementing localhost ports starting at 13306.
- **Model discovery** — point it at a query like `q4-k-m`; it searches
  `~/models` (and `~/.local/share/gufo/models`) case-insensitively, treating
  `_` and `-` as equivalent. Full paths work too.
- **Speculative decoding, automatic** — if a draft sidecar GGUF sits in the
  model's directory, `--speculative auto` (the default) wires it up: MTP
  (`mtp-*.gguf`), DFlash2 (`*dflash2*.gguf`) or DSpark (`*dspark*.gguf`), in
  that order. No sidecar → plain autoregressive.
- **pi-webui integration** — registers a `gufo-<model-slug>` provider
  (OpenAI completions API) in `~/.pi/agent/models.json` with a `.bak` backup on
  every change; unregisters on `stop`.
- **Observability** — `status`, `logs`, and `diagnose` subcommands; the
  container logs report per-request `decode_tps`, `prefill_tps`, TTFT and
  draft acceptance (see [Watching tokens/sec](#watching-tokenssec)).

## Requirements

- Linux with **podman** (rootless is fine)
- **jq**, **curl**, **ss** (iproute2), bash 4+
- An **AMD GPU** (`/dev/kfd` + `/dev/dri/renderD*`) — Gufo is built for the
  Strix Halo / Radeon AI line. Without `/dev/kfd` the container simply starts
  without GPU devices (CPU mode, slow).
- Disk + RAM for the model. Rule of thumb: model file size + context cache.
  The defaults (128 k context, 4 GiB CPU conversation cache) are chosen for
  30 GB-class models on a 128 GB unified-memory machine; see
  [Configuration](#configuration) and [Troubleshooting](#troubleshooting).

## Install

```sh
git clone https://github.com/perl5punk/gufo-cli.git
install -m 755 gufo-cli/gufo ~/.local/bin/gufo     # or: sudo ... /usr/local/bin/gufo

gufo help            # command reference
gufo diagnose        # verify GPU/toolchain inside the runtime image
```

That's the whole install — no daemons, no state of its own. Models are just
GGUF files you already have (e.g. from `hf download`); put them under
`~/models`.

## Quickstart

```sh
gufo models                          # list GGUFs found in the model dirs
gufo run qwen3.8-27b-ud-q8           # start it (registers in pi automatically)
# ... chat in pi-webui or hit the API directly:
curl -s http://127.0.0.1:13306/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"*","messages":[{"role":"user","content":"hi"}]}'
gufo status                          # containers, ports, model ids
gufo stop qwen3.8-27b-ud-q8          # stop + remove (and unregister)
```

`gufo prompt qwen3.8-27b-ud-q8 "say hi" --max-tokens 64` works without
registering anything — one-shot generation straight from the CLI.

Run several models at once (e.g. different quants of the same model):

```sh
gufo run qwen3.8-27b-ud-q4 --name gufo-27b-q4 --port 13310
```

## Commands

| Command | Description |
|---|---|
| `models` | List `.gguf` files in the model dirs (name, size, path) |
| `run <model> [opts]` | Start a model container, wait for load, register in pi |
| `stop <model\|name\|all> [--keep-config]` | Stop + remove container(s); removes the provider unless `--keep-config` |
| `status` | All `gufo-*` containers: state, port, served model id, registration |
| `logs [name] [--no-follow]` | Tail container logs (follows by default) |
| `prompt <model> "text" [--max-tokens N]` | One-shot generation (no container kept) |
| `gpu` | Check GPU device nodes and container access (udev trap on Ubuntu-family hosts) |
| `refresh [name]` | Re-read the served model id and resync `models.json` (after swapping GGUF files in place) |
| `unregister <model\|name>` | Remove the provider from `models.json` only |
| `diagnose` | Run `gufo diagnose` in the runtime image (GPU/toolchain check) |
| `download <recipe>` | Fetch a verified model + speculative sidecar from Hugging Face (`flash-next`, `dflash2-27b`) |

### `run` options

| Option | Default | Meaning |
|---|---|---|
| `--port N` | first free from 13306 | Host port (loopback only) |
| `--name slug` | `gufo-<model-slug>` | Container name |
| `--ctx N` | 131072 | Context tokens (`gufo serve -c`) |
| `--max N` | 32768 | `maxTokens` advertised to pi |
| `--ram-cache N` | 4 GiB (bytes) | CPU conversation-cache budget |
| `--speculative MODE [GGUF]` | `auto` | Draft backend: `auto`, `off`, `mtp`, `dflash2`, `dspark`; optional explicit sidecar path |
| `--draft-tokens N` | 7 (1–7) | Draft cap per step |
| `--draft-policy POLICY` | engine default | DFlash2 block policy: `fixed` or `adaptive` |
| `--served-name ID` | GGUF `general.name` | Model id exposed by the OpenAI API (use a stable id when another app lists models and forwards requests back to you) |
| `--api-key KEY` | none | Require this bearer key in the container |
| `--image IMG` | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Runtime image |
| `--no-register` | — | Container only, skip `models.json` |
| `--tailscale` | off | Expose the endpoint on your tailnet via `tailscale serve` (see below) |

## GPU device access (`gpu`)

```sh
gufo gpu
```

Checks that the runtime container can actually open `/dev/kfd` and
`/dev/dri/renderD*` — it stats the host nodes and probes read/write access from
*inside* a throwaway container. Rootless podman cannot carry the `render` group
across its user-namespace boundary, so distros that ship these nodes
`0660 root:render` (Ubuntu/Pop!_OS defaults; Fedora ships `0666`) fail every
GPU load with misleading errors despite a healthy host — observed in the wild:
`no ROCm-capable device is detected` and `weight upload staging allocation
failed`. The fix, printed by `gufo gpu` on failure, is a udev rule making the
nodes world-accessible:

```sh
sudo tee /etc/udev/rules.d/99-gpu-access.rules >/dev/null <<'RULES'
KERNEL=="renderD[0-9]*", GROUP="render", MODE="0666"
KERNEL=="kfd", GROUP="render", MODE="0666"
RULES
sudo udevadm control --reload && sudo udevadm trigger
```

`gufo run` performs this check before every start (quiet on success);
`--skip-device-check` or `GUFO_SKIP_DEVICE_CHECK=1` bypasses it.

## Lemonade Server integration

[`lemonade-backend/`](lemonade-backend/README.md) adds **`gufo-lemonade`**, a
local bridge that publishes every GGUF in your model directories to
[Lemonade Server](https://lemonade-server.ai) as the `gufo` provider: the models
appear in the Lemonade UI and `/v1/models`, and the bridge starts the right
container on demand (and frees memory for it) before proxying the request,
streaming included.

```bash
cd lemonade-backend && ./install.sh     # no root, no Lemonade rebuild
gufo-lemonade status
```

It runs as your user with rootless podman and never edits `models.json`, so this
CLI keeps working unchanged. [Why it is built this way](lemonade-backend/docs/ANALYSIS.md)
— Lemonade compiles backends into `lemond`, so a first-class `gufo` recipe would
mean a fork; the doc includes the blueprint. See also
[troubleshooting](lemonade-backend/docs/TROUBLESHOOTING.md).

## Speculative decoding

Gufo supports MTP, DFlash2 and DSpark draft backends. `gufo-cli` makes them
zero-config: drop the matching draft GGUF **next to the target model** and the
default `--speculative auto` finds it (searched up to 3 levels deep in the
model's directory).

Priority in `auto` mode: `mtp-*.gguf` → `*dflash2*.gguf` → `*dspark*.gguf`.

Typical layouts:

```
models/
├── qwen3.8-flash-next/                 # MoE — MTP sidecar
│   ├── UD-Q4_K_XL/
│   │   └── Qwen3.8-Flash-Next-UD-Q4_K_XL-0000{1..4}-of-00004.gguf
│   └── MTP/
│       └── mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf      <- auto-detected
└── Qwen3.8-27B-GGUF/                   # dense — DFlash2 draft
    ├── Qwen3.8-27B-UD-Q8_K_XL.gguf
    └── Qwen3.8-27B-DFlash2-Q4_K_M.gguf                  <- auto-detected
```

Which model supports which backend (and where to get the sidecar) is
documented per-model by the Gufo project:
<https://github.com/gufo-org/gufo/tree/main/docs/models>

Examples:

```sh
gufo run flash-next                    # auto -> --speculative mtp
gufo run q8-k-xl                       # auto -> --speculative dflash2
gufo run my-model --speculative dflash2 /path/to/draft.gguf   # explicit
gufo run my-model --speculative off    # plain autoregressive
```

Measured on a Strix Halo (Strix Point X1), Qwen3.8-27B:

| Setup | Decode | Notes |
|---|---|---|
| Q4_K_M, autoregressive | ~5.6 tps | |
| Q4_K_M + DFlash2 (auto) | **31.1 tps** | 101/115 draft tokens accepted (88%) |

The container's load log confirms the backend:
`podman logs <name> | grep -o 'speculative=[a-z0-9]*'`.

## Downloading a model (`download`)

Rather than hand-writing `hf download` invocations, `gufo download <recipe>`
fetches a known-good model plus its speculative sidecar, verifies every file
byte-for-byte, and lands them where `run --speculative auto` will find them:

```sh
gufo download flash-next    # Qwen3.8-Flash-Next UD-Q4_K_XL + MTP sidecar (~114 GB)
gufo download dflash2-27b   # DFlash2 draft next to the 27B GGUF (~1.1 GB)
```

Each recipe pins a specific repo revision, checks there is enough free disk
before starting, and is resumable — rerun it if a transfer drops. It needs the
[`hf` CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)
(installed and `hf auth login`).

- **`flash-next`** writes shards to `<models-dir>/qwen3.8-flash-next/UD-Q4_K_XL/`
  and the MTP sidecar to `…/MTP/mtp-*.gguf`; `gufo run flash-next --ctx 32768`
  then auto-enables MTP.
- **`dflash2-27b`** drops `Qwen3.8-27B-DFlash2-Q4_K_M.gguf` beside the 27B target
  in `Qwen3.8-27B-GGUF/`; `gufo run <27b>` then auto-enables DFlash2.

Both land in the first entry of `GUFO_MODELS_DIRS` (`~/models` by default), so
they show up in `gufo models` immediately.

## Exposing an endpoint on your tailnet

`gufo run <model> --tailscale` publishes the OpenAI endpoint through
[Tailscale Serve](https://tailscale.com/kb/1312/serve) instead of leaving it
loopback-only:

```
✔ ready: model id '...' on http://127.0.0.1:13306/v1
✔ tailnet: https://rogtablet.tail47c42a.ts.net:13306/v1 — tailnet-only, no auth (gate with ACLs); removed on gufo stop
```

Peers on your tailnet then use `https://<node>.<tailnet>.ts.net:<port>/v1` as
the base URL — TLS via the node's auto-provisioned `ts.net` certificate, and
the endpoint stays invisible outside the tailnet. `gufo status` shows the
tailnet URL when a model is exposed, and `gufo stop` removes the serve entry
automatically.

**One-time setup** — changing serve config requires operator rights (the
container and registration work without this; only the tailnet exposure needs
it):

```sh
sudo tailscale set --operator=$USER   # once, as your normal user
```

Notes:

- The endpoint itself has **no authentication** — Tailscale's boundary is your
  ACLs. Restrict which tailnet users/devices may reach the port if your tailnet
  is shared.
- Each exposed model gets its own port (the container's port), so multiple
  models can be exposed simultaneously.
- Exposed ports work like any other `serve` entry: they persist in the
  tailscale daemon until removed (`gufo stop`, or
  `sudo tailscale serve --https=<port> off`).

## Watching tokens/sec

Gufo logs one `event=completed` line per request with full stats — no extra
tooling needed:

```
request=r3 event=completed ... prompt_tokens=15522 prefill_tokens=15522
generated_tokens=135 ttft_ms=77219.5 prefill_tps=201.5 decode_tps=5.6
batch_width=1 draft_accepted=101 draft_proposed=115 draft_rounds=18
```

Live watch:

```sh
gufo logs <name> | grep --line-buffered 'event=completed' \
  | grep --line-buffered -oE 'request=[a-z0-9]+|ttft_ms=[0-9.]+|prefill_tps=[0-9.]+|decode_tps=[0-9.]+|draft_accepted=[0-9]+ draft_proposed=[0-9]+'
```

## Configuration

All knobs are environment variables (with in-script defaults):

| Variable | Default | Meaning |
|---|---|---|
| `GUFO_IMAGE` | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Runtime image |
| `GUFO_PORT_START` | `13306` | First port tried (auto-increments if busy) |
| `GUFO_MODELS_DIR` | `$HOME/models` | Primary models dir |
| `PI_MODELS_JSON` | `$HOME/.pi/agent/models.json` | pi provider config (skipped if absent) |

Secondary models dir is always `$HOME/.local/share/gufo/models`.
Load timeout is 900 s (`WAIT_TIMEOUT` in the script).

`models.json` is only touched when it exists and `jq` is available; `run`
backs it up to `models.json.bak` before every edit, and `--no-register`
skips it entirely — so the CLI is safe to use without pi installed.

## Troubleshooting

- **`model failed to load` / container exited during load** — check
  `gufo logs <name>`: the last 15 lines are shown on failure. Common causes:
  not enough RAM (see below), or a corrupt/incomplete GGUF.
- **OOM while loading large models** — lower `--ram-cache` (it's a *minimum
  budget* on the CPU side, on top of the model file) and/or `--ctx`. Gufo's
  own default (half of free RAM, up to 32 GiB) will OOM smaller memory pools;
  that's why the default here is 4 GiB.
- **Port conflicts** — the script auto-increments from `GUFO_PORT_START`;
  use `--port` to pin one. `gufo status` shows what's live.
- **Model not found** — `gufo models` shows exactly what the script sees;
  files must be `*.gguf` within 4 levels of a models dir.
- **Two quants, one name** — use `--name` + `--port` for the second instance.
- **Swapped the GGUF file in place?** — restart the container, then
  `gufo refresh` to sync the new served model id into `models.json`.

## License

[Mozilla Public License 2.0](LICENSE)
