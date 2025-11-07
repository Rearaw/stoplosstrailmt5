import MetaTrader5 as mt5
import time
import logging
from return_codes import retcodedes
# === CONFIGURATION ===
CHECK_INTERVAL=0.1# Seconds between updates
USE_BREAK_EVEN=True
LOGIN = None          # MT5 account login (set to your account number, e.g., 123456)
PASSWORD = None       # MT5 account password (set to your password)
SERVER = None         # MT5 server name (set to your broker's server, e.g., "Broker-Demo")
volatility_map={"high":{"TRAIL_DISTANCE": 50, # Fixed trailing distance in points
                     
                    "MIN_PROFIT": 100,   # Minimum profit in account currency to start trailing
                    "MIN_PRICE_MOVE":50.0,
                    },
            "medium":{"TRAIL_DISTANCE": 20, # Fixed trailing distance in points
                    "MIN_PROFIT": 50,   # Minimum profit in account currency to start trailing
                    "MIN_PRICE_MOVE":25.0,
                    },
            "low":{"TRAIL_DISTANCE": 15, # Fixed trailing distance in points
                    "MIN_PROFIT": 20,   # Minimum profit in account currency to start trailing
                    "MIN_PRICE_MOVE":10.0,
                    }
            }


volatility_currency_pairs={
    "high":["XAUUSDm"],
    "medium":["GBPUSDm","EURUSDm","USDCHFm","USDCADm","AUDUSDm","NZDUSDm","GBPJPYm","EURJPYm","USDJPYm"],
    "low":["EURCHFm","EURGBPm","AUDJPYm","CADJPYm","CHFJPYm","NZDJPYm"],}

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


# === MAIN LOOP ===
last_sl_price = {}  # Track the price at which the last SL was set per position ticket

try:
    while True:
        positions = mt5.positions_get()
        if positions is None:
            logger.error("Failed to get positions")
            time.sleep(CHECK_INTERVAL)
            continue

        if not positions:
            #logger.info("No open positions")
            pass
        else:
            for pos in positions:
                ticket = pos.ticket
                symbol = pos.symbol
                info = mt5.symbol_info(symbol)
                tick = mt5.symbol_info_tick(symbol)
                # Determine volatility settings for this symbol (fallback to 'medium' defaults)
                level = None
                for vol_level, symbols in volatility_currency_pairs.items():
                    if symbol in symbols:
                        level = vol_level
                        break

                if level:
                    cfg = volatility_map.get(level, {})
                    TRAIL_DISTANCE = cfg.get("TRAIL_DISTANCE", volatility_map["medium"]["TRAIL_DISTANCE"])
                    MIN_PROFIT = cfg.get("MIN_PROFIT", volatility_map["medium"]["MIN_PROFIT"])
                    MIN_PRICE_MOVE = cfg.get("MIN_PRICE_MOVE", volatility_map["medium"]["MIN_PRICE_MOVE"])
                    logger.debug(f"Symbol {symbol} found in volatility level '{level}'; TRAIL_DISTANCE={TRAIL_DISTANCE}, MIN_PROFIT={MIN_PROFIT}, MIN_PRICE_MOVE={MIN_PRICE_MOVE}")
                else:
                    TRAIL_DISTANCE = volatility_map["medium"]["TRAIL_DISTANCE"]
                    MIN_PROFIT = volatility_map["medium"]["MIN_PROFIT"]
                    MIN_PRICE_MOVE = volatility_map["medium"]["MIN_PRICE_MOVE"]
                    logger.debug(f"Symbol {symbol} not found in volatility mapping; using defaults TRAIL_DISTANCE={TRAIL_DISTANCE}, MIN_PROFIT={MIN_PROFIT}, MIN_PRICE_MOVE={MIN_PRICE_MOVE}")
                if not info or not tick:
                    logger.error(f"Failed to get symbol info or tick for {symbol}")
                    continue

                point = info.point
                digits = info.digits
                current_price = tick.bid if pos.type == 0 else tick.ask
                profit_points = (current_price - pos.price_open) / point if pos.type == 0 else (pos.price_open - current_price) / point
                # If no stop loss set, add one based on volatility level (in pips)
                if pos.sl == 0:
                    try:
                        # Define initial SL pips for each volatility level
                        initial_sl_pips = {
                            "high": 388,    # ~500kes approximate 500kes
                            "medium": 60,   # ~500kes pips for medium volatility(jpys)
                            "low": 30       # 30 pips for low volatility
                        }
                        
                        # Get SL pips based on volatility level (default to medium)
                        sl_pips = initial_sl_pips.get(level, initial_sl_pips["medium"])
                        
                        # Convert pips to points (1 pip = 10 points for most pairs)
                        sl_points = sl_pips * 10
                        
                        if pos.type == 0:  # BUY
                            initial_sl = pos.price_open - sl_points * point
                        else:  # SELL
                            initial_sl = pos.price_open + sl_points * point

                        request = {
                            "action": mt5.TRADE_ACTION_SLTP,
                            "symbol": symbol,
                            "sl": round(initial_sl, digits),
                            "tp": pos.tp,
                            "position": ticket,
                        }
                        result = mt5.order_send(request)
                        if result.retcode == mt5.TRADE_RETCODE_DONE:
                            logger.info(f"Set initial SL ({sl_pips} pips) for {'BUY' if pos.type==0 else 'SELL'} position {ticket} ({symbol}) to {initial_sl:.{digits}f}")
                            last_sl_price[ticket] = current_price
                        else:
                            logger.error(f"Failed to set initial SL for position {ticket} ({symbol}) to {initial_sl:.{digits}f},{retcodedes(result.retcode)}")
                    except Exception as e:
                        logger.exception(f"Exception when setting initial SL for position {ticket} ({symbol}): {e}")
                if pos.profit > MIN_PROFIT:
                    # Break-even protection: Skip trailing if profit_points < TRAIL_DISTANCE
                    if USE_BREAK_EVEN and profit_points < TRAIL_DISTANCE:
                        logger.info(f"Skipping SL trail for {pos.type} position {ticket} ({symbol}): profit_points={profit_points:.2f} < TRAIL_DISTANCE={TRAIL_DISTANCE}")
                        continue

                    # Check for significant price movement
                    update_sl = False
                    if ticket not in last_sl_price:  # First SL update
                        update_sl = True
                    else:
                        last_price = last_sl_price[ticket]
                        if pos.type == 0:  # BUY
                            if current_price >= last_price + MIN_PRICE_MOVE * point:
                                update_sl = True
                        else:  # SELL
                            if current_price <= last_price - MIN_PRICE_MOVE * point:
                                update_sl = True

                    if update_sl:
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
                                    last_sl_price[ticket] = current_price
                                else:
                                    logger.error(f"Failed to move SL for BUY position {ticket} ({symbol}) to {new_sl:.{digits}f}, {retcodedes(result.retcode)}")

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
                                    last_sl_price[ticket] = current_price
                                else:
                                    logger.error(f"Failed to move SL for SELL position {ticket} ({symbol}) to {new_sl:.{digits}f}, {retcodedes(result.retcode)}")

        time.sleep(CHECK_INTERVAL)
except KeyboardInterrupt:
    logger.info("Script interrupted by user")
finally:
    mt5.shutdown()
    logger.info("MT5 connection shut down")