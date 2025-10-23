import MetaTrader5 as mt5
from time import sleep

# === CONFIGURATION ===
SYMBOL = "USDJPYm"
TRAIL_DISTANCE = 4
  # in points
CHECK_INTERVAL = 3    # seconds between updates

# === INITIALIZE MT5 ===
if not mt5.initialize():
    print("initialize() failed")
    mt5.shutdown()
    exit()

print("Connected to MT5")

# === MAIN LOOP ===
while True:
    positions = mt5.positions_get()
    if not positions:
        print("No open positions for", SYMBOL)
    else:
        for pos in positions:
            ticket = pos.ticket
            price_open = pos.price_open
            sl = pos.sl
            tp = pos.tp
            position_type = pos.type  # 0=BUY, 1=SELL

            tick = mt5.symbol_info_tick(SYMBOL)
            current_price = tick.bid if position_type == 0 else tick.ask
            if pos.profit>2.0:

                if position_type == 0:  # BUY
                    new_sl = current_price - TRAIL_DISTANCE * mt5.symbol_info(SYMBOL).point
                    if new_sl and new_sl > price_open:
                        request = {
                            "action": mt5.TRADE_ACTION_SLTP,
                            "symbol": SYMBOL,
                            "sl": round(new_sl, 5),
                            "tp": tp,
                            "position": ticket,
                        }
                        result = mt5.order_send(request)
                        print(f"Moved SL for BUY {ticket} to {new_sl}, result={result.retcode}")

                elif position_type == 1:  # SELL
                    new_sl = current_price+TRAIL_DISTANCE*mt5.symbol_info(SYMBOL).point
                    if  new_sl < price_open:
                        request = {
                            "action": mt5.TRADE_ACTION_SLTP,
                            "symbol": SYMBOL,
                            "sl": round(new_sl, 5),
                            "tp": tp,
                            "position": ticket,
                        }
                        result = mt5.order_send(request)
                        print(f"Moved SL for SELL {ticket} to {new_sl}, result={result.retcode}")

    sleep(CHECK_INTERVAL)
