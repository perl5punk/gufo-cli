# Lemonade backend for Gufo

Run the models managed by [`gufo`](../README.md) inside
[Lemonade Server](https://lemonade-server.ai) — the same model picker, the same
`/v1/chat/completions` endpoint, the same clients — **without rebuilding or
patching Lemonade**.

Install it with one script after Lemonade is installed, then pick
`gufo.<model>` in the Lemonade app.

```
lemonade (127.0.0.1:13305)            gufo-lemonade bridge            gufo
  |                                      (127.0.0.1:13399)             CLI
  |  GET  /v1/models  ----------------> catalog of every GGUF  ---->  gufo models
  |  POST /v1/chat/completions  ------> start container if needed ---> gufo run <gguf>
  |                                     proxy the request to it    --> 127.0.0.1:13400/v1/...
  |  <----------------------- streamed reply, model id rewritten back
```

## TL;DR — can `gufo-cli` be a Lemonade backend?

**Not as a first-class backend.** Lemonade's backends are C++ descriptor +
server pairs that are compiled into `lemond` at build time
(`LEMON_BACKENDS` in `CMakeLists.txt`); there is no plugin, dlopen or
out-of-tree backend API. A real `gufo` recipe means a Lemonade fork and a
rebuilt `lemond` — see [docs/ANALYSIS.md](docs/ANALYSIS.md) for the source-level
evidence and the blueprint if you want that later.

**But it integrates cleanly as a provider.** Lemonade ships a `cloud` recipe
that takes any OpenAI-compatible base URL, discovers models from `<base>/models`
and publishes them to `/v1/models`, the desktop UI and every client. Gufo
already speaks that API — one container per model — with two gaps: containers
only exist once started, and each gets its own auto-assigned port.

So this directory adds the missing piece: **`gufo-lemonade`**, a small
single-file Python bridge (stdlib only) that

- catalogs every `.gguf` in your model directories and advertises all of them
  to Lemonade *before* anything is loaded,
- starts the right container on demand by calling `gufo run`, and
- proxies requests to it, including SSE streaming.

Deployed that way, Gufo models appear natively in the Lemonade UI, work with
`lemonade run`, OpenAI SDK clients, and anything else pointed at the Lemonade
server. The trade-off versus a compiled backend is documented in
[docs/ANALYSIS.md](docs/ANALYSIS.md) — mostly that requests to a cold model pay
a container start, and that the models are labelled `cloud` rather than a
`gufo` recipe.

## Requirements

| | |
|---|---|
| Lemonade Server | **>= 11** (`lemonade cloud install` must exist), running locally |
| Engine host | Linux, rootless **podman**, **jq**, **curl** (i.e. the gufo-cli requirements) |
| Bridge | **python3** >= 3.8, no third-party packages |
| Root | **not required** for the install path below |

Run the installer as the user that owns `~/models` and can start GPU
containers. Do not run it as root — the bridge has to drive *your* rootless
podman.

## Install

```bash
git clone https://github.com/<you>/gufo-cli && cd gufo-cli/lemonade-backend
./install.sh
```

Expected tail of the output:

```
==> Registering 'gufo' as a Lemonade provider
Installing cloud provider: gufo (http://127.0.0.1:13399/v1)
Cloud provider installed: gufo
  models discovered: 4
  ok provider 'gufo' -> http://127.0.0.1:13399/v1

==> Verifying that Lemonade publishes the Gufo models
       gufo.Qwen3-4B-Q4_K_M
       gufo.Qwen3.8-27B-UD-Q4_K_M
       ...
  ok 4 model(s) visible to every Lemonade client
```

`install.sh` is idempotent and does exactly five things:

1. installs `gufo` and `gufo-lemonade` into `~/.local/bin`;
2. writes `~/.config/gufo-lemonade/config.json` (never overwrites an existing one);
3. installs and starts `gufo-lemonade.service` as a **systemd user** service;
4. runs `lemonade cloud install gufo --base-url http://127.0.0.1:13399/v1
   --api-key gufo-local --allow-insecure-http`;
5. checks that `http://127.0.0.1:13305/v1/models` now lists `gufo.*`.

Options: `--provider NAME`, `--port N`, `--host ADDR`, `--api-key KEY`,
`--no-autostart`, `--with-env-key` (also pin the key in `/etc/default/lemond`,
needs root), `--restart-lemond`, `--dry-run`. `--help` documents them.

Why no root: `cloud` requires an API key, and lemond keeps a CLI-supplied key in
memory only. Rather than write to `/etc`, the bridge re-asserts its own
registration on start and whenever Lemonade's model list drifts — so the models
come back by themselves after a lemond restart. `--with-env-key` is there if you
prefer the pinned `LEMONADE_GUFO_API_KEY` variant.

## Use it

In the app: open the model picker and choose `gufo.<model>`.

From the CLI, exactly like any other Lemonade model:

```bash
lemonade list | grep gufo            # Downloaded=Yes, recipe cloud
lemonade run gufo.Qwen3.8-Flash-Next-UD-Q4_K_XL   # load + open the chat web UI
lemonade chat gufo.Qwen3.8-Flash-Next-UD-Q4_K_XL  # terminal REPL

curl http://127.0.0.1:13305/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gufo.Qwen3.8-Flash-Next-UD-Q4_K_M",
       "messages":[{"role":"user","content":"hello"}],"stream":true}'
```

`lemonade load` / `unload` / `pin` are no-ops for a cloud provider — Lemonade's
cloud server only records the model as loaded and returns instantly. The bridge
owns the real container lifecycle.

Because a first request may have to start a container (minutes for a 100 GB
model), warm models up deliberately:

```bash
gufo-lemonade load Qwen3.8-Flash-Next-UD-Q4_K_XL   # start now, block until ready
gufo-lemonade status                               # bridge + Lemonade view
gufo-lemonade models                               # catalog and load state
```

If a request arrives while a model is loading, the reply is an explicit
`503: 'X' is still loading in container gufo-x; retry in a minute` instead of a
silent timeout. The load keeps running in the background — ask again and it
answers. Keep `start_wait_seconds` below Lemonade's own cloud timeout so this
message is what reaches the client.

## Bridge CLI

```
gufo-lemonade serve              run the bridge (what systemd runs)
gufo-lemonade models             GGUF catalog + load state
gufo-lemonade status             bridge health, loaded models, what Lemonade publishes
gufo-lemonade load MODEL         start a container now (warm it up)
gufo-lemonade unload MODEL|all   stop a container
gufo-lemonade scan               rescan the directories and re-publish in Lemonade
gufo-lemonade refresh            re-register the provider (forces Lemonade discovery)
gufo-lemonade doctor             prerequisite checks (podman, lemond, provider, GPU)
gufo-lemonade config [--force]   write the default config file
```

Admin endpoints on the bridge port, for scripts: `GET /health`,
`GET /gufo/status`, `POST /gufo/load {"model":"...","force":true}`,
`POST /gufo/unload {"model":"all"}`, `POST /gufo/scan`.

Everything except `/health` requires `Authorization: Bearer <api_key>` — the same
key Lemonade was given at install time, so the bridge is not an open local
endpoint (relevant if you ever point it at a tailnet interface).

## Configuration

`~/.config/gufo-lemonade/config.json` — JSON, no restart needed except where
noted (a restart is always safe: `systemctl --user restart gufo-lemonade`).

| Key | Default | Meaning |
|---|---|---|
| `host`, `port` | `127.0.0.1`, `13399` | bridge endpoint Lemonade talks to |
| `provider` | `gufo` | Lemonade namespace: models become `gufo.<id>` |
| `lemond_url` | `http://127.0.0.1:13305` | where to register / verify |
| `models_dirs` | `~/models`, `~/.local/share/gufo/models` | scanned for `**/*.gguf` |
| `max_depth` | `4` | how deep to look inside those directories |
| `hide_sidecars` | `true` | keep `mtp-*`, `*dflash2*`, `*dspark*`, `*mmproj*` out of the picker (they are still used automatically as drafts) |
| `gufo_bin` | `gufo` | CLI used to start/stop containers |
| `port_start` | `13400` | first host port offered to containers |
| `ctx` | `131072` | context cap, clipped to each model's native window |
| `ram_cache_bytes` | `4294967296` | passed to `gufo run --ram-cache` |
| `speculative` | `auto` | `auto`/`off`/`mtp`/`dflash2`/`dspark` |
| `use_served_names` | `true` | serve each container under the published id (`gufo run --served-name`), not the GGUF's internal name |
| `container_api_key` | `""` | optional bearer key required *inside* containers |
| `api_key` | `gufo-local` | required bearer key on the bridge (except `/health`); Gufo never sees it |
| `auto_register` | `true` | keep the Lemonade provider registration alive |
| `register_interval_min` | `15` | periodic re-registration / discovery |
| `scan_interval_seconds` | `60` | rescan `models_dirs`, publish additions and removals |
| `max_loaded` | `1` | containers kept resident; `0` = unlimited, `1` = one model at a time (LRU) |
| `evict_before_start` | `true` | free memory *before* launching, so the next model can allocate |
| `idle_timeout_min` | `0` | evict after this much idle time; `0` = never |
| `start_wait_seconds` | `180` | how long a request waits for a cold model before answering 503 |
| `retry_backoff_seconds` | `60` | don't re-attempt a model that just failed to load |
| `autostart` | `[]` | model ids to warm up when the bridge starts |
| `supports` | tools+reasoning on, image off | capability labels advertised to Lemonade |
| `model_overrides` | `{}` | per id: `ctx`, `title`, `hidden`, `tools`, `reasoning`, `image_input` |

Example — keep two models resident, warm one at boot, hide a scratch file, and
mark a vision model:

```json
{
  "max_loaded": 2,
  "idle_timeout_min": 45,
  "autostart": ["Qwen3.8-27B-UD-Q4_K_M"],
  "model_overrides": {
    "Qwen3.8-Flash-Next-UD-Q4_K_XL": {"ctx": 262144},
    "scratch-export": {"hidden": true},
    "Qwen3-VL-30B-Q4_K_M": {"image_input": true}
  }
}
```

Model ids come from the file name (`Qwen3.8-27B-UD-Q8_K_XL.gguf` →
`gufo.Qwen3.8-27B-UD-Q8_K_XL`), stable across restarts. Sharded sets
(`...-00001-of-00004.gguf`) collapse into one model whose size is the whole set.
Draft/vision sidecars are not listed as models.

## Memory behaviour, in plain terms

Strix Halo has unified memory, and these checkpoints are 16–111 GB. With
`max_loaded: 1` the bridge evicts the least recently used model **before**
starting another, so the next one has room to allocate; containers you started
yourself with `gufo run` are adopted and respected as long as they run.
Set `max_loaded: 0` (plus a big `ram_cache_bytes` policy you trust) if you have
the memory for several engines at once, or `idle_timeout_min` to release a model
you stopped using.

## Uninstall

```bash
./uninstall.sh              # unregister the provider, remove the service
./uninstall.sh --purge      # also remove ~/.local/bin/{gufo,gufo-lemonade} + config
./uninstall.sh --stop-models --purge
```

`gufo` itself keeps working afterwards — the Lemonade bridge is additive.

## Verified on

Fedora 44, Lemonade Server 11.9.0 (RPM, `lemond.service` as user `lemonade`,
`127.0.0.1:13305`), podman rootless, Strix Halo (Ryzen AI Max+ 395, gfx1151),
`gufo-runtime:0.12.0`. Checks performed:

- `gufo.*` models published in `GET /v1/models` with `recipe: cloud`,
  `lemonade list` reporting them as downloaded, and shown in the Lemonade app's
  picker; `lemonade load gufo.<model>` succeeds;
- non-streaming chat through Lemonade → bridge → container: correct reply, reply
  `model` rewritten to the published id (1.9 s on an already-loaded model);
- API key enforcement: no key / wrong key → `401`, `/health` open, correct key
  → `200`, verified from both `curl` and Lemonade;
- streaming chat through the same path: SSE chunks delivered incrementally
  (230 chunks observed in one reply, reasoning tokens intact);
- a container started by hand with `gufo run` adopted by the bridge (no restart),
  including after `systemctl --user restart gufo-lemonade` — the bridge comes
  back, re-adopts the container and re-registers the provider on its own;
- on-demand start through the bridge, end to end (correct `gufo run
  ... --served-name` invocation, port allocation, readiness probe, `model`
  rewrite, reply) against a stand-in engine, and against the real engine up to
  the point where the runtime itself refuses a GGUF — which surfaces as a clean
  502 carrying the container's own error message;
- adding a GGUF published it automatically within ~25 s; deleting it removed it
  from `/v1/models` the same way (registrar rescan);
- `install.sh` run twice (idempotent), `uninstall.sh` cleanup.

## Known limits

- **Cold start latency.** The first request to a stopped model starts a
  container, and Lemonade's `load`/`unload` cannot help (no-ops for cloud).
  Use `gufo-lemonade load` (or `autostart`) when latency matters.
- **`cloud` is labelled experimental** by Lemonade, and models show up under the
  `cloud` recipe rather than a `gufo` recipe. It is the only supported
  out-of-process path today.
- **One provider, one endpoint.** Everything Gufo is published through a single
  provider name; that is exactly why the bridge exists, but it means you cannot
  give two Gufo models two different provider namespaces.
- **Engine arch support.** Gufo builds kernels for Strix Halo (`gfx1151`) and
  for the model families it targets, so a GGUF outside that set is expected to
  fail: `gufo-runtime:0.12.0` loads the Qwen3.8 Flash-Next family and refuses
  others inside the container with `Unexpected Qwen layer kind ... expected
  Gated DeltaNet`. Nothing to fix in the integration — the bridge forwards the
  message verbatim and Lemonade shows it. Check `gufo diagnose` and the runtime
  release notes for the supported set, and keep unsupported GGUFs out of the
  published catalog with `model_overrides: {"<id>": {"hidden": true}}`.
- **Image input is off by default.** Gufo can attach a `--mmproj` sidecar, but
  `gufo run` does not wire it up yet, so the bridge advertises text-only
  models (`supports.image_input`) unless you override a model — do not enable it
  until the sidecar is actually attached.
- The bridge does not touch `~/.pi/agent/models.json`: it always calls
  `gufo run --no-register`, so pi and Lemonade never fight over registrations.
  pi can consume the same models through Lemonade (`local-lemonade` on
  `:13305`); a pi provider registered by `gufo run` instead points straight at a
  container port and goes stale if the bridge evicts that model.

## Contents

| File | |
|---|---|
| `bin/gufo-lemonade` | the bridge + its CLI, one stdlib-only Python file |
| `install.sh` / `uninstall.sh` | one-shot install and clean removal |
| `systemd/gufo-lemonade.service` | user unit template (`@BRIDGE@`, `@PORT@` are substituted) |
| `tests/test_bridge.py` | offline checks: ids, shards, sidecars, eviction, model cards, GGUF header parsing |
| `docs/ANALYSIS.md` | why this shape; the native C++ backend blueprint |
| `docs/TROUBLESHOOTING.md` | observed failures, causes, fixes |
