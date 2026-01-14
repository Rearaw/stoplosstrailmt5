
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
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)
# ================= CONFIGURATION =================
SYMBOLS          = ["XAUUSDm", "USDJPYm","XAGUSDm","USOILm","GBPUSDm","EURUSDm","USDCHFm","USDCADm","AUDUSDm","NZDUSDm","GBPJPYm","EURJPYm",]
TIMEFRAME       = mt5.TIMEFRAME_M15
LOT_SIZE        = 0.01
SL_PIPS         = 25
TP_PIPS         = 50
LOOKBACK_BARS   = 300
MIN_FVG_SIZE    = 0.00015                   # minimum gap size in price units (filter noise)

# For bullish FVG retracement: we want price to come back down to the FVG zone
# For bearish FVG retracement: we want price to come back up to the FVG zone

# ================= HELPERS =================
# Initialize MT5 connection
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
def check_for_fvg_retracement_trade(OHLC,symbol):
    
    if OHLC is None:
        mt5.shutdown()
        exit()
    logger.info(f"checking for FVG retracement trade setups on {symbol}...")
    fvg = smc.fvg(OHLC, join_consecutive=True)  # Fair Value Gaps

    # Get the most recent valid (non-mitigated) FVG
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
    bid = mt5.symbol_info_tick(SYMBOL).bid
    ask = mt5.symbol_info_tick(SYMBOL).ask

    # ==============================================
    # BULLISH FVG RETRACEMENT SETUP (Long)
    # Price is above FVG → expect pullback into bullish FVG
    # ==============================================
    if fvg_type == 1:  # Bullish FVG
        if ask > top:  # price is above the FVG
            zone_mid = (top + bottom) / 2
            
            # Price has retraced into/near the FVG zone
            if bottom <= current_price <= top + (top - bottom)*0.3:  # loose condition - up to 30% above top
                
                logger.info(f"Bullish FVG retracement detected | Zone: {bottom:.5f} - {top:.5f}")
                
                # Place BUY order
                try:
                    request = {
                        "action": mt5.TRADE_ACTION_DEAL,
                        "symbol": SYMBOL,
                        "volume": LOT_SIZE,
                        "type": mt5.ORDER_TYPE_BUY,
                        "price": mt5.symbol_info_tick(SYMBOL).ask,
                        "deviation": 10,
                        "magic": 123456,
                        "comment": "FVG Retracement Long",
                        "type_time": mt5.ORDER_TIME_GTC,
                        "type_filling": mt5.ORDER_FILLING_IOC,
                    }
                    
                    result = mt5.order_send(request)
                    ts = datetime.now().strftime("%H:%M:%S")
                    if result and getattr(result, "retcode", None) == mt5.TRADE_RETCODE_DONE:
                        logger.info(f"{ts} - order was Successfully placed")
                    else:
                        rc = getattr(result, "retcode", None)
                        logger.error(f"{ts} - Failed to BUY, {retcodedes(rc)}")
                except Exception as e:
                    ts = datetime.now().strftime("%H:%M:%S")
                    logger.append(f"{ts} - Error placing BUY orders: {e}")

    # ==============================================
    # BEARISH FVG RETRACEMENT SETUP (Short)
    # Price is below FVG → expect rally into bearish FVG
    # ==============================================
    elif fvg_type == -1:  # Bearish FVG
        if ask < bottom:  # price is below the FVG
            
            # Price has retraced into/near the FVG zone
            if top >= current_price >= bottom - (top - bottom)*0.3:  # up to 30% below bottom
                
                logger.info(f" Bearish FVG retracement detected | Zone: {bottom:.5f} - {top:.5f}")
                try:    
                    # Place SELL order
                    request = {
                        "action": mt5.TRADE_ACTION_DEAL,
                        "symbol": SYMBOL,
                        "volume": LOT_SIZE,
                        "type": mt5.ORDER_TYPE_SELL,
                        "price": mt5.symbol_info_tick(SYMBOL).bid,
                        "deviation": 10,
                        "magic": 123456,
                        "comment": "FVG Retracement Short",
                        "type_time": mt5.ORDER_TIME_GTC,
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
    return False
while True:
    positions=am.get_active_trades()
    logger.info(f"({len(positions.index)} positions currently open)")
    if len(positions.index) <= 3:
        for SYMBOL in SYMBOLS:
            if SYMBOL not in positions['symbol'].values:
                OHLC = fetch_ohlc(SYMBOL, TIMEFRAME, LOOKBACK_BARS)
                check_for_fvg_retracement_trade(OHLC, SYMBOL)
    logger.info(f"sleeping for 60 seconds...")
    time.sleep(60)


mt5.shutdown()