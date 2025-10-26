import MetaTrader5 as mt5
import time
import logging
import numpy as np

# === CONFIGURATION ===
TRAIL_DISTANCE = 3.0  # Fixed trailing distance in points (adjustable, 1-5 recommended)
MIN_PROFIT = 0.0      # Minimum profit in account currency to start trailing (0 to trail when positive)
USE_BREAK_EVEN = True # Only trail when profit in points >= TRAIL_DISTANCE
LOGIN = None          # MT5 account login (set to your account number, e.g., 123456)
PASSWORD = None       # MT5 account password (set to your password)
SERVER = None         # MT5 server name (set to your broker's server, e.g., "Broker-Demo")
ATR_PERIOD = 14       # ATR period for volatility measurement
ATR_TIMEFRAME = mt5.TIMEFRAME_M1  # Timeframe for ATR (H1)
VOLATILITY_THRESHOLD = 50.0  # ATR in points above which the symbol is considered volatile
VOLATILE_INTERVAL = 1.0  # Check interval in seconds for volatile symbols
SLOW_INTERVAL = 10.0     # Check interval in seconds for slow symbols

# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# === INITIALIZE MT5 ===
init_kwargs = {}
if LOGIN:
    init_kwargs['login'] = LOGIN
if PASSWORD:
    init_kwargs['password'] = PASSWORD
if SERVER:
    init_kwargs['server'] = SERVER

if not mt5.initialize(**init_kwargs):
    logger.error("Failed to initialize MT5")
    mt5.shutdown()
    exit()

logger.info("Successfully connected to MT5")

# === HELPER FUNCTIONS ===
def get_atr(symbol, timeframe, period):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, period + 1)
    if rates is None or len(rates) < period + 1:
        return None
    highs = rates['high']
    lows = rates['low']
    closes = rates['close']
    tr = np.maximum(highs[1:] - lows[1:], np.abs(highs[1:] - closes[:-1]), np.abs(lows[1:] - closes[:-1]))
    atr = np.mean(tr)
    return atr

# === MAIN LOOP ===
last_update_time = {}  # Dictionary to track last update time per position ticket

try:
    while True:
        positions = mt5.positions_get()
        if positions is None:
            logger.error("Failed to get positions")
            time.sleep(1)  # Minimal sleep on error
            continue

        if not positions:
            logger.info("No open positions")
            time.sleep(1)  # Minimal sleep when no positions
            continue

        current_time = time.time()
        for pos in positions:
            ticket = pos.ticket
            symbol = pos.symbol
            info = mt5.symbol_info(symbol)
            tick = mt5.symbol_info_tick(symbol)
            if not info or not tick:
                logger.error(f"Failed to get symbol info or tick for {symbol}")
                continue

            point = info.point
            digits = info.digits
            current_price = tick.bid if pos.type == 0 else tick.ask
            profit_points = (current_price - pos.price_open) / point if pos.type == 0 else (pos.price_open - current_price) / point

            # Calculate ATR to determine volatility
            atr = get_atr(symbol, ATR_TIMEFRAME, ATR_PERIOD)
            if atr is None:
                logger.error(f"Failed to calculate ATR for {symbol}")
                continue
            atr_points = atr / point
            interval = VOLATILE_INTERVAL if atr_points > VOLATILITY_THRESHOLD else SLOW_INTERVAL
            logger.info(f"Symbol {symbol}: ATR_points={atr_points:.2f}, interval={interval} seconds")

            # Check if it's time to update this position
            if ticket not in last_update_time or (current_time - last_update_time[ticket] >= interval):
                if pos.profit > MIN_PROFIT:
                    # Break-even protection: Skip trailing if profit_points < TRAIL_DISTANCE
                    if USE_BREAK_EVEN and profit_points < TRAIL_DISTANCE:
                        logger.info(f"Skipping SL trail for {pos.type} position {ticket} ({symbol}): profit_points={profit_points:.2f} < TRAIL_DISTANCE={TRAIL_DISTANCE}")
                    else:
                        if pos.type == 0:  # BUY
                            new_sl = current_price - TRAIL_DISTANCE * point
                            if pos.sl == 0 or new_sl > pos.sl:  # Allow setting SL or if new SL is higher
                                request = {
                                    "action": mt5.TRADE_ACTION_SLTP,
                                    "symbol": symbol,
                                    "sl": round(new_sl, digits),
                                    "tp": pos.tp,
                                    "position": ticket,
                                }
                                result = mt5.order_send(request)
                                if result.retcode == mt5.TRADE_RETCODE_DONE:
                                    logger.info(f"Successfully moved SL for BUY position {ticket} ({symbol}) to {new_sl:.{digits}f}")
                                else:
                                    logger.error(f"Failed to move SL for BUY position {ticket} ({symbol}) to {new_sl:.{digits}f}, retcode={result.retcode}")

                        elif pos.type == 1:  # SELL
                            new_sl = current_price + TRAIL_DISTANCE * point
                            if pos.sl == 0 or (pos.sl > 0 and new_sl < pos.sl):  # Allow setting SL or if new SL is lower
                                request = {
                                    "action": mt5.TRADE_ACTION_SLTP,
                                    "symbol": symbol,
                                    "sl": round(new_sl, digits),
                                    "tp": pos.tp,
                                    "position": ticket,
                                }
                                result = mt5.order_send(request)
                                if result.retcode == mt5.TRADE_RETCODE_DONE:
                                    logger.info(f"Successfully moved SL for SELL position {ticket} ({symbol}) to {new_sl:.{digits}f}")
                                else:
                                    logger.error(f"Failed to move SL for SELL position {ticket} ({symbol}) to {new_sl:.{digits}f}, retcode={result.retcode}")

                last_update_time[ticket] = current_time

        time.sleep(1)  # Global minimal sleep to avoid high CPU usage; per-position updates are controlled by interval
except KeyboardInterrupt:
    logger.info("Script interrupted by user")
finally:
    mt5.shutdown()
    logger.info("MT5 connection shut down")