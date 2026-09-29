import os
import sys

import pyarrow as pa
import pytest


def find_extension():
    for candidate in [
        os.path.join(os.path.dirname(__file__), "..", "build", "Release"),
        os.path.join(os.path.dirname(__file__), "..", "build"),
        "/var/task",
    ]:
        candidate = os.path.realpath(candidate)
        if not os.path.isdir(candidate):
            continue
        if any(f.startswith("sum_columns") and f.endswith(".so")
               for f in os.listdir(candidate)):
            return candidate
    return None


ext_dir = find_extension()
if ext_dir and ext_dir not in sys.path:
    sys.path.insert(0, ext_dir)

try:
    import sum_columns as ext
    EXT_AVAILABLE = True
except ImportError:
    EXT_AVAILABLE = False

pytestmark = pytest.mark.skipif(not EXT_AVAILABLE,
    reason="sum_columns extension not built — run: conan install . --build=missing && conan build .")


def make_batch(columns: dict) -> pa.RecordBatch:
    arrays = [pa.array(v, type=pa.type_for_alias(a) if isinstance(v[0], (int, float)) else None)
              for a, v in columns.items()]
    return pa.RecordBatch.from_arrays(list(columns.values()), list(columns.keys()))


@pytest.fixture
def price_data():
    close = [100.0 + i * 0.05 + ((-1) ** i) * 0.3 for i in range(252)]
    return pa.RecordBatch.from_arrays(
        [pa.array(close, type=pa.float64())],
        ["close"],
    )
