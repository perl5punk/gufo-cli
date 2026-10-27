#!/usr/bin/env python3
"""Offline checks for the pure logic of bin/gufo-lemonade (no network, no podman).

    python3 tests/test_bridge.py
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "gufo-lemonade"


def load_module():
    spec = importlib.util.spec_from_loader("gufo_lemonade", loader=None)
    module = importlib.util.module_from_spec(spec)
    # The shipped file has no .py suffix, so compile it explicitly.
    code = compile(BIN.read_text(), str(BIN), "exec")
    module.__dict__["__name__"] = "gufo_lemonade"
    exec(code, module.__dict__)
    return module


gl = load_module()


class TestIds(unittest.TestCase):
    def test_container_name_mirrors_gufo_slugify(self):
        # `gufo` builds: lowercase, non-alnum -> '-', collapse, strip, drop shard
        # suffix, truncate to 48.
        cases = {
            "Qwen3-4B-Q4_K_M": "gufo-qwen3-4b-q4-k-m",
            "Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004": "gufo-qwen3-8-flash-next-ud-q4-k-xl",
            "DeepSeek-R1-Coder 32B": "gufo-deepseek-r1-coder-32b",
        }
        for stem, expected in cases.items():
            self.assertEqual(gl.container_name_for(stem), expected)

    def test_sanitize_id_keeps_lemonade_safe_characters(self):
        self.assertEqual(gl.sanitize_id("Qwen3.8-27B-UD-Q8_K_XL"), "Qwen3.8-27B-UD-Q8_K_XL")
        self.assertEqual(gl.sanitize_id("a b/c:d"), "a-b-c-d")
        self.assertEqual(gl.sanitize_id("***"), "model")


class TestSidecars(unittest.TestCase):
    def test_draft_and_vision_sidecars_are_not_models(self):
        for name in (
            "mtp-Qwen3.8-Flash-Next-shared-Q8_0",
            "Qwen3.8-27B-DFlash2-Q4_K_M",
            "some-model-dspark-v2",
            "Qwen3-VL-mmproj",
        ):
            self.assertTrue(gl.SIDECAR_RE.match(name), f"{name} should be hidden")

    def test_real_models_are_not_hidden(self):
        for name in ("Qwen3-4B-Q4_K_M", "Qwen3.8-27B-UD-Q4_K_M", "gemma-3-27b-it-qat"):
            self.assertFalse(gl.SIDECAR_RE.match(name), f"{name} should be listed")


class TestShards(unittest.TestCase):
    def test_shard_suffix_detection(self):
        m = gl.SHARD_RE.match("Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004")
        self.assertIsNotNone(m)
        self.assertEqual(m.group("base"), "Qwen3.8-Flash-Next-UD-Q4_K_XL")
        self.assertEqual(m.group("idx"), "00001")
        self.assertIsNone(gl.SHARD_RE.match("Qwen3-4B-Q4_K_M"))


class TestCatalog(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "set").mkdir()
        for name, size in (
            ("Alpha-Model-00001-of-00002.gguf", 10),
            ("Alpha-Model-00002-of-00002.gguf", 20),
            ("Beta-Q4_K_M.gguf", 5),
            ("mtp-draft-Q8_0.gguf", 1),
            ("sub-model-mmproj.gguf", 1),
        ):
            (self.root / "set" / name).write_bytes(b"\x00" * size)
        cfg = dict(gl.DEFAULTS)
        cfg["models_dirs"] = [str(self.root)]
        self.catalog = gl.Catalog(cfg)

    def tearDown(self):
        self.tmp.cleanup()

    def test_shards_collapse_to_the_first_shard(self):
        ids = [e.id for e in self.catalog.entries]
        self.assertEqual(ids, ["Alpha-Model", "Beta-Q4_K_M"])
        alpha = self.catalog.by_id["Alpha-Model"]
        self.assertTrue(alpha.path.name.endswith("00001-of-00002.gguf"))
        self.assertEqual(alpha.size, 30)  # whole set (10 + 20), not just shard 1

    def test_sidecars_are_skipped(self):
        ids = [e.id for e in self.catalog.entries]
        self.assertNotIn("mtp-draft-Q8_0", ids)
        self.assertNotIn("sub-model-mmproj", ids)

    def test_lookup_is_forgiving(self):
        for name in ("Beta-Q4_K_M", "gufo.Beta-Q4_K_M", "beta-q4-k-m", "BETA_Q4KM",
                     "gufo-Beta-Q4-K-M", "gufo-beta-q4-k-m"):
            self.assertIsNotNone(self.catalog.get(name), f"{name} should resolve")
        self.assertIsNone(self.catalog.get("nope"))

    def test_same_stem_elsewhere_is_deduplicated(self):
        other = self.root / "other"
        other.mkdir()
        (other / "Beta-Q4_K_M.gguf").write_bytes(b"\x00" * 7)
        self.catalog.scan()
        ids = sorted(e.id for e in self.catalog.entries)
        self.assertEqual(ids, ["Alpha-Model", "Beta-Q4_K_M"])

    def test_ids_that_collide_after_sanitizing_get_disambiguated(self):
        other = self.root / "other"
        other.mkdir()
        # 'X Y' and 'X-Y' both sanitize to 'X-Y'; the second gets its directory.
        (other / "X Y.gguf").write_bytes(b"\x00" * 3)
        (self.root / "set" / "X-Y.gguf").write_bytes(b"\x00" * 4)
        self.catalog.scan()
        ids = sorted(e.id for e in self.catalog.entries)
        self.assertEqual(len(ids), len(set(ids)), ids)
        self.assertIn("X-Y", ids)
        # Whichever file was scanned first keeps the plain id; the other one gets
        # its directory prefix, so both stay addressable.
        self.assertIn("set-X-Y" if "set-X-Y" in ids else "other-X-Y", ids)


class TestContextWindow(unittest.TestCase):
    def entry(self, native):
        entry = gl.ModelEntry("m", "m", Path("/tmp/m.gguf"), 1, {})
        entry.native_ctx = native
        return entry

    def test_cap_is_clipped_to_native(self):
        cfg = {"ctx": 131072, "model_overrides": {}}
        self.assertEqual(self.entry(40960).effective_ctx(cfg), 40960)
        self.assertEqual(self.entry(262144).effective_ctx(cfg), 131072)

    def test_unknown_native_falls_back_to_cap(self):
        cfg = {"ctx": 131072, "model_overrides": {}}
        self.assertEqual(self.entry(0).effective_ctx(cfg), 131072)

    def test_override_wins(self):
        cfg = {"ctx": 131072, "model_overrides": {"m": {"ctx": 8192}}}
        self.assertEqual(self.entry(262144).effective_ctx(cfg), 8192)


class TestEviction(unittest.TestCase):
    def make(self, ids, max_loaded):
        catalog = gl.Catalog.__new__(gl.Catalog)
        catalog.lock = gl.threading.Lock()
        catalog.entries = []
        catalog.by_id = {}
        for i, name in enumerate(ids):
            entry = gl.ModelEntry(name, name, Path(f"/tmp/{name}.gguf"), 1, {})
            entry.running = True
            entry.last_used = i  # oldest first
            catalog.entries.append(entry)
            catalog.by_id[name] = entry
        cfg = dict(gl.DEFAULTS)
        cfg["max_loaded"] = max_loaded
        engine = gl.Engine.__new__(gl.Engine)
        engine.cfg = cfg
        engine.catalog = catalog
        engine.lock = gl.threading.RLock()
        stopped = []
        engine.stop = lambda entry: stopped.append(entry.id)  # type: ignore[assignment]
        return engine, stopped

    def test_lru_eviction_keeps_the_newest(self):
        engine, stopped = self.make(["a", "b", "c"], 1)
        engine.enforce_limits(exclude="c")
        self.assertEqual(stopped, ["a", "b"])

    def test_zero_means_no_limit(self):
        engine, stopped = self.make(["a", "b"], 0)
        engine.enforce_limits(exclude="b")
        self.assertEqual(stopped, [])

    def test_within_limit_stops_nothing(self):
        engine, stopped = self.make(["a"], 2)
        engine.enforce_limits(exclude="a")
        self.assertEqual(stopped, [])


class TestModelCards(unittest.TestCase):
    def test_card_advertises_what_lemonade_needs(self):
        entry = gl.ModelEntry("M-x", "M x", Path("/tmp/M-x.gguf"), 1234, {})
        entry.native_ctx = 32768
        card = entry.to_model_card(dict(gl.DEFAULTS))
        self.assertEqual(card["id"], "M-x")
        self.assertEqual(card["owned_by"], "gufo")
        self.assertEqual(card["context_length"], 32768)
        self.assertIn("chat", card["capabilities"])
        self.assertEqual(card["architecture"]["input_modalities"], ["text"])
        self.assertFalse(card["supports_image_input"])
        self.assertEqual(card["gufo"]["state"], "stopped")

    def test_image_input_override_changes_modalities(self):
        cfg = dict(gl.DEFAULTS)
        cfg["model_overrides"] = {"M-x": {"image_input": True}}
        entry = gl.ModelEntry("M-x", "M x", Path("/tmp/M-x.gguf"), 1234, {})
        card = entry.to_model_card(cfg)
        self.assertEqual(card["architecture"]["input_modalities"], ["text", "image"])
        self.assertEqual(card["architecture"]["modality"], "text+image->text")

    def test_hidden_models_are_not_published(self):
        bridge_cfg = dict(gl.DEFAULTS)
        bridge_cfg["model_overrides"] = {"M-x": {"hidden": True}}
        catalog = gl.Catalog.__new__(gl.Catalog)
        catalog.entries = [gl.ModelEntry("M-x", "M x", Path("/tmp/M-x.gguf"), 1, {}),
                           gl.ModelEntry("M-y", "M y", Path("/tmp/M-y.gguf"), 1, {})]
        engine = gl.Engine.__new__(gl.Engine)
        engine.loaded = lambda: []  # type: ignore[assignment]
        registrar = gl.Registrar.__new__(gl.Registrar)
        registrar.last_ok = 0.0
        registrar.detail = "test"
        bridge = gl.Bridge(bridge_cfg, catalog, engine, registrar)
        self.assertEqual([c["id"] for c in bridge.model_cards()], ["M-y"])


class TestGGUFHeader(unittest.TestCase):
    def test_non_gguf_is_ignored(self):
        with tempfile.NamedTemporaryFile(suffix=".gguf") as fh:
            fh.write(b"NOTA GGUF FILE" * 100)
            fh.flush()
            self.assertEqual(gl.read_gguf_metadata(Path(fh.name)), {})
            self.assertEqual(gl.gguf_context_length({}), 0)

    def test_minimal_header_is_parsed(self):
        import struct

        def kv(key, value):
            out = struct.pack("<Q", len(key)) + key.encode() + struct.pack("<I", 4)
            return out + struct.pack("<I", value)

        blob = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", 0) + struct.pack("<Q", 2)
        blob += kv("general.architecture", 0)  # value content irrelevant for the walk
        blob += kv("llama.context_length", 2048)
        with tempfile.NamedTemporaryFile(suffix=".gguf") as fh:
            fh.write(blob)
            fh.flush()
            meta = gl.read_gguf_metadata(Path(fh.name))
        self.assertEqual(gl.gguf_context_length(meta), 2048)




class TestAuth(unittest.TestCase):
    """The bridge is only as private as its bearer check."""

    def test_valid_bearer_token(self):
        self.assertTrue(gl.bearer_ok("Bearer s3cret", "s3cret"))

    def test_lowercase_scheme_and_whitespace(self):
        self.assertTrue(gl.bearer_ok("bearer  s3cret ", "s3cret"))

    def test_missing_or_wrong_header(self):
        self.assertFalse(gl.bearer_ok(None, "s3cret"))
        self.assertFalse(gl.bearer_ok("", "s3cret"))
        self.assertFalse(gl.bearer_ok("Bearer wrong", "s3cret"))
        self.assertFalse(gl.bearer_ok("s3cret", "s3cret"))  # scheme required

    def test_no_key_configured_means_open(self):
        self.assertTrue(gl.bearer_ok(None, ""))


class TestConfigContract(unittest.TestCase):
    """install.sh and README.md document these keys by name."""

    DOCUMENTED = [
        "host", "port", "provider", "lemond_url", "models_dirs", "max_depth",
        "hide_sidecars", "gufo_bin", "port_start", "ctx", "ram_cache_bytes",
        "speculative", "use_served_names", "container_api_key", "api_key",
        "auto_register", "register_interval_min", "scan_interval_seconds",
        "max_loaded", "evict_before_start", "idle_timeout_min",
        "start_wait_seconds", "retry_backoff_seconds", "autostart", "supports",
        "model_overrides",
    ]

    def test_every_documented_key_has_a_default(self):
        missing = [k for k in self.DOCUMENTED if k not in gl.DEFAULTS]
        self.assertEqual([], missing)

    def test_defaults_are_copies_not_aliases(self):
        cfg = json.loads(json.dumps(gl.DEFAULTS))
        cfg["supports"]["tools"] = False
        self.assertTrue(gl.DEFAULTS["supports"]["tools"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
