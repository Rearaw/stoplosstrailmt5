from typing import Dict, List, Tuple, Literal, Optional
import MetaTrader5 as mt5
from datetime import datetime
from colorama import init, Fore, Style
init(autoreset=True)
if not mt5.initialize():
    print("Failed to initialize MT5.")
    mt5.shutdown()
    exit()
import logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def place_buy_orders(lot_size: float, num_orders: int, symbol: str ):
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
                color = Fore.GREEN
                logger.info(f"[INFO] {color}{ts} - order was Successfully placed")
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
                color = Fore.RED
                logger.info(f"[INFO] {color}{ts} - order was Successfully placed")
            else:
                rc = getattr(result, "retcode", None)
                logger.error(f"[ERROR] {ts} - Failed to SELL, {retcodedes(rc)}")
    except Exception as e:
        ts = datetime.now().strftime("%H:%M:%S")
        logger.append(f"[ERROR] {ts} - Error placing SELL orders: {e}")

