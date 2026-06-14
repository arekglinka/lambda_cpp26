import pyarrow as pa
import pytest

from conftest import ext


class TestSumColumns:

    def test_int64_sum(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([1, 2, 3, 4, 5], type=pa.int64())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert result["vals"] == 15.0

    def test_double_sum(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([1.5, 2.5, 3.0], type=pa.float64())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert abs(result["vals"] - 7.0) < 1e-9

    def test_float_sum(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([1.0, 2.0, 3.0], type=pa.float32())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert abs(result["vals"] - 6.0) < 1e-6

    def test_int32_sum(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([10, 20, 30], type=pa.int32())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert result["vals"] == 60.0

    def test_negative_values(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([-5, 10, -3, 8], type=pa.int64())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert result["vals"] == 10.0

    def test_nulls_skipped(self):
        arr = pa.array([1, None, 3, None, 5], type=pa.int64())
        batch = pa.RecordBatch.from_arrays([arr], ["vals"])
        result = ext.sum_columns(batch)
        assert result["vals"] == 9.0

    def test_multiple_columns(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([1, 2, 3], type=pa.int64()),
             pa.array([10.0, 20.0, 30.0], type=pa.float64())],
            ["ints", "floats"],
        )
        result = ext.sum_columns(batch)
        assert result["ints"] == 6.0
        assert result["floats"] == 60.0

    def test_single_row(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([42], type=pa.int64())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert result["vals"] == 42.0

    def test_empty_column(self):
        batch = pa.RecordBatch.from_arrays(
            [pa.array([], type=pa.int64())],
            ["vals"],
        )
        result = ext.sum_columns(batch)
        assert result["vals"] == 0.0
