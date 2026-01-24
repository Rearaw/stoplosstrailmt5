
import sys
import os.path
sys.path.append(os.path.abspath(os.path.expanduser("~/smart-money-concepts/")))
import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime
import logging
from typing import Literal, Optional, Dict, List
from return_codes import retcodedes
from smartmoneyconcepts import smc
import account_manager as am
import time
import threading
from typing import Dict, List, Tuple
from termcolor import colored
import colorama
colorama.init()
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)
# ================= CONFIGURATION =================
SYMBOLS          = ["XAUUSDm", "USDJPYm","XAGUSDm","USOILm","GBPUSDm","EURUSDm","USDCHFm","USDCADm","AUDUSDm","NZDUSDm","GBPJPYm","EURJPYm",]
TIMEFRAME       = mt5.TIMEFRAME_M15
LOT_SIZE        = 0.01
LOOKBACK_BARS   = 300

if not mt5.initialize():
    print("Failed to initialize MT5.")
    mt5.shutdown()
    exit()
# Function to fetch OHLC data from MT5
def fetch_ohlc(symbol, timeframe, count=500) -> Optional[pd.DataFrame]:
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None:
        print("Failed to fetch data.")
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df[['time', 'open', 'high', 'low', 'close', 'tick_volume']]
    df.set_index('time', inplace=True)
    return df

              
# ================= MAIN TRADING LOGIC =================
def check_for_fvg_retracement_trade(OHLC,symbol,currentFVG=False):
    
    if OHLC is None:
        return False
    logger.info(f"checking for FVG retracement trade setups on {symbol}...")
    fvg = smc.fvg(OHLC, join_consecutive=True)  # Fair Value Gaps
    if not currentFVG:
        fvg = fvg.iloc[:-2]  # Remove the last row# Get the most recent valid (non-mitigated) FVG
    valid_fvgs = fvg[~fvg['FVG'].isna() & (fvg['MitigatedIndex'] == 0)]
    
    valid_fvgs = valid_fvgs[valid_fvgs.index != OHLC.index[-1]]

    if valid_fvgs.empty:
        return False

    logger.info(f"found {len(valid_fvgs)} valid FVGs for {symbol}")
    last_fvg = valid_fvgs.iloc[-1]
    fvg_type = last_fvg['FVG']      # 1 = bullish, -1 = bearish
    top      = last_fvg['Top']
    bottom   = last_fvg['Bottom']
    current_price = OHLC['close'].iloc[-1]
    bid = mt5.symbol_info_tick(symbol).bid
    ask = mt5.symbol_info_tick(symbol).ask

    # ==============================================
    # BULLISH FVG RETRACEMENT SETUP (Long)
    # Price is above FVG → expect pullback into bullish FVG
    # ==============================================

    if fvg_type == 1:  # Bullish FVG
        if ask > top:  # price is above the FVG
            zone_mid = (top + bottom) / 2
            #monitor_fvg(symbol, "BUY", [top, bottom])
            # Price has retraced into/near the FVG zone
            if bottom <= current_price <= top + (top - bottom)*0.3:  # loose condition - up to 30% above top

                logger.info(colored(f"Bullish FVG retracement detected | Zone: {bottom:.5f} - {top:.5f}", 'green'))

                # # Place BUY order
                try:
                    monitor_fvg(symbol, "BUY", [top, bottom])
                
                #     request = {
                #         "action": mt5.TRADE_ACTION_DEAL,
                #         "symbol": SYMBOL,
                #         "volume": LOT_SIZE,
                #         "type": mt5.ORDER_TYPE_BUY,
                #         "price": mt5.symbol_info_tick(SYMBOL).ask,
                #         "deviation": 10,
                #         "magic": 123456,
                #         "comment": "FVG Retracement Long",
                #         "type_time": mt5.ORDER_TIME_GTC,
                #         "type_filling": mt5.ORDER_FILLING_IOC,
                #     }
                    
                #     result = mt5.order_send(request)
                #     ts = datetime.now().strftime("%H:%M:%S")
                #     if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
                #         logger.info(f"{ts} - order was Successfully placed")
                #     else:
                #         rc = getattr(result, "retcode", None)
                #         logger.error(f"{ts} - Failed to BUY, {retcodedes(rc)}")
                except Exception as e:
                    ts = datetime.now().strftime("%H:%M:%S")
                    logger.append(f"{ts} - Error placing BUY orders: {e}")

    # ==============================================
    # BEARISH FVG RETRACEMENT SETUP (Short)
    # Price is below FVG → expect rally into bearish FVG
    # ==============================================
    elif fvg_type == -1:  # Bearish FVG
        if ask < bottom:  # price is below the FVG
            #monitor_fvg(symbol, "SELL", [bottom, top])
            # Price has retraced into/near the FVG zone
            if top >= current_price >= bottom - (top - bottom)*0.3:  # up to 30% below bottom

                logger.info(colored(f" Bearish FVG retracement detected | Zone: {bottom:.5f} - {top:.5f}", 'red'))
                try:
                    monitor_fvg(symbol, "SELL", [top, bottom])
                    # Place SELL order
                    # request = {
                    #     "action": mt5.TRADE_ACTION_DEAL,
                    #     "symbol": SYMBOL,
                    #     "volume": LOT_SIZE,
                    #     "type": mt5.ORDER_TYPE_SELL,
                    #     "price": mt5.symbol_info_tick(SYMBOL).bid,
                    #     "deviation": 10,
                    #     "magic": 123456,
                    #     "comment": "FVG Retracement Short",
                    #     "type_time": mt5.ORDER_TIME_GTC,
                    #     "type_filling": mt5.ORDER_FILLING_IOC,
                    # }
                    # result = mt5.order_send(request)
                    # ts = datetime.now().strftime("%H:%M:%S")
                    # if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
                    #     logger.info(f"[INFO] {ts} - order was Successfully placed")
                    # else:
                    #     rc = getattr(result, "retcode", None)
                    #     logger.error(f"[ERROR] {ts} - Failed to BUY, {retcodedes(rc)}")
                except Exception as e:
                    ts = datetime.now().strftime("%H:%M:%S")
                    logger.append(f"[ERROR] {ts} - Error placing BUY orders: {e}")
    return False
