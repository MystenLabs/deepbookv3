"""
Oracle Feed Storage Demo

A Python implementation demonstrating feed storage, identification, indexing,
updates, permission bitmasks, and extensible calculator routing with chained
dependencies for financial data oracles.
"""

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import IntEnum
from hashlib import sha256
from math import exp, log, sqrt
from typing import Any, Literal, Protocol

import httpx
from scipy.stats import norm

# =============================================================================
# Constants
# =============================================================================

DAYS_IN_YEAR = 365.0

API_BASE_URL = "https://prod-data.blockscholes.com"
API_KEY = "rm16liqFZh1TfzTNOXjRw4yzAFyyZGYg5rLyy2NE"
DOMESTIC_RATE = 0.035


# =============================================================================
# API Client
# =============================================================================


def _api_request(endpoint: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Make a POST request to the BlockScholes API."""
    url = f"{API_BASE_URL}{endpoint}"
    headers = {"X-API-Key": API_KEY, "Content-Type": "application/json"}
    with httpx.Client(timeout=30.0) as client:
        response = client.post(url, json=payload, headers=headers)
        response.raise_for_status()
        return response.json()


def fetch_svi_params(expiry_iso: str) -> dict[str, float]:
    """Fetch SVI model parameters for a given expiry.

    Returns dict with keys: a, b, rho, m, sigma, timestamp
    """
    payload = {
        "exchange": "composite",
        "base_asset": "BTC",
        "model": "SVI",
        "expiry": expiry_iso,
        "start": "LATEST",
        "end": "LATEST",
        "frequency": "1m",
        "options": {
            "format": {
                "timestamp": "s",
                "hexify": False,
                "decimals": 5,
            }
        },
    }
    data = _api_request("/api/v1/modelparams", payload)
    row = data["data"][0]
    return {
        "timestamp": row["timestamp"],
        "a": row["alpha"],
        "b": row["beta"],
        "rho": row["rho"],
        "m": row["m"],
        "sigma": row["sigma"],
    }


def fetch_forward_price(expiry_iso: str) -> dict[str, float]:
    """Fetch forward (futures mark) price for a given expiry.

    Returns dict with keys: timestamp, price
    """
    payload = {
        "base_asset": "BTC",
        "asset_type": "future",
        "expiry": expiry_iso,
        "start": "LATEST",
        "end": "LATEST",
        "frequency": "1m",
        "options": {
            "format": {
                "timestamp": "s",
                "hexify": False,
                "decimals": 5,
            }
        },
    }
    data = _api_request("/api/v1/price/mark", payload)
    row = data["data"][0]
    return {"timestamp": row["timestamp"], "price": row["v"]}


def fetch_spot_price() -> dict[str, float]:
    """Fetch current BTC spot index price.

    Returns dict with keys: timestamp, price
    """
    payload = {
        "base_asset": "BTC",
        "asset_type": "spot",
        "start": "LATEST",
        "end": "LATEST",
        "frequency": "1m",
        "options": {
            "format": {
                "timestamp": "s",
                "hexify": False,
                "decimals": 5,
            }
        },
    }
    data = _api_request("/api/v1/price/index", payload)
    row = data["data"][0]
    return {"timestamp": row["timestamp"], "price": row["v"]}


# =============================================================================
# Core Data Structures
# =============================================================================
#
# Design: A Feed is uniquely identified by its type (id) plus parameters.
# Parameters are split into:
#   - enumerable: Small integer values with limited range (source, asset type)
#                 Used for permission bitmask validation
#   - other: Dictionary for variable data (expiry, strike, flags)
#
# Interactions:
#   - Feed + FeedParameters form the lookup key in DataStorage
#   - FeedData is the return type containing value + timestamp
#   - FeedType enum defines the available feed categories
# =============================================================================


class FeedType(IntEnum):
    IV = 0
    FORWARD = 1
    SVI_PARAMS = 2
    OPTION_PRICE = 3
    SPOT = 4
    DOMESTIC_RATE = 5


class SVIParam(IntEnum):
    A = 0
    B = 1
    RHO = 2
    M = 3
    SIGMA = 4


@dataclass(frozen=True)
class FeedParameters:
    enumerable: tuple[int, ...] = ()
    other: dict[str, float | int | str | bool] = field(default_factory=dict)


@dataclass(frozen=True)
class Feed:
    id: int
    parameters: FeedParameters = field(default_factory=FeedParameters)


@dataclass
class FeedData:
    value: float
    timestamp: int


# =============================================================================
# Data Storage
# =============================================================================
#
# Design: Primary persistence layer with parallel arrays for values and
# timestamps, plus a mapping from feed keys to 1-based indexes.
#
# Why 1-based indexing? Using 1-based indexes allows index 0 to represent
# "not found", so we can use a plain `int` return type. The alternative would
# be using `Optional[int]` (i.e., `int | None`) which requires explicit None
# checks everywhere. With 1-based indexing, `index == 0` cleanly means "missing".
#
# Key generation: hash(feed_id + version + parameters) ensures:
#   - Same feed with different params -> different keys
#   - Version increment invalidates all existing keys (for reset)
#
# Interactions:
#   - DerivedDataProvider reads from DataStorage for base feed values
#   - External updaters write via add/update methods
#   - PermissionManager validates access before reads
#
# Methods:
#   - add_feed_with_value: Register new feed with initial value
#   - update_data_for_feed: Update existing feed's value
#   - remove_feed: Unregister a feed (keeps data, removes index)
#   - reset_all_data: Clear all and increment version
# =============================================================================


class DataStorage:
    def __init__(self) -> None:
        self._data: list[float] = []
        self._timestamps: list[int] = []
        self._feed_indexes: dict[str, int] = {}  # feed_key -> 1-based index
        self.version: int = 0

    def _get_feed_key(self, feed: Feed) -> str:
        raw = f"{feed.id}:{self.version}:{feed.parameters.enumerable}:{feed.parameters.other}"
        return sha256(raw.encode()).hexdigest()

    def get_latest_feed_data(self, feed: Feed) -> FeedData:
        key = self._get_feed_key(feed)
        index = self._feed_indexes.get(key)
        if index is None or index == 0:
            raise KeyError(f"Feed not found: {feed}")
        idx = index - 1  # Convert to 0-based
        return FeedData(value=self._data[idx], timestamp=self._timestamps[idx])

    def add_feed_with_value(
        self,
        feed: Feed,
        value: float,
        timestamp: int,
        target_index: int | None = None,
    ) -> int:
        key = self._get_feed_key(feed)
        if key in self._feed_indexes:
            raise ValueError(f"Feed already exists: {feed}")

        if target_index is not None and target_index < len(self._data):
            self._data[target_index] = value
            self._timestamps[target_index] = timestamp
            self._feed_indexes[key] = target_index + 1
        else:
            self._data.append(value)
            self._timestamps.append(timestamp)
            self._feed_indexes[key] = len(self._data)  # 1-based

        return self._feed_indexes[key]

    def update_data_for_feed(
        self, feed: Feed, value: float, timestamp: int
    ) -> None:
        key = self._get_feed_key(feed)
        index = self._feed_indexes.get(key)
        if index is None or index == 0:
            raise KeyError(f"Feed not found: {feed}")
        idx = index - 1
        self._data[idx] = value
        self._timestamps[idx] = timestamp

    def remove_feed(self, feed: Feed) -> None:
        key = self._get_feed_key(feed)
        if key not in self._feed_indexes:
            raise KeyError(f"Feed not found: {feed}")
        del self._feed_indexes[key]

    def reset_all_data(self) -> None:
        self._data.clear()
        self._timestamps.clear()
        self._feed_indexes.clear()
        self.version += 1

    def feed_count(self) -> int:
        return len(self._feed_indexes)


# =============================================================================
# Calculator Protocol & Configuration
# =============================================================================
#
# Design: Calculators are stateless computation units that:
#   1. Declare what input feeds they need via get_input_feed_parameters()
#   2. Compute output from those inputs via calculate()
#
# The Protocol (structural typing) allows any class with matching methods
# to be used as a Calculator without explicit inheritance.
#
# CalculatorConfig bundles:
#   - input_feed_ids: Which feed types this calculator needs (e.g., [SPOT, RATE])
#   - handler: The Calculator instance that performs computation
#
# Interactions:
#   - DerivedDataProvider stores CalculatorConfig per output feed type
#   - When a derived feed is requested, the provider:
#     1. Looks up the config by feed ID
#     2. Calls handler.get_input_feed_parameters() to get params for each input
#     3. Fetches input values (possibly recursively for chained calculators)
#     4. Calls handler.calculate() with the collected inputs
# =============================================================================


class Calculator(Protocol):
    def calculate(
        self,
        timestamp: int,
        input_data: list[float],
        parameters: FeedParameters,
    ) -> float: ...

    def get_input_feed_parameters(
        self, parameters: FeedParameters
    ) -> list[FeedParameters]: ...


@dataclass
class CalculatorConfig:
    input_feed_ids: list[int]
    handler: Calculator


# =============================================================================
# Derived Data Provider (Calculator Router)
# =============================================================================
#
# Design: A routing layer that maps output feed types to their calculators
# and orchestrates the computation flow.
#
# Key features:
#   - Calculator registration: Admin adds/removes calculators at runtime
#   - Dependency resolution: Automatically fetches inputs from DataStorage
#   - Chained resolution: If an input is itself derived, recursively computes it
#   - Timestamp propagation: Returns min timestamp of all inputs (staleness)
#
# Resolution flow for OPTION_PRICE(params):
#   1. Lookup config: needs [SPOT, FORWARD, IV, RATE] inputs
#   2. Get input params from handler.get_input_feed_parameters(params)
#   3. For FORWARD: check DataStorage, not found -> recurse (needs SPOT, RATE)
#   4. For IV: check DataStorage, not found -> recurse (needs FORWARD + SVI)
#   5. Collect all input values, call handler.calculate()
#
# Interactions:
#   - Reads base data from DataStorage (injected dependency)
#   - Calculators are registered by admin (add_calculator)
#   - PermissionManager validates access before routing here
# =============================================================================


class DerivedDataProvider:
    def __init__(self, data_storage: DataStorage) -> None:
        self._data_storage = data_storage
        self._calculators: dict[int, CalculatorConfig] = {}

    def add_calculator(
        self,
        output_feed_id: int,
        input_feed_ids: list[int],
        handler: Calculator,
    ) -> None:
        self._calculators[output_feed_id] = CalculatorConfig(
            input_feed_ids=input_feed_ids, handler=handler
        )

    def remove_calculator(self, output_feed_id: int) -> None:
        if output_feed_id not in self._calculators:
            raise ValueError(f"No calculator for feed ID: {output_feed_id}")
        del self._calculators[output_feed_id]

    def get_latest_feed_data(self, feed: Feed) -> FeedData:
        config = self._calculators.get(feed.id)
        if config is None:
            raise ValueError(f"No calculator registered for feed ID: {feed.id}")

        input_params = config.handler.get_input_feed_parameters(feed.parameters)
        if len(input_params) != len(config.input_feed_ids):
            raise ValueError(
                f"Parameter count mismatch: expected {len(config.input_feed_ids)}, "
                f"got {len(input_params)}"
            )

        input_data: list[float] = []
        min_timestamp = 2**31 - 1

        for feed_id, params in zip(
            config.input_feed_ids, input_params, strict=True
        ):
            input_feed = Feed(id=feed_id, parameters=params)
            try:
                feed_data = self._data_storage.get_latest_feed_data(input_feed)
            except KeyError:
                if feed_id in self._calculators:
                    feed_data = self.get_latest_feed_data(input_feed)
                else:
                    raise

            input_data.append(feed_data.value)
            min_timestamp = min(min_timestamp, feed_data.timestamp)

        result = config.handler.calculate(
            min_timestamp, input_data, feed.parameters
        )
        return FeedData(value=result, timestamp=min_timestamp)

    def is_derived(self, feed_id: int) -> bool:
        return feed_id in self._calculators


# =============================================================================
# Option Pricing Helper
# =============================================================================
#
# Design: Computes Black-Scholes option prices and greeks for both vanilla
# and digital options. Returns an OptionPriceResult containing the premium
# and all greeks.
#
# For vanilla options: Standard Black-Scholes formula
# For digital options: Discounted probability of finishing ITM (N(phi * d_m))
#
# Interactions:
#   - Used by OptionPriceCalculator to compute option values
#   - Can be used standalone for risk analysis
# =============================================================================

OptionType = Literal["C", "P"]
OptionStyle = Literal["vanilla", "digital"]


@dataclass
class OptionPriceResult:
    premium: float
    delta: float
    gamma: float
    vega: float
    theta: float
    volga: float
    vanna: float


def get_foreign_rate(
    spot: float, r_d: float, forward: float, t: float
) -> float:
    if t <= 0:
        return r_d
    return r_d - log(forward / spot) / t


def compute_option_price(
    spot: float,
    forward: float,
    strike: float,
    vol: float,
    t: float,
    r_d: float,
    op_type: OptionType,
    style: OptionStyle = "vanilla",
) -> OptionPriceResult:
    if spot <= 0 or forward <= 0 or t <= 0:
        raise ValueError(f"Invalid inputs: {spot=}, {forward=}, {t=}")

    phi = 1 if op_type.upper() == "C" else -1

    if strike <= 0 or vol <= 0:
        raise ValueError(f"Strike and vol must be > 0: {strike=}, {vol=}")

    sqrt_t = sqrt(t)
    r_f = get_foreign_rate(spot, r_d, forward, t)

    d_p = (log(forward / strike) + 0.5 * vol * vol * t) / (vol * sqrt_t)
    d_m = d_p - vol * sqrt_t

    discount_d = exp(-r_d * t)
    discount_f = exp(-r_f * t)

    pdf_d_p: float = float(norm.pdf(d_p))
    pdf_d_m: float = float(norm.pdf(d_m))
    cdf_phi_d_p: float = float(norm.cdf(phi * d_p))
    cdf_phi_d_m: float = float(norm.cdf(phi * d_m))

    if style == "digital":
        # Digital option: pays 1 unit if ITM at expiry
        premium = discount_d * cdf_phi_d_m

        # Digital greeks
        delta = phi * discount_d * pdf_d_m / (spot * vol * sqrt_t)
        gamma = (
            -phi * discount_d * pdf_d_m * d_p / (spot * spot * vol * vol * t)
        )
        vega = (
            -phi * discount_d * pdf_d_m * d_p / (vol * 100)
        )  # per 1 vol point
        theta = (
            r_d * premium
            + phi
            * discount_d
            * pdf_d_m
            * (d_p / (2 * t) + r_d * d_m / (vol * sqrt_t))
        ) / DAYS_IN_YEAR
        volga = phi * discount_d * pdf_d_m * d_p * (d_p * d_m - 1) / (vol * vol)
        vanna = (
            phi
            * discount_d
            * pdf_d_m
            * (d_m * d_p - 1)
            / (spot * vol * vol * sqrt_t)
        )
    else:
        # Vanilla option: standard Black-Scholes
        premium = (
            phi * discount_d * (forward * cdf_phi_d_p - strike * cdf_phi_d_m)
        )
        premium = max(premium, 0.0)

        # Vanilla greeks
        delta = phi * discount_f * cdf_phi_d_p
        gamma = discount_f * pdf_d_p / (spot * vol * sqrt_t)

        theta_1 = discount_f * pdf_d_p * spot * vol / (2 * sqrt_t)
        theta_2 = r_f * spot * discount_f * cdf_phi_d_p
        theta_3 = r_d * strike * discount_d * cdf_phi_d_m
        theta = (-theta_1 + phi * (theta_2 - theta_3)) / DAYS_IN_YEAR

        vega = spot * discount_f * sqrt_t * pdf_d_p / 100  # per 1 vol point
        volga = spot * discount_f * sqrt_t * pdf_d_p * (d_p * d_m / vol)
        vanna = -discount_f * pdf_d_p * d_m / vol

    return OptionPriceResult(
        premium=float(premium),
        delta=float(delta),
        gamma=float(gamma),
        vega=float(vega),
        theta=float(theta),
        volga=float(volga),
        vanna=float(vanna),
    )


# =============================================================================
# Example Calculators
# =============================================================================
#
# Design: Concrete Calculator implementations demonstrating different patterns.
# The `timestamp` parameter represents the current time (Unix seconds), and
# `expiry_timestamp` in parameters specifies the expiry as Unix epoch seconds.
# Time to expiry is computed as: (expiry_timestamp - timestamp) / SECONDS_IN_YEAR
#
# SVIImpliedVolCalculator:
#   - Inputs: FORWARD, SVI[A, B, RHO, M, SIGMA] (6 total)
#   - Output: IV using SVI parameterization of the volatility smile
#   - Formula: total_var = a + b * (rho*(k-m) + sqrt((k-m)^2 + sigma^2)), iv = sqrt(var/t)
#   - Demonstrates: Multi-input calculation, time-based expiry calculation
#
# OptionPriceCalculator:
#   - Inputs: SPOT, FORWARD, IV, DOMESTIC_RATE (IV is itself derived -> chain)
#   - Output: Option premium (vanilla or digital based on is_digital flag)
#   - For options very close to expiry (< 5 min), returns intrinsic value
#   - Demonstrates: Chained resolution, option style selection via parameters
#   - Note: Domestic rate is used only for discounting option premium, not for
#           computing forward price (forward is fetched directly from storage)
#
# Interactions:
#   - Each calculator's get_input_feed_parameters() extracts relevant parts
#     of the output params to construct input feed params
#   - Calculators are stateless - all state comes from inputs
# =============================================================================

SECONDS_IN_YEAR = 365.0 * 24 * 60 * 60
FIVE_MIN_IN_YEARS = (5 * 60) / SECONDS_IN_YEAR


def compute_time_to_expiry(timestamp: int, expiry_timestamp: int) -> float:
    """Compute time to expiry in years from timestamps.

    Args:
        timestamp: Current time in Unix seconds
        expiry_timestamp: Expiry time in Unix seconds

    Returns:
        Time to expiry in years (can be negative if expired)
    """
    return (expiry_timestamp - timestamp) / SECONDS_IN_YEAR


class SVIImpliedVolCalculator:
    NUM_INPUTS = 6  # forward, svi_a, svi_b, svi_rho, svi_m, svi_sigma

    def calculate(
        self,
        timestamp: int,
        input_data: list[float],
        parameters: FeedParameters,
    ) -> float:
        if len(input_data) != self.NUM_INPUTS:
            raise ValueError(
                f"Expected {self.NUM_INPUTS} inputs, got {len(input_data)}"
            )

        forward = input_data[0]
        svi_a = input_data[1]
        svi_b = input_data[2]
        svi_rho = input_data[3]
        svi_m = input_data[4]
        svi_sigma = input_data[5]

        expiry_timestamp = int(parameters.other.get("expiry_timestamp", 0))
        strike = float(parameters.other.get("strike", forward))
        time_to_expiry = compute_time_to_expiry(timestamp, expiry_timestamp)

        if time_to_expiry <= 0:
            return 0.0

        log_k = log(strike / forward) if forward > 0 else 0.0
        term_1 = svi_rho * (log_k - svi_m)
        term_2 = sqrt((log_k - svi_m) ** 2 + svi_sigma**2)
        total_var = svi_a + svi_b * (term_1 + term_2)

        return sqrt(total_var / time_to_expiry)

    def get_input_feed_parameters(
        self, parameters: FeedParameters
    ) -> list[FeedParameters]:
        forward_params = FeedParameters(
            enumerable=parameters.enumerable[:2],
            other={
                "expiry_timestamp": parameters.other.get("expiry_timestamp", 0)
            },
        )
        base_enum = parameters.enumerable[:2]
        svi_a = FeedParameters(enumerable=(*base_enum, SVIParam.A))
        svi_b = FeedParameters(enumerable=(*base_enum, SVIParam.B))
        svi_rho = FeedParameters(enumerable=(*base_enum, SVIParam.RHO))
        svi_m = FeedParameters(enumerable=(*base_enum, SVIParam.M))
        svi_sigma = FeedParameters(enumerable=(*base_enum, SVIParam.SIGMA))
        return [forward_params, svi_a, svi_b, svi_rho, svi_m, svi_sigma]


class OptionPriceCalculator:
    NUM_INPUTS = 4  # spot, forward, iv, domestic_rate

    def calculate(
        self,
        timestamp: int,
        input_data: list[float],
        parameters: FeedParameters,
    ) -> float:
        if len(input_data) != self.NUM_INPUTS:
            raise ValueError(
                f"Expected {self.NUM_INPUTS} inputs, got {len(input_data)}"
            )

        spot = input_data[0]
        forward = input_data[1]
        iv = input_data[2]
        domestic_rate = input_data[3]

        expiry_timestamp = int(parameters.other.get("expiry_timestamp", 0))
        strike = float(parameters.other.get("strike", forward))
        is_call = bool(parameters.other.get("is_call", True))
        is_digital = bool(parameters.other.get("is_digital", False))

        time_to_expiry = compute_time_to_expiry(timestamp, expiry_timestamp)
        if time_to_expiry <= 0:
            return 0.0

        if time_to_expiry < FIVE_MIN_IN_YEARS:
            if is_call:
                return max(spot - strike, 0.0)
            else:
                return max(strike - spot, 0.0)

        if iv <= 0:
            return 0.0

        op_type: OptionType = "C" if is_call else "P"
        style: OptionStyle = "digital" if is_digital else "vanilla"

        result = compute_option_price(
            spot=spot,
            forward=forward,
            strike=strike,
            vol=iv,
            t=time_to_expiry,
            r_d=domestic_rate,
            op_type=op_type,
            style=style,
        )
        return result.premium

    def get_input_feed_parameters(
        self, parameters: FeedParameters
    ) -> list[FeedParameters]:
        base = FeedParameters(enumerable=parameters.enumerable[:2])
        forward_params = FeedParameters(
            enumerable=parameters.enumerable[:2],
            other={
                "expiry_timestamp": parameters.other.get("expiry_timestamp", 0)
            },
        )
        return [base, forward_params, parameters, base]


# =============================================================================
# Permission Bitmask Utilities
# =============================================================================
#
# Design: Permission model using bitmasks. Each enumerable parameter position
# uses a bitmask where bit N indicates permission for value N. This allows
# compact storage of permissions for multiple values.
#
# Example: bitmask 0b0101 = 5 grants access to values 0 and 2
#   - is_authorized_for_parameter(5, 0) -> True  (bit 0 set)
#   - is_authorized_for_parameter(5, 1) -> False (bit 1 not set)
#   - is_authorized_for_parameter(5, 2) -> True  (bit 2 set)
#
# PermissionManager stores: address -> feed_id -> [bitmask_per_param_position]
#
# Interactions:
#   - Validates permissions before routing to provider
#   - Admins grant/revoke via PermissionManager methods
#   - Each enumerable param in FeedParameters is validated against its bitmask
# =============================================================================


def is_authorized_for_parameter(bitmask: int, value: int) -> bool:
    return ((1 << value) & bitmask) != 0


class PermissionManager:
    def __init__(self) -> None:
        self.permissions: dict[str, dict[int, list[int]]] = {}

    def grant(
        self, address: str, feed_id: int, param_bitmasks: list[int]
    ) -> None:
        if address not in self.permissions:
            self.permissions[address] = {}
        self.permissions[address][feed_id] = param_bitmasks

    def revoke(self, address: str, feed_id: int) -> None:
        if address in self.permissions:
            self.permissions[address].pop(feed_id, None)

    def check_access(self, address: str, feed: Feed) -> bool:
        addr_perms = self.permissions.get(address)
        if addr_perms is None:
            return False

        bitmasks = addr_perms.get(feed.id)
        if bitmasks is None:
            return False

        for i, param_value in enumerate(feed.parameters.enumerable):
            if i >= len(bitmasks):
                return False
            if not is_authorized_for_parameter(bitmasks[i], param_value):
                return False

        return True


# =============================================================================
# Demonstration
# =============================================================================


def main() -> None:
    print("=" * 70)
    print("Oracle Feed Storage Demo")
    print("=" * 70)

    # -------------------------------------------------------------------------
    # [1] Initialize Storage
    # -------------------------------------------------------------------------
    # DataStorage is the primary persistence layer. Version starts at 0 and
    # increments on reset, invalidating all existing feed keys.
    # -------------------------------------------------------------------------
    storage = DataStorage()
    print(f"\n[1] Created DataStorage (version={storage.version})")

    # -------------------------------------------------------------------------
    # [2] Fetch Live Data from API & Add Base Feeds
    # -------------------------------------------------------------------------
    # Base feeds are stored directly (not computed). Enumerable params identify
    # the data source: [source=0, asset=1] -> e.g., Deribit BTC
    # These form the foundation for derived calculations.
    # -------------------------------------------------------------------------
    expiry_iso = "2026-06-26T08:00:00.000Z"
    expiry_jun26 = int(
        datetime.fromisoformat(expiry_iso.replace("Z", "+00:00")).timestamp()
    )

    print("\n[2] Fetching live data from BlockScholes API...")

    def ts_to_iso(ts: int) -> str:
        return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Fetch spot price
    spot_data = fetch_spot_price()
    spot_value = spot_data["price"]
    spot_timestamp = int(spot_data["timestamp"])
    print(f"    SPOT: ts={spot_timestamp} ({ts_to_iso(spot_timestamp)})")

    # Fetch forward price
    forward_data = fetch_forward_price(expiry_iso)
    forward_value = forward_data["price"]
    forward_timestamp = int(forward_data["timestamp"])
    print(
        f"    FORWARD: ts={forward_timestamp} ({ts_to_iso(forward_timestamp)})"
    )

    # Fetch SVI parameters
    svi_data = fetch_svi_params(expiry_iso)
    svi_timestamp = int(svi_data["timestamp"])
    svi_a = svi_data["a"]
    svi_b = svi_data["b"]
    svi_rho = svi_data["rho"]
    svi_m = svi_data["m"]
    svi_sigma = svi_data["sigma"]
    print(f"    SVI: ts={svi_timestamp} ({ts_to_iso(svi_timestamp)})")

    # Reference timestamp for calculations (min of all fetched timestamps)
    ref_timestamp = min(spot_timestamp, forward_timestamp, svi_timestamp)
    time_to_expiry_years = (expiry_jun26 - ref_timestamp) / SECONDS_IN_YEAR
    print(
        f"    Reference ts (min): {ref_timestamp} ({ts_to_iso(ref_timestamp)}) "
        f"-> TTX={time_to_expiry_years:.4f}y"
    )

    # Add feeds to storage
    base_params = FeedParameters(enumerable=(0, 1))

    spot_feed = Feed(id=FeedType.SPOT, parameters=base_params)
    storage.add_feed_with_value(spot_feed, spot_value, timestamp=spot_timestamp)
    print(
        f"    Added SPOT feed: ${storage.get_latest_feed_data(spot_feed).value:,.2f}"
    )

    domestic_rate_feed = Feed(id=FeedType.DOMESTIC_RATE, parameters=base_params)
    storage.add_feed_with_value(
        domestic_rate_feed, DOMESTIC_RATE, timestamp=spot_timestamp
    )
    print(
        f"    Added DOMESTIC_RATE feed: {storage.get_latest_feed_data(domestic_rate_feed).value:.2%}"
    )

    # Add forward price for 26JUN26 expiry (fetched from API)
    forward_params = FeedParameters(
        enumerable=(0, 1), other={"expiry_timestamp": expiry_jun26}
    )
    forward_feed = Feed(id=FeedType.FORWARD, parameters=forward_params)
    storage.add_feed_with_value(
        forward_feed, forward_value, timestamp=forward_timestamp
    )
    print(f"    Added FORWARD feed (26JUN26 expiry): ${forward_value:,.2f}")

    # Add SVI parameters (fetched from API)
    # These are stored as separate feeds identified by enumerable[2] = SVIParam
    # SVI formula: total_var = a + b*(rho*(k-m) + sqrt((k-m)^2 + sigma^2))
    svi_a_feed = Feed(
        id=FeedType.SVI_PARAMS,
        parameters=FeedParameters(enumerable=(0, 1, SVIParam.A)),
    )
    svi_b_feed = Feed(
        id=FeedType.SVI_PARAMS,
        parameters=FeedParameters(enumerable=(0, 1, SVIParam.B)),
    )
    svi_rho_feed = Feed(
        id=FeedType.SVI_PARAMS,
        parameters=FeedParameters(enumerable=(0, 1, SVIParam.RHO)),
    )
    svi_m_feed = Feed(
        id=FeedType.SVI_PARAMS,
        parameters=FeedParameters(enumerable=(0, 1, SVIParam.M)),
    )
    svi_sigma_feed = Feed(
        id=FeedType.SVI_PARAMS,
        parameters=FeedParameters(enumerable=(0, 1, SVIParam.SIGMA)),
    )

    storage.add_feed_with_value(svi_a_feed, svi_a, timestamp=svi_timestamp)
    storage.add_feed_with_value(svi_b_feed, svi_b, timestamp=svi_timestamp)
    storage.add_feed_with_value(svi_rho_feed, svi_rho, timestamp=svi_timestamp)
    storage.add_feed_with_value(svi_m_feed, svi_m, timestamp=svi_timestamp)
    storage.add_feed_with_value(
        svi_sigma_feed, svi_sigma, timestamp=svi_timestamp
    )
    print(
        f"    Added SVI params: a={svi_a:.5f}, b={svi_b:.5f}, rho={svi_rho:.5f}, m={svi_m:.5f}, sigma={svi_sigma:.5f}"
    )
    print(f"    Storage now has {storage.feed_count()} feeds")

    # -------------------------------------------------------------------------
    # [3] Set Up Derived Data Provider
    # -------------------------------------------------------------------------
    # DerivedDataProvider routes feed requests to registered calculators.
    # Each calculator declares its input feed types; the provider handles
    # fetching inputs and chaining through derived dependencies.
    # Note: Forward prices are stored directly, not derived via calculator.
    # -------------------------------------------------------------------------
    derived = DerivedDataProvider(storage)
    print("\n[3] Created DerivedDataProvider")

    # Register IV calculator using SVI model (FORWARD + 5 SVI params -> IV)
    derived.add_calculator(
        output_feed_id=FeedType.IV,
        input_feed_ids=[
            FeedType.FORWARD,
            FeedType.SVI_PARAMS,
            FeedType.SVI_PARAMS,
            FeedType.SVI_PARAMS,
            FeedType.SVI_PARAMS,
            FeedType.SVI_PARAMS,
        ],
        handler=SVIImpliedVolCalculator(),
    )
    print(
        "    Registered SVIImpliedVolCalculator: FORWARD + SVI[a,b,rho,m,sigma] -> IV"
    )

    # Register Option Price calculator (SPOT + FORWARD + IV + DOMESTIC_RATE -> OPTION_PRICE)
    # Handles both vanilla and digital options via is_digital flag
    # Domestic rate is used only for discounting, not for forward calculation
    derived.add_calculator(
        output_feed_id=FeedType.OPTION_PRICE,
        input_feed_ids=[
            FeedType.SPOT,
            FeedType.FORWARD,
            FeedType.IV,
            FeedType.DOMESTIC_RATE,
        ],
        handler=OptionPriceCalculator(),
    )
    print(
        "    Registered OptionPriceCalculator: SPOT + FORWARD + IV + DOMESTIC_RATE -> OPTION_PRICE"
    )

    # -------------------------------------------------------------------------
    # [4] Query Derived Data (Chained Resolution)
    # -------------------------------------------------------------------------
    # When requesting a derived feed, the provider automatically:
    # 1. Finds the calculator for that feed type
    # 2. Fetches required inputs (recursively computing derived inputs)
    # 3. Invokes the calculator with collected inputs
    # Forward is fetched directly from storage (not derived).
    # -------------------------------------------------------------------------
    print("\n[4] Querying derived feeds (demonstrates chained resolution)")

    # Forward price for 26JUN26 expiry (fetched from storage)
    forward_data = storage.get_latest_feed_data(forward_feed)
    print(f"    FORWARD (26JUN26): ${forward_data.value:,.2f} (from storage)")

    # IV for 26JUN26 expiry, ATM strike (at forward)
    atm_strike = forward_value
    iv_params_atm = FeedParameters(
        enumerable=(0, 1),
        other={"expiry_timestamp": expiry_jun26, "strike": atm_strike},
    )
    iv_feed_atm = Feed(id=FeedType.IV, parameters=iv_params_atm)
    iv_data_atm = derived.get_latest_feed_data(iv_feed_atm)
    print(f"    IV (26JUN26, ATM K={atm_strike:,.0f}): {iv_data_atm.value:.2%}")

    # IV for OTM call strike (+10k over forward) - shows smile effect
    otm_strike = forward_value + 10000
    iv_params_otm = FeedParameters(
        enumerable=(0, 1),
        other={"expiry_timestamp": expiry_jun26, "strike": otm_strike},
    )
    iv_feed_otm = Feed(id=FeedType.IV, parameters=iv_params_otm)
    iv_data_otm = derived.get_latest_feed_data(iv_feed_otm)
    print(
        f"    IV (26JUN26, OTM K={otm_strike:,.0f}): {iv_data_otm.value:.2%} <- SVI smile effect"
    )
    print(
        "    Chain: FORWARD(storage) + SVI -> IV, SPOT+FORWARD+IV+DOMESTIC_RATE -> PRICE"
    )

    # -------------------------------------------------------------------------
    # [5] Option Pricing (Vanilla & Digital)
    # -------------------------------------------------------------------------
    # Shows vanilla and digital option prices for both calls and puts at:
    # - ATM strike (at forward)
    # - OTM strike (+10k over forward)
    # -------------------------------------------------------------------------
    print("\n[5] Option pricing (Vanilla & Digital, Call & Put)")

    def get_option_price(
        strike: float, is_call: bool, is_digital: bool
    ) -> float:
        params = FeedParameters(
            enumerable=(0, 1),
            other={
                "expiry_timestamp": expiry_jun26,
                "strike": strike,
                "is_call": is_call,
                "is_digital": is_digital,
            },
        )
        feed = Feed(id=FeedType.OPTION_PRICE, parameters=params)
        return derived.get_latest_feed_data(feed).value

    # ATM options (strike = forward)
    print(f"\n    ATM (K={atm_strike:,.0f}):")
    vanilla_atm_call = get_option_price(
        atm_strike, is_call=True, is_digital=False
    )
    vanilla_atm_put = get_option_price(
        atm_strike, is_call=False, is_digital=False
    )
    digital_atm_call = get_option_price(
        atm_strike, is_call=True, is_digital=True
    )
    digital_atm_put = get_option_price(
        atm_strike, is_call=False, is_digital=True
    )
    print(f"      Vanilla Call: ${vanilla_atm_call:,.2f}")
    print(f"      Vanilla Put:  ${vanilla_atm_put:,.2f}")
    print(f"      Digital Call: {digital_atm_call:.4f}")
    print(f"      Digital Put:  {digital_atm_put:.4f}")

    # OTM options (strike = forward + 10k)
    print(f"\n    OTM (K={otm_strike:,.0f}):")
    vanilla_otm_call = get_option_price(
        otm_strike, is_call=True, is_digital=False
    )
    vanilla_otm_put = get_option_price(
        otm_strike, is_call=False, is_digital=False
    )
    digital_otm_call = get_option_price(
        otm_strike, is_call=True, is_digital=True
    )
    digital_otm_put = get_option_price(
        otm_strike, is_call=False, is_digital=True
    )
    print(f"      Vanilla Call: ${vanilla_otm_call:,.2f}")
    print(f"      Vanilla Put:  ${vanilla_otm_put:,.2f}")
    print(f"      Digital Call: {digital_otm_call:.4f}")
    print(f"      Digital Put:  {digital_otm_put:.4f}")

    # -------------------------------------------------------------------------
    # [6] Update Base Feed & Re-query
    # -------------------------------------------------------------------------
    # Updating a base feed automatically affects all derived values that
    # depend on it. No cache invalidation needed - derived values are
    # computed fresh on each request.
    # -------------------------------------------------------------------------
    print("\n[6] Update SPOT & FORWARD prices and re-query derived values")
    new_spot = spot_value + 5000.0
    new_forward = forward_value + 5000.0
    storage.update_data_for_feed(
        spot_feed, new_spot, timestamp=spot_timestamp + 100
    )
    print(
        f"    Updated SPOT: ${storage.get_latest_feed_data(spot_feed).value:,.2f} (+5k)"
    )

    storage.update_data_for_feed(
        forward_feed, new_forward, timestamp=forward_timestamp + 100
    )
    print(f"    Updated FORWARD (26JUN26): ${new_forward:,.2f} (+5k)")

    # Re-query ATM options with new forward as strike
    new_atm_strike = new_forward
    new_otm_strike = new_forward + 10000
    print(f"\n    New ATM (K={new_atm_strike:,.0f}):")
    print(
        f"      Vanilla Call: ${get_option_price(new_atm_strike, True, False):,.2f}"
    )
    print(
        f"      Vanilla Put:  ${get_option_price(new_atm_strike, False, False):,.2f}"
    )
    print(
        f"      Digital Call: {get_option_price(new_atm_strike, True, True):.4f}"
    )
    print(
        f"      Digital Put:  {get_option_price(new_atm_strike, False, True):.4f}"
    )

    print(f"\n    New OTM (K={new_otm_strike:,.0f}):")
    print(
        f"      Vanilla Call: ${get_option_price(new_otm_strike, True, False):,.2f}"
    )
    print(
        f"      Vanilla Put:  ${get_option_price(new_otm_strike, False, False):,.2f}"
    )
    print(
        f"      Digital Call: {get_option_price(new_otm_strike, True, True):.4f}"
    )
    print(
        f"      Digital Put:  {get_option_price(new_otm_strike, False, True):.4f}"
    )

    # -------------------------------------------------------------------------
    # [7] Permission Bitmask Demonstration
    # -------------------------------------------------------------------------
    # Permissions use bitmasks for compact storage. Each enumerable parameter
    # position has a bitmask where bit N grants access to value N.
    # Example: bitmask 0b0011 grants access to values 0 and 1.
    # -------------------------------------------------------------------------
    print("\n[7] Permission bitmask demonstration")
    perms = PermissionManager()

    # Grant access: address can read SPOT for source=0 (bit 0) and asset=1 (bit 1)
    perms.grant("0xAlice", FeedType.SPOT, [0b0001, 0b0010])
    print("    Granted 0xAlice: SPOT for source=0, asset=1")

    allowed_feed = Feed(
        id=FeedType.SPOT, parameters=FeedParameters(enumerable=(0, 1))
    )
    denied_feed = Feed(
        id=FeedType.SPOT, parameters=FeedParameters(enumerable=(1, 1))
    )

    print(
        f"    0xAlice read SPOT(source=0, asset=1): {perms.check_access('0xAlice', allowed_feed)}"
    )
    print(
        f"    0xAlice read SPOT(source=1, asset=1): {perms.check_access('0xAlice', denied_feed)}"
    )
    print(
        f"    0xBob read SPOT(source=0, asset=1): {perms.check_access('0xBob', allowed_feed)}"
    )

    # -------------------------------------------------------------------------
    # [8] Extensibility: Add New Calculator at Runtime
    # -------------------------------------------------------------------------
    # New calculators can be registered at any time without modifying existing
    # code. This enables adding new derived feed types dynamically.
    # -------------------------------------------------------------------------
    print("\n[8] Extensibility: Add custom calculator at runtime")

    class BasisCalculator:
        NUM_INPUTS = 2

        def calculate(
            self,
            timestamp: int,
            input_data: list[float],
            parameters: FeedParameters,
        ) -> float:
            forward = input_data[0]
            spot = input_data[1]
            return forward - spot

        def get_input_feed_parameters(
            self, parameters: FeedParameters
        ) -> list[FeedParameters]:
            base = FeedParameters(enumerable=parameters.enumerable)
            return [parameters, base]

    BASIS_FEED_ID = 100
    derived.add_calculator(
        output_feed_id=BASIS_FEED_ID,
        input_feed_ids=[FeedType.FORWARD, FeedType.SPOT],
        handler=BasisCalculator(),
    )
    print(f"    Registered BasisCalculator for feed ID {BASIS_FEED_ID}")

    basis_feed = Feed(id=BASIS_FEED_ID, parameters=forward_params)
    basis_data = derived.get_latest_feed_data(basis_feed)
    print(f"    BASIS (Forward - Spot, 26JUN26): ${basis_data.value:,.2f}")

    # -------------------------------------------------------------------------
    # [9] Reset Demonstration
    # -------------------------------------------------------------------------
    # Resetting clears all data and increments the version. This invalidates
    # all feed keys since the key includes the version number, ensuring stale
    # references fail cleanly.
    # -------------------------------------------------------------------------
    print(
        "\n[9] Reset storage (invalidates all feed keys via version increment)"
    )
    old_version = storage.version
    storage.reset_all_data()
    print(f"    Version changed: {old_version} -> {storage.version}")
    print(f"    Feed count after reset: {storage.feed_count()}")

    print("\n" + "=" * 70)
    print("Demo complete!")
    print("=" * 70)


if __name__ == "__main__":
    main()
