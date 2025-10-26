import sys
import importlib
import types
import time
import pytest

def _make_fake_mt5(positions, point=0.0001, digits=5, trade_retcode_done=10009):
    """
    Create a Fake MetaTrader5 module object with expected methods/attributes.
    positions: list of position-like dicts with keys:
      ticket, symbol, type, price_open, sl, tp, profit, tick_bid, tick_ask
    """
    class FakeInfo:
        def __init__(self, point, digits):
            self.point = point
            self.digits = digits

    class FakeTick:
        def __init__(self, bid, ask):
            self.bid = bid
            self.ask = ask

    class FakePos:
        def __init__(self, d):
            self.ticket = d.get("ticket")
            self.symbol = d.get("symbol")
            self.type = d.get("type")
            self.price_open = d.get("price_open")
            self.sl = d.get("sl", 0.0)
            self.tp = d.get("tp", 0.0)
            self.profit = d.get("profit", 0.0)

    class FakeResult:
        def __init__(self, retcode):
            self.retcode = retcode

    fake = types.SimpleNamespace()
    fake.TRADE_ACTION_SLTP = 1
    fake.TRADE_RETCODE_DONE = trade_retcode_done
    fake._shutdown_called = False
    fake._order_requests = []

    # internal storage
    _positions = [FakePos(p) for p in positions]
    _ticks = {p["symbol"]: FakeTick(p["tick_bid"], p["tick_ask"]) for p in positions}
    _info = {p["symbol"]: FakeInfo(point, digits) for p in positions}

    def initialize(**kwargs):
        return True

    def shutdown():
        fake._shutdown_called = True

    def positions_get():
        # return a shallow copy of positions to mimic real behaviour
        return list(_positions)

    def symbol_info(sym):
        return _info.get(sym)

    def symbol_info_tick(sym):
        return _ticks.get(sym)

    def order_send(request):
        fake._order_requests.append(request)
        return FakeResult(fake.TRADE_RETCODE_DONE)

    fake.initialize = initialize
    fake.shutdown = shutdown
    fake.positions_get = positions_get
    fake.symbol_info = symbol_info
    fake.symbol_info_tick = symbol_info_tick
    fake.order_send = order_send

    return fake

def _import_v2_with_fake_mt5(fake_mt5, sleep_side_effect):
    """
    Insert fake_mt5 into sys.modules under the name 'MetaTrader5',
    monkeypatch time.sleep to the provided side effect (callable),
    ensure V2 is re-imported (removed first).
    Returns the fake_mt5 object and the imported V2 module.
    """
    # inject fake MetaTrader5 module before importing V2
    sys.modules['MetaTrader5'] = fake_mt5
    # ensure V2 is reloaded fresh
    if 'V2' in sys.modules:
        del sys.modules['V2']
    # patch time.sleep to trigger exit after one loop iteration
    original_sleep = time.sleep
    time.sleep = sleep_side_effect
    try:
        v2 = importlib.import_module('V2')
    finally:
        # restore time.sleep to avoid affecting other tests/process
        time.sleep = original_sleep
    return fake_mt5, v2

def test_buy_position_trails_stop_loss(monkeypatch):
    # Arrange: create a BUY position that meets MIN_PROFIT and TRAIL_DISTANCE requirements
    ticket = 12345
    symbol = "EURUSD"
    # price_open and tick_bid chosen so profit_points >= TRAIL_DISTANCE (4.0)
    pos = {
        "ticket": ticket,
        "symbol": symbol,
        "type": 0,  # BUY
        "price_open": 1.10000,
        "sl": 0.0,
        "tp": 0.0,
        "profit": 12.0,  # > MIN_PROFIT (11.0)
        "tick_bid": 1.10050,
        "tick_ask": 1.10060,
    }
    fake_mt5 = _make_fake_mt5([pos], point=0.0001, digits=5, trade_retcode_done=10009)

    # make time.sleep raise KeyboardInterrupt to stop the infinite loop after first iteration
    def sleep_raises(sec):
        raise KeyboardInterrupt()

    # Act: import V2 with fake mt5 and patched sleep
    fake_module, v2 = _import_v2_with_fake_mt5(fake_mt5, sleep_raises)

    # Assert: one order_send call was made to move SL for the BUY position
    assert len(fake_module._order_requests) == 1
    req = fake_module._order_requests[0]
    assert req["position"] == ticket
    # expected new SL = current_price - TRAIL_DISTANCE * point
    trail_distance = v2.TRAIL_DISTANCE
    point = v2.mt5.symbol_info(symbol).point
    expected_new_sl = round(pos["tick_bid"] - trail_distance * point, v2.mt5.symbol_info(symbol).digits)
    assert pytest.approx(req["sl"], rel=1e-6) == expected_new_sl
    # ensure shutdown was called
    assert fake_module._shutdown_called is True

def test_no_trail_when_profit_below_min(monkeypatch):
    # Arrange: create a BUY position that has profit below MIN_PROFIT so no SL move should occur
    ticket = 22222
    symbol = "GBPUSD"
    pos = {
        "ticket": ticket,
        "symbol": symbol,
        "type": 0,  # BUY
        "price_open": 1.25000,
        "sl": 0.0,
        "tp": 0.0,
        "profit": 5.0,  # < MIN_PROFIT
        "tick_bid": 1.25050,
        "tick_ask": 1.25060,
    }
    fake_mt5 = _make_fake_mt5([pos], point=0.0001, digits=5, trade_retcode_done=10009)

    def sleep_raises(sec):
        raise KeyboardInterrupt()

    fake_module, v2 = _import_v2_with_fake_mt5(fake_mt5, sleep_raises)

    # Assert: no order_send calls were made because profit < MIN_PROFIT
    assert len(fake_module._order_requests) == 0
    assert fake_module._shutdown_called is True