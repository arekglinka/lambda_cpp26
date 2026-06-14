import math

import pyarrow as pa
import pytest

from conftest import ext


class TestPriceOptions:

    def test_returns_all_fields(self, price_data):
        result = ext.price_options(price_data)
        expected_keys = {
            "spot", "volatility", "risk_free_rate", "maturity_days",
            "strike", "call_price", "put_price",
            "call_delta", "put_delta", "gamma", "theta", "vega", "rho",
        }
        assert set(result.keys()) == expected_keys

    def test_spot_is_last_close(self, price_data):
        result = ext.price_options(price_data)
        close_col = price_data.column("close")
        expected_spot = close_col[close_col.length - 1].as_py()
        assert abs(result["spot"] - expected_spot) < 1e-6

    def test_volatility_positive(self, price_data):
        result = ext.price_options(price_data)
        assert result["volatility"] > 0
        assert result["volatility"] < 2.0

    def test_option_prices_positive(self, price_data):
        result = ext.price_options(price_data)
        assert result["call_price"] > 0
        assert result["put_price"] > 0

    def test_atm_strike_equals_spot(self, price_data):
        result = ext.price_options(price_data)
        assert result["strike"] == result["spot"]

    def test_put_call_parity(self, price_data):
        result = ext.price_options(price_data)
        S = result["spot"]
        K = result["strike"]
        r = result["risk_free_rate"]
        T = result["maturity_days"] / 365.0
        C = result["call_price"]
        P = result["put_price"]
        parity = C - P - S + K * math.exp(-r * T)
        assert abs(parity) < 0.01, f"put-call parity violated: {parity}"

    def test_atm_call_delta_near_half(self, price_data):
        result = ext.price_options(price_data)
        assert abs(result["call_delta"] - 0.5) < 0.15

    def test_atm_put_delta_near_neg_half(self, price_data):
        result = ext.price_options(price_data)
        assert abs(result["put_delta"] + 0.5) < 0.15

    def test_delta_put_call_identity(self, price_data):
        result = ext.price_options(price_data)
        assert abs(result["call_delta"] - result["put_delta"] - 1.0) < 0.01

    def test_gamma_positive(self, price_data):
        result = ext.price_options(price_data)
        assert result["gamma"] > 0

    def test_vega_positive(self, price_data):
        result = ext.price_options(price_data)
        assert result["vega"] > 0

    def test_theta_negative(self, price_data):
        result = ext.price_options(price_data)
        assert result["theta"] < 0

    def test_custom_maturity(self, price_data):
        r30 = ext.price_options(price_data, maturity_days=30)
        r90 = ext.price_options(price_data, maturity_days=90)
        assert r90["call_price"] > r30["call_price"]

    def test_custom_rate(self, price_data):
        r_low = ext.price_options(price_data, risk_free_rate=0.01)
        r_high = ext.price_options(price_data, risk_free_rate=0.10)
        assert r_high["call_price"] > r_low["call_price"]