# Global dictionary to track active FVG monitors
active_monitors: Dict[str, Dict] = {}
monitors_lock = threading.Lock()

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
    """Worker thread function to monitor FVG and place orders."""
    fvg_range = fvg_high - fvg_low
    half_retrace = fvg_range / 2
    validated = False
    timeout_counter = 0
    max_timeout = 1440  # 72 minutes hours at 3-second intervals
    
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

def _place_buy_stop_limit(symbol: str, fvg_high: float, fvg_low: float) -> bool:
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
            logger.info(f"BUY STOP LIMIT placed for {symbol} at {fvg_high:.5f}")
            return True
        else:
            rc = getattr(result, "retcode", None)
            logger.error(f"Failed to place BUY STOP LIMIT: {retcodedes(rc)}")
            return False
    except Exception as e:
        logger.error(f"Error placing BUY order for {symbol}: {e}")
        return False

def _place_sell_stop_limit(symbol: str, fvg_high: float, fvg_low: float) -> bool:
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
            logger.info(f"SELL STOP LIMIT placed for {symbol} at {fvg_low:.5f}")
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
try:
    while True:
        positions=am.get_active_trades()
        if positions is not None:
            logger.info(colored(f"({len(positions.index)} positions currently open)", 'yellow'))
            if len(positions.index) <= 3:
                for SYMBOL in SYMBOLS:
                    if SYMBOL not in positions['symbol'].values:
                        OHLC = fetch_ohlc(SYMBOL, TIMEFRAME, LOOKBACK_BARS)
                        check_for_fvg_retracement_trade(OHLC, SYMBOL)
        else:
            logger.info(colored(f"(no positions currently open)", 'yellow'))
            for SYMBOL in SYMBOLS:
                OHLC = fetch_ohlc(SYMBOL, TIMEFRAME, LOOKBACK_BARS)
                check_for_fvg_retracement_trade(OHLC, SYMBOL, currentFVG=True)
        logger.info(f"sleeping for 60 seconds...")

        time.sleep(60)
        active = get_active_monitors()
        if active:
            logger.info(f"Currently {len(active)} active FVG monitors")
            for m in active:
                logger.info(colored(f"  • {m['id']}  →  {m['status']}", 'yellow'))
except KeyboardInterrupt:
    logger.info("Stopping FVG monitoring...")
finally:
    mt5.shutdown()


