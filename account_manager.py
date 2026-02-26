import MetaTrader5 as mt5
import pandas as pd
import logging
from typing import Optional
# === SETUP LOGGING ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

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
            #logger.info(f"No active positions{' for ' + symbol if symbol else ''}")
            return None

        # Convert MT5 position objects to list of dicts and build DataFrame
        rows = [p._asdict() for p in positions]
        df = pd.DataFrame(rows)

        # Convert any epoch time columns to datetime where appropriate
        for col in df.columns:
            if "time" in col and pd.api.types.is_integer_dtype(df[col].dtype):
                try:
                    df[col] = pd.to_datetime(df[col], unit="s", errors="coerce")
                except Exception:
                    # ignore conversion errors and leave original values
                    pass

         # logger.info(f"Retrieved {len(df)} active position(s){' for ' + symbol if symbol else ''}")
        return df
    except Exception as e:
        logger.error(f"Error while fetching active trades: {e}")
        return None
