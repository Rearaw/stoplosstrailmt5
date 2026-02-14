import MetaTrader5 as mt5
import pandas as pd
import numpy as np
#import time
#import threading
from typing import Dict, List, Tuple, Literal, Optional
from termcolor import colored
import pandas_ta as pta
import account_manager as am #get open positions
import logging
import time
from datetime import datetime
import mplfinance as mpf
from scipy.signal import find_peaks
from scipy.stats import linregress
from strategies.smma_mt5_strategy import smma
from strategies.smma_mt5_strategy import triple_smma_stateful_strategy as smma_strategy
import pattern_recognition as pr
import talib as ta
import deal as d
import colorama
from colorama import Fore, Style, init
colorama.init()
from sleeper import sleeper
init(autoreset=True)
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)
# ================= CONFIGURATION =================
SYMBOLS          = ["XAUUSDm"]
TIMEFRAME       = mt5.TIMEFRAME_M5
LOT_SIZE        = 0.01
LOOKBACK_BARS   = 200
def peak_detection(close: pd.Series, distance: int = 10, prominence: float = 0.01) -> Tuple[np.ndarray, np.ndarray]:
    """
    Detects peaks and troughs in a Close price series using scipy.signal.find_peaks.
    
    Parameters
    ----------
    close : pd.Series
        Series of closing prices (indexed, preferably with DatetimeIndex).
    distance : int
        Minimum distance between detected peaks/troughs.
    prominence : float
        Minimum prominence required for a peak/trough to be considered significant.
    
    Returns
    -------
    peaks : np.ndarray
        Indices of detected peaks.
    troughs : np.ndarray
        Indices of detected troughs.
    """
    #close.to_numpy()
    high=close["high"]
    low=close["low"]
    close_array =high.to_numpy()
    low_array=low.to_numpy()
    peaks, _ = find_peaks(close_array, distance=distance, prominence=prominence)
    troughs, _ = find_peaks(-low_array, distance=distance, prominence=prominence)
    return peaks, troughs
if not mt5.initialize():
    print("Failed to initialize MT5.")
    mt5.shutdown()
    exit()
class indicators:
    def __init__(self):
        pass
    def smma(self, df: pd.DataFrame) -> pd.DataFrame:
        close = df['close']
        df["long_ma"] =smma(close, length=100)#find sell signals when on top of short_ma
        df["medium_ma"] =smma(close, length=50)
        df["short_ma"] =smma(close, length=10)#find buy signals if on top of both long_ma
        return df
    def RSI(self, df: pd.DataFrame, length: int = 14) -> pd.DataFrame:
        df['RSI'] = pta.rsi(df['close'], length=length)
        return df
    def VWAP(self, df: pd.DataFrame) -> pd.DataFrame:
        df["VWAP"]=pta.vwap(df.high, df.low, df.close, df.volume)
        return df
    def BBANDS(self, df: pd.DataFrame, length: int = 20, std_dev: float = 2.50) -> pd.DataFrame:
        bbandu=smma(df['close'], length=length)+ta.STDDEV(df['close'], timeperiod=length, nbdev=std_dev)
        bbandd=smma(df['close'], length=length)-ta.STDDEV(df['close'], timeperiod=length, nbdev=std_dev)
        df['BB_upper'] = bbandu
        #df['BB_middle'] = ta.SMA(df['close'], timeperiod=length, nbdevup=std_dev, nbdevdn=1.4, matype=0)
        df['BB_lower'] = bbandd
        return df
def continuation_patterns(df: pd.DataFrame) -> pd.DataFrame:
    pass
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




def main(symbols: List[str]):
    for symbol in SYMBOLS:
        print(colored(f"Analyzing {symbol}...", 'cyan'))
        df_ohlcv = fetch_ohlcv(symbol, TIMEFRAME, LOOKBACK_BARS)
    signal=smma_strategy(df_ohlcv,)
    current= signal.iloc[-2] # Use second-to-last row to avoid lookahead bias
    if current['long_entry']:
        logger.info(colored(f"Long entry signal detected for {symbol}", 'green'))
        d.place_buy_orders(LOT_SIZE, 1, symbol)
    elif current['short_entry']:
        logger.info(colored(f"Short entry signal detected for {symbol}", 'red'))
        d.place_sell_orders(LOT_SIZE, 1, symbol)
    else:
        logger.info(colored(f"No entry signal detected for {symbol}", 'yellow'))
    return

def main2(symbols: List[str]):
    for symbol in SYMBOLS:
        print(colored(f"Analyzing {symbol}...", 'cyan'))
        df_ohlcv = fetch_ohlcv(symbol, TIMEFRAME, LOOKBACK_BARS)
    indicator = indicators()
    signal=smma_strategy(df_ohlcv,)
    results=pr.detect_candlestick_patterns(df_ohlcv)
    df_ohlcv = indicator.smma(df_ohlcv)
    df_ohlcv = indicator.RSI(df_ohlcv)
    df_ohlcv = indicator.VWAP(df_ohlcv)
    df_ohlcv = indicator.BBANDS(df_ohlcv)
    smma_plot = mpf.make_addplot(df_ohlcv['long_ma'], color='red', linestyle='-')
    sma_plot = mpf.make_addplot(df_ohlcv['short_ma'], color='green', linestyle='-')
    vwap_plot = mpf.make_addplot(df_ohlcv['VWAP'], color='magenta', linestyle='-')
    upper_band = mpf.make_addplot(df_ohlcv['BB_upper'], color='red', linestyle='--')
    #middle_band = mpf.make_addplot(df_ohlcv['BB_middle'], color='orange', linestyle='-')
    lower_band = mpf.make_addplot(df_ohlcv['BB_lower'], color='green', linestyle='--')
    
    
    add_plots = [smma_plot,sma_plot,vwap_plot,upper_band,lower_band]
    mpf.plot(
    df_ohlcv,
    type='candle',
    style='charles',          # Alternatives: 'charles', 'binance', 'blueskies', etc.
    addplot=add_plots,
    volume=True,            # Includes volume panel below price
    title='OHLCV Chart with SMMA, VWAP, and RSI',
    ylabel='Price',
    #panel_ratios=(4, 1, 2), # Price panel largest, volume small, RSI medium
    figsize=(14, 10),
    tight_layout=True
)


if __name__ == "__main__":
    try:
        while True:
            positions=am.get_active_trades()
            if positions is None:
                logger.info(colored(f"(no positions currently open)", 'yellow'))
                main(SYMBOLS)
            elif len(positions.index) <= 3:
                logger.info(colored(f"({len(positions.index)} positions currently open)", 'yellow'))
                main(SYMBOLS)

            else:      
                logger.info(colored("Maximum number of open positions reached. No new trades will be initiated.", 'red'))
                main(SYMBOLS)
            sleeper(300) # Check every 5 minutes
    except KeyboardInterrupt:
        logger.info("Stopping smma monitoring...")
        mt5.shutdown()