import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime
from typing import Literal, Optional, Dict, List
import os
import logging
from strategies.smma_mt5_strategy import smma_crossover_strategy
from return_codes import retcodedes
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

SYMBOLS: List[str] = ["USDJPYm","USOILm"]  # trade symbols here
TIMEFRAME = mt5.TIMEFRAME_M1
# =============================SMMA CONFIG =============================
SHORT_LEN = 9
LONG_LEN = 45
SQUEEZE_WINDOW = 3
SQUEEZE_SIZE = 0.0005       # Adjust per symbol if needed (e.g., forex pips)
CHECK_INTERVAL = 60         # Check every 60 seconds
LOG_FILE = "signals_log.csv"  # Optional: Log signals to file
# =================================================================
def place_buy_orders(lot_size: float, num_orders: int, symbol: str):
    try:
        for _ in range(num_orders):
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": lot_size,
                "type": mt5.ORDER_TYPE_BUY,
                "price": mt5.symbol_info_tick(symbol).ask,
                "type_filling": mt5.ORDER_FILLING_IOC,
            }
            
            result = mt5.order_send(request)
            ts = datetime.now().strftime("%H:%M:%S")
            if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
                logger.info(f"[INFO] {ts} - order was Successfully placed")
            else:
                rc = getattr(result, "retcode", None)
                logger.error(f"[ERROR] {ts} - Failed to BUY, {retcodedes(rc)}")
    except Exception as e:
        ts = datetime.now().strftime("%H:%M:%S")
        logger.append(f"[ERROR] {ts} - Error placing BUY orders: {e}")
def place_sell_orders(lot_size: float, num_orders: int, symbol: str):
    try:
        for _ in range(num_orders):
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": lot_size,
                "type": mt5.ORDER_TYPE_SELL,
                "price": mt5.symbol_info_tick(symbol).bid,
                "type_filling": mt5.ORDER_FILLING_IOC,
            }
            
            result = mt5.order_send(request)
            ts = datetime.now().strftime("%H:%M:%S")
            if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
                logger.info(f"[INFO] {ts} - order was Successfully placed")
            else:
                rc = getattr(result, "retcode", None)
                logger.error(f"[ERROR] {ts} - Failed to SELL, {retcodedes(rc)}")
    except Exception as e:
        ts = datetime.now().strftime("%H:%M:%S")
        logger.append(f"[ERROR] {ts} - Error placing SELL orders: {e}")

def get_rates(symbol: str, timeframe: int, bars: int) -> Optional[pd.DataFrame]:
    """Fetch latest OHLC data from MT5 for a specific symbol."""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        print(f"[{datetime.now()}] Failed to retrieve rates for {symbol}")
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df
def log_signals_to_file(results: pd.DataFrame):
    """Append current signals to CSV log file."""
    timestamp = datetime.now()
    log_df = results.copy()
    log_df['timestamp'] = timestamp
    log_df = log_df[['timestamp', 'symbol', 'signal', 'short_smma', 'long_smma', 'distance']]
    log_df.to_csv(LOG_FILE, mode='a', header=not os.path.exists(LOG_FILE), index=False)
    print(f"[{timestamp}] Signals logged to {LOG_FILE}")

def get_active_trades(symbol: Optional[str] = None) -> Optional[pd.DataFrame]:
    """
    Return current open positions from MT5 as a pandas DataFrame.
    If no active positions are found, returns None.
    If symbol is provided, only returns positions for that symbol.
    """
    try:
        positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
        if positions is None:
            logger.error(f"Failed to retrieve positions from MT5{' for ' + symbol if symbol else ''}")
            return None
        if len(positions) == 0:
            logger.info(f"No active positions{' for ' + symbol if symbol else ''}")
            return None

        # Convert MT5 position objects to list of dicts and build DataFrame
        rows = [p._asdict() for p in positions]
        df = pd.DataFrame(rows)

        # Convert any epoch time columns to datetime where appropriate
        for col in df.columns:
            if "time" in col and pd.api.types.is_integer_dtype(df[col].dtype):
                try:
                    df[col] = pd.to_datetime(df[col], unit="s")
                except Exception:
                    # ignore conversion errors and leave original values
                    pass

        logger.info(f"Retrieved {len(df)} active position(s){' for ' + symbol if symbol else ''}")
        return df

    except Exception as e:
        logger.error(f"Error while fetching active trades: {e}")
        return None
# ============================= MAIN LOOP =============================
def get_signals():
    ...

def main():
    if not mt5.initialize():
        print("MT5 initialization failed. Check if MT5 is running and logged in.")
        return

    account = mt5.account_info()
    print(f"Connected to MT5 | Account: {account.login} | Server: {account.server}")
    print(f"Monitoring symbols: {', '.join(SYMBOLS)} | Timeframe: {TIMEFRAME} | Check every {CHECK_INTERVAL}s")
    print(f"SMMA({SHORT_LEN}), SMMA({LONG_LEN}) | Squeeze: {SQUEEZE_WINDOW} bars, ≤ {SQUEEZE_SIZE}")

    last_signals: Dict[str, str] = {sym: "none" for sym in SYMBOLS}
    required_bars = (max(LONG_LEN, SHORT_LEN) + SQUEEZE_WINDOW )+24
    print("\nWaiting for signals...\n")

    while True:
        try:
            results_list = []
            for symbol in SYMBOLS:
                df = get_rates(symbol, TIMEFRAME, required_bars)
                if df is None or len(df) < required_bars:
                    continue

                result = smma_crossover_strategy(
                    df, SHORT_LEN, LONG_LEN, SQUEEZE_WINDOW, SQUEEZE_SIZE
                )
                result['symbol'] = symbol
                results_list.append(result)

            if not results_list:
                time.sleep(CHECK_INTERVAL)
                continue

            results_df = pd.DataFrame(results_list)

            # Display table of current signals
            display_cols = ['symbol','trend']
            print(results_df[display_cols].to_string(index=False, float_format='%.5f'))

            # Check for new signals and alert
            for _, row in results_df.iterrows():
                symbol = row['symbol']
                trend = row['trend']


            # Log to file
            #log_signals_to_file(results_df)

            time.sleep(CHECK_INTERVAL)

        except KeyboardInterrupt:
            print("\nStrategy stopped by user.")
            break
        except Exception as e:
            print(f"Error: {e}")
            time.sleep(CHECK_INTERVAL)

    mt5.shutdown()
    print("MT5 connection closed.")
if __name__ == "__main__":
    main()