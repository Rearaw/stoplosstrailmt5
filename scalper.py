import os.path, sys
sys.path.append(os.path.abspath(os.path.expanduser("~/smart-money-concepts/")))

import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import threading
import time
from typing import Dict, List, Literal, Optional
from termcolor import colored
import logging
from datetime import datetime
import account_manager as am
import deal as d
from smartmoneyconcepts import smc
from strategies.smma_mt5_strategy import triple_smma_stateful_strategy as smma_strategy
from sleeper import sleeper
import colorama
from colorama import Fore, Style, init
colorama.init()
from sleeper import sleeper
init(autoreset=True)
import pattern_recognition as pr

FVG_FORMING_PATTERNS = {
    'bullish': ['Belt Hold', 'Marubozu', 'Long Line', 'Engulfing', '3 Inside', '3 Outside',
                'Hikkake', 'Hikkake Modified', 'Tasuki Gap', 'Kicking', 'Morning Star', 'Piercing'],
    'bearish': ['Belt Hold', 'Marubozu', 'Long Line', 'Engulfing', '3 Inside', '3 Outside',
                'Hikkake', 'Hikkake Modified', 'Tasuki Gap', 'Kicking', 'Evening Star', 'Dark Cloud Cover']
}

CONTINUATION_PATTERNS = {
    'bullish': ['3 White Soldiers', 'Tasuki Gap', 'Rise 3 Methods', '3 Outside',
                'Side by Side White', '3 Line Strike', 'Mat Hold'],
    'bearish': ['3 Black Crows', 'Tasuki Gap', 'Fall 3 Methods', '3 Inside',
                'Side by Side Black', '3 Line Strike']
}
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)
# ================= CONFIGURATION =================
SYMBOLS          = ["XAUUSDm"]
TIMEFRAME       = mt5.TIMEFRAME_M5
LOT_SIZE        = 0.01
LOOKBACK_BARS   = 200
# Persistent state for pending FVG retracements (one per symbol)
pending_fvgs: Dict[str, Dict] = {}
# Global dictionary to track active FVG monitors
active_monitors: Dict[str, Dict] = {}
monitors_lock = threading.Lock()

# ================= LOGGING =================
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

if not mt5.initialize():
    logger.critical("Failed to initialize MT5.")
    mt5.shutdown()
    sys.exit()
# ================= LIQUIDTY MONITORING =================
def detect_liquidity_grab(df: pd.DataFrame, direction: Literal['bullish', 'bearish']) -> bool:
    """
    Detects a recent liquidity grab (sweep of equal highs/lows followed by reversal).
    Uses the exact smc.liquidity() implementation.
    """
    if len(df) < 100:
        return False

    swings = smc.swing_highs_lows(df)
    liq = smc.liquidity(df, swings, range_percent=0.008)   # tuned for XAUUSD volatility

    recent_liq = liq.iloc[-40:]          # last ~3.3 hours on M5
    current_idx = len(df) - 1

    if direction == 'bullish':
        # Bearish liquidity = grouped lows (buy-side liquidity pool)
        candidates = recent_liq[recent_liq['Liquidity'] == -1]
        for _, row in candidates.iterrows():
            swept = row.get('Swept')
            if pd.notna(swept):
                swept_idx = int(swept)
                if current_idx - 35 <= swept_idx <= current_idx:   # swept within last 35 bars
                    liq_level = row['Level']
                    if df['close'].iloc[-1] > liq_level:
                        logger.info(f"[{df.index[-1]}] Bullish liquidity grab detected (swept buy-side at {liq_level:.5f})")
                        return True

    else:  # bearish
        # Bullish liquidity = grouped highs (sell-side liquidity pool)
        candidates = recent_liq[recent_liq['Liquidity'] == 1]
        for _, row in candidates.iterrows():
            swept = row.get('Swept')
            if pd.notna(swept):
                swept_idx = int(swept)
                if current_idx - 35 <= swept_idx <= current_idx:
                    liq_level = row['Level']
                    if df['close'].iloc[-1] < liq_level:
                        logger.info(f"[{df.index[-1]}] Bearish liquidity grab detected (swept sell-side at {liq_level:.5f})")
                        return True

    return False
def has_matching_pattern(pattern_list: list, direction: str, patterns_str: str) -> bool:
    """Case-sensitive exact match for TA-Lib output strings."""
    prefix = "Bullish " if direction == "bullish" else "Bearish "
    for p in pattern_list:
        if (prefix + p in patterns_str) or (p in patterns_str):
            return True
    return False
# ================= FVG RETRACEMENT MONITORING =================
def monitor_fvg(symbol: str, action: str, fvg_size: List[float]) -> bool:
    """
    Monitor a currency pair for FVG retracement and place a STOP LIMIT order.
    Runs in a separate thread.
    
    Args:
        symbol: Currency pair (e.g., "USDCHF")
        action: "BUY" or "SELL"
        fvg_size: [high, low] representing FVG top and bottom
    
    Returns:
        True if thread started successfully
    """
    if action not in ["BUY", "SELL"]:
        logger.error(f"Invalid action: {action}. Must be 'BUY' or 'SELL'")
        return False
    
    fvg_high, fvg_low = fvg_size
    if fvg_high <= fvg_low:
        logger.error(f"Invalid FVG: high ({fvg_high}) must be > low ({fvg_low})")
        return False
    
    monitor_id = f"{symbol}_{action}_{fvg_high}_{fvg_low}"
    
    with monitors_lock:
        if monitor_id in active_monitors:
            logger.warning(f"Monitor already active for {monitor_id}")
            return False
        
        active_monitors[monitor_id] = {
            "symbol": symbol,
            "action": action,
            "fvg_high": fvg_high,
            "fvg_low": fvg_low,
            "status": "waiting",
            "thread": None
        }
    
    thread = threading.Thread(
        target=_monitor_fvg_worker,
        args=(symbol, action, fvg_high, fvg_low, monitor_id),
        daemon=True
    )
    
    with monitors_lock:
        active_monitors[monitor_id]["thread"] = thread
    
    thread.start()
    logger.info(f"Started FVG monitor for {symbol} ({action})")
    return True

def _monitor_fvg_worker(symbol: str, action: str, fvg_high: float, fvg_low: float, monitor_id: str):
    """Worker thread function to monitor FVG and place orders.
    look for engulfing candles"""
    fvg_range = fvg_high - fvg_low
    half_retrace = fvg_range / 2
    validated = False
    timeout_counter = 0
    max_timeout = 1440  # 72 minutes hours at 3-second intervals
   #to do wait for engulfing candles for entries 
    try:
        while timeout_counter < max_timeout:
            tick = mt5.symbol_info_tick(symbol)
            if tick is None:
                logger.warning(f"Failed to get tick for {symbol}")
                timeout_counter += 1
                time.sleep(3)
                continue
            
            current_price = tick.bid if action == "SELL" else tick.ask
            
            # Check retracement condition
            if action == "BUY":
                retracted = current_price <= (fvg_high - half_retrace)
            else:  # SELL
                retracted = current_price >= (fvg_low + half_retrace)
            
            if retracted and not validated:
                # Fetch latest candle to validate close within FVG
                rates = mt5.copy_rates_from_pos(symbol, TIMEFRAME, 0, 1)
                if rates is not None and len(rates) > 0:
                    close_price = rates[0]['close']
                    if fvg_low <= close_price <= fvg_high:
                        validated = True
                        with monitors_lock:
                            active_monitors[monitor_id]["status"] = "validated"
                        logger.info(f"{symbol} FVG {action} setup validated at {current_price:.5f}")
            
            # Place order if validated
            if validated:
                if action == "BUY":
                    order_placed = _place_buy_stop_limit(symbol, fvg_high, fvg_low)
                else:
                    order_placed = _place_sell_stop_limit(symbol, fvg_high, fvg_low)
                
                if order_placed:
                    with monitors_lock:
                        active_monitors[monitor_id]["status"] = "order_placed"
                    break
            
            timeout_counter += 1
            time.sleep(5)
        
        if timeout_counter >= max_timeout:
            logger.warning(f"Monitor {monitor_id} timed out")
            with monitors_lock:
                active_monitors[monitor_id]["status"] = "timeout"
    
    except Exception as e:
        logger.error(f"Error in FVG monitor for {symbol}: {e}")
        with monitors_lock:
            active_monitors[monitor_id]["status"] = "error"
    
    finally:
        with monitors_lock:
            if monitor_id in active_monitors:
                active_monitors[monitor_id]["thread"] = None

def _place_buy_stop(symbol: str, fvg_high: float, fvg_low: float) -> bool:
    """Place a BUY STOP LIMIT order at FVG high."""
    try:
        request = {
            "action": mt5.TRADE_ACTION_PENDING,
            "symbol": symbol,
            "volume": LOT_SIZE,
            "type": mt5.ORDER_TYPE_BUY_STOP,
            "price": fvg_high,
            "stoplimit": fvg_high,
            "magic": 123456,
            "comment": "FVG Stop Limit Buy",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        result = mt5.order_send(request)
        if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
            logger.info(f"BUY STOP  placed for {symbol} at {fvg_high:.5f}")
            return True
        else:
            rc = getattr(result, "retcode", None)
            logger.error(f"Failed to place BUY STOP LIMIT: {retcodedes(rc)}")
            return False
    except Exception as e:
        logger.error(f"Error placing BUY order for {symbol}: {e}")
        return False

def _place_sell_stop(symbol: str, fvg_high: float, fvg_low: float) -> bool:
    """Place a SELL STOP LIMIT order at FVG low."""
    try:
        request = {
            "action": mt5.TRADE_ACTION_PENDING,
            "symbol": symbol,
            "volume": LOT_SIZE,
            "type": mt5.ORDER_TYPE_SELL_STOP,
            "price": fvg_low,
            "stoplimit": fvg_low,
            "magic": 123456,
            "comment": "FVG Stop Limit Sell",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        result = mt5.order_send(request)
        if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
            logger.info(f"SELL STOP placed for {symbol} at {fvg_low:.5f}")
            return True
        else:
            rc = getattr(result, "retcode", None)
            logger.error(f"Failed to place SELL STOP LIMIT: {retcodedes(rc)}")
            return False
    except Exception as e:
        logger.error(f"Error placing SELL order for {symbol}: {e}")
        return False

def get_active_monitors() -> List[Dict]:
    """Return list of currently active FVG monitors."""
    with monitors_lock:
        return [
            {
                "id": monitor_id,
                "symbol": m["symbol"],
                "action": m["action"],
                "status": m["status"],
                "fvg": [m["fvg_high"], m["fvg_low"]]
            }
            for monitor_id, m in active_monitors.items()
            if m["thread"] is not None and m["thread"].is_alive()
        ]
# ================= DATA FETCH =================
def fetch_ohlcv(symbol, timeframe, count=100) -> Optional[pd.DataFrame]:
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None:
        print(colored("Failed to fetch data.", 'red'))
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df[['time', 'open', 'high', 'low', 'close', 'tick_volume']]
    df=df.rename(columns={"tick_volume": "volume"})
    df.set_index('time', inplace=True)
    return df
# ================= MAIN LOGIC =================
def main(symbols: List[str]):
    for symbol in symbols:
        logger.info(f"[{symbol}] Analysing...")

        df = fetch_ohlcv(symbol, TIMEFRAME, LOOKBACK_BARS)
        if df is None or len(df) < 120:
            continue

        signal = smma_strategy(df)
        signal_row = signal.iloc[-2]          # last closed bar
        current_price = df['close'].iloc[-1]

        fvg = smc.fvg(df, join_consecutive=True)

        # ================= LONG SIGNAL =================
        if signal_row.get('long_entry', False):

            # 1. Direct unmitigated bullish FVG below price → threaded monitor
            bull_fvgs = fvg[
                (fvg['FVG'] == 1) &
                (fvg['MitigatedIndex'] == 0) &
                (fvg['Top'] < current_price)
            ]
            if not bull_fvgs.empty:
                last_fvg = bull_fvgs.iloc[-1]
                fvg_zone = [float(last_fvg['Top']), float(last_fvg['Bottom'])]
                if monitor_fvg(symbol, "BUY", fvg_zone):
                    logger.info(f"[{symbol}] SMMA long + bullish FVG behind price → monitor started (Method: FVG retracement)")
                continue

            # 2. FVG-forming pattern in last 12 candles
            pattern_df = pr.detect_candlestick_patterns(df.copy())
            recent = pattern_df.iloc[-12:]
            patterns_str = ' '.join([
                str(recent['single_candle_patterns'].fillna('')),
                str(recent['two_candle_patterns'].fillna('')),
                str(recent['three_plus_candle_patterns'].fillna(''))
            ])

            if has_matching_pattern(FVG_FORMING_PATTERNS['bullish'], 'bullish', patterns_str):
                logger.info(f"[{symbol}] SMMA long + FVG-forming pattern detected → waiting for new FVG formation")
                continue   # next 5-min cycle will catch the newly created FVG

            # 3. Liquidity grab confluence
            if detect_liquidity_grab(df, 'bullish'):
                logger.info(f"[{symbol}] SMMA long + liquidity grab confluence → standard entry")
                try:
                    d.place_buy_orders(LOT_SIZE, 1, symbol)
                    logger.info(f"[{symbol}] Trade executed (Method: standard triple SMMA + liquidity grab)")
                except Exception as e:
                    logger.error(f"[{symbol}] Standard buy failed: {e}")
                continue

            # 4. Continuation pattern (fallback)
            if has_matching_pattern(CONTINUATION_PATTERNS['bullish'], 'bullish', patterns_str):
                logger.info(f"[{symbol}] SMMA long + continuation pattern → standard entry")
                try:
                    d.place_buy_orders(LOT_SIZE, 1, symbol)
                    logger.info(f"[{symbol}] Trade executed (Method: standard triple SMMA + continuation pattern)")
                except Exception as e:
                    logger.error(f"[{symbol}] Standard buy failed: {e}")
                continue

            logger.info(f"[{symbol}] SMMA long signal – no FVG / pattern / liquidity grab confluence → skipped")

        # ================= SHORT SIGNAL (symmetric) =================
        elif signal_row.get('short_entry', False):

            bear_fvgs = fvg[
                (fvg['FVG'] == -1) &
                (fvg['MitigatedIndex'] == 0) &
                (fvg['Bottom'] > current_price)
            ]
            if not bear_fvgs.empty:
                last_fvg = bear_fvgs.iloc[-1]
                fvg_zone = [float(last_fvg['Top']), float(last_fvg['Bottom'])]
                if monitor_fvg(symbol, "SELL", fvg_zone):
                    logger.info(f"[{symbol}] SMMA short + bearish FVG above price → monitor started (Method: FVG retracement)")
                continue

            pattern_df = pr.detect_candlestick_patterns(df.copy())
            recent = pattern_df.iloc[-12:]
            patterns_str = ' '.join([
                str(recent['single_candle_patterns'].fillna('')),
                str(recent['two_candle_patterns'].fillna('')),
                str(recent['three_plus_candle_patterns'].fillna(''))
            ])

            if has_matching_pattern(FVG_FORMING_PATTERNS['bearish'], 'bearish', patterns_str):
                logger.info(f"[{symbol}] SMMA short + FVG-forming pattern detected → waiting for new FVG formation")
                continue

            if detect_liquidity_grab(df, 'bearish'):
                logger.info(f"[{symbol}] SMMA short + liquidity grab confluence → standard entry")
                try:
                    d.place_sell_orders(LOT_SIZE, 1, symbol)
                    logger.info(f"[{symbol}] Trade executed (Method: standard triple SMMA + liquidity grab)")
                except Exception as e:
                    logger.error(f"[{symbol}] Standard sell failed: {e}")
                continue

            if has_matching_pattern(CONTINUATION_PATTERNS['bearish'], 'bearish', patterns_str):
                logger.info(f"[{symbol}] SMMA short + continuation pattern → standard entry")
                try:
                    d.place_sell_orders(LOT_SIZE, 1, symbol)
                    logger.info(f"[{symbol}] Trade executed (Method: standard triple SMMA + continuation pattern)")
                except Exception as e:
                    logger.error(f"[{symbol}] Standard sell failed: {e}")
                continue

            logger.info(f"[{symbol}] SMMA short signal – no FVG / pattern / liquidity grab confluence → skipped")

        # Optional status
        active = get_active_monitors()
        if active:
            logger.info(f"Active FVG monitors: {len(active)}")

# ================= MAIN LOOP =================
if __name__ == "__main__":
    try:
        while True:
            positions = am.get_active_trades()
            pos_count = 0 if positions is None else len(positions.index)

            if pos_count <= 3:
                logger.info(f"({pos_count} open positions) – running analysis.")
                main(SYMBOLS)
            else:
                logger.info("Maximum open positions reached – no new entries.")

            sleeper(300)   # 5 minutes

    except KeyboardInterrupt:
        logger.info("Shutting down SMMA + FVG bot.")
        mt5.shutdown()
    except Exception as e:
        logger.critical(f"Unhandled exception: {e}")
        mt5.shutdown()