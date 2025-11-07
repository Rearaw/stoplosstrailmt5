import sys
from PySide6.QtWidgets import QApplication, QMainWindow, QPushButton, QVBoxLayout, QWidget, QLineEdit, QLabel
import MetaTrader5 as mt5
from PySide6.QtWidgets import QComboBox, QMessageBox
from PySide6.QtWidgets import QTextEdit, QCompleter
from PySide6.QtCore import Qt, QTimer, QStringListModel
from datetime import datetime
from PySide6.QtWidgets import QSpinBox
from return_codes import retcodedes

class TradingApp(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Trading Bot")
        self.setGeometry(100, 100, 300, 400)

        # Create central widget and layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)

        # Create input fields (lot size first, currency pair below, then number of orders)
        self.lot_size_input = self.create_input_field("Lot Size:", layout)
        self.lot_size_input.setText("0.01")
        self.currency_input = self.create_input_field("Currency Pair:", layout)
        self.num_orders_input = QSpinBox()
        self.num_orders_input.setRange(1, 10)
        self.num_orders_input.setValue(1)
        # keep compatibility with existing setText("1") call elsewhere
        def _setText(txt):
            try:
                self.num_orders_input.setValue(int(txt))
            except Exception:
             pass
        self.num_orders_input.setText = _setText
        layout.addWidget(QLabel("Number of Orders:"))
        layout.addWidget(self.num_orders_input)
        self.num_orders_input.setText("1")

        # Local imports for completer and logger

        # Logger below inputs
        self.logger = QTextEdit()
        self.logger.setReadOnly(True)
        self.logger.setMinimumHeight(120)
        layout.addWidget(self.logger)

        def log(msg, level="INFO"):
            ts = datetime.now().strftime("%H:%M:%S")
            self.logger.append(f"[{level}] {ts} - {msg}")

        # Setup completer for currency input (filters as the user types)
        self._symbols_model = QStringListModel()
        self._completer = QCompleter(self._symbols_model, self)
        self._completer.setCaseSensitivity(Qt.CaseInsensitive)
        try:
            # Some PySide6 versions require setFilterMode on the completer's model
            self._completer.setFilterMode(Qt.MatchContains)
        except Exception:
            pass
        self._completer.setCompletionMode(QCompleter.PopupCompletion)
        self.currency_input.setCompleter(self._completer)

        # Refresh button to load available pairs from MT5
        refresh_button = QPushButton("Refresh Pairs")
        layout.addWidget(refresh_button)
        def log(msg, level="INFO"):
            ts = datetime.now().strftime("%H:%M:%S")
            self.logger.append(f"[{level}] {ts} - {msg}")
        def populate_symbols():
            try:
                if not mt5.initialize():
                    log("MetaTrader5 initialization failed", "ERROR")
                    QMessageBox.warning(self, "MT5 Error", "MetaTrader5 initialization failed")
                    return
                symbols = mt5.symbols_get()
                if not symbols:
                    self._symbols_model.setStringList([])
                    log("No symbols found", "WARN")
                    return
                names = []
                for s in symbols:
                    name = getattr(s, "name", None) or getattr(s, "symbol", None) or str(s)
                    names.append(name)
                names = sorted(set(names))
                self._symbols_model.setStringList(names)
                log(f"Loaded {len(names)} symbols")
                if not self.currency_input.text() and names:
                    self.currency_input.setText(names[0])
            except Exception as e:
                log(f"Error populating symbols: {e}", "ERROR")

        refresh_button.clicked.connect(populate_symbols)

        # Style buy/sell buttons after they are created (they are created after this placeholder)
        def style_trade_buttons():
            for btn in self.findChildren(QPushButton):
                text = (btn.text() or "").strip().lower()
                btn.setMinimumHeight(48)
                base_style = "font-size:16px; padding:8px; border-radius:6px;"
                if text == "buy":
                    btn.setStyleSheet(base_style + "background-color:#28a745; color:white; font-weight:bold;")
                elif text == "sell":
                    btn.setStyleSheet(base_style + "background-color:#dc3545; color:white; font-weight:bold;")
                else:
                    btn.setStyleSheet(base_style)

        # Call styling shortly after UI creation to catch later-created buttons
        QTimer.singleShot(100, style_trade_buttons)

        # Initial population of symbols
        populate_symbols()
        # Create buttons
        buy_button = QPushButton("Buy")
        sell_button = QPushButton("Sell")
        
        # Connect buttons to functions
        buy_button.clicked.connect(self.place_buy_orders)
        sell_button.clicked.connect(self.place_sell_orders)

        # Add buttons to layout
        layout.addWidget(buy_button)
        layout.addWidget(sell_button)

        # Initialize MT5
        if not mt5.initialize():
            print("MetaTrader5 initialization failed")

    def create_input_field(self, label_text, layout):
        label = QLabel(label_text)
        input_field = QLineEdit()
        layout.addWidget(label)
        layout.addWidget(input_field)
        return input_field

    def place_buy_orders(self):
        try:
            lot_size = float(self.lot_size_input.text())
            num_orders = int(self.num_orders_input.text())
            symbol = self.currency_input.text()

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
                    self.logger.append(f"[INFO] {ts} - order was Successfully placed")
                else:
                    rc = getattr(result, "retcode", None)
                    self.logger.append(f"[ERROR] {ts} - Failed to BUY, {retcodedes(rc)}")
        except Exception as e:
            ts = datetime.now().strftime("%H:%M:%S")
            self.logger.append(f"[ERROR] {ts} - Error placing BUY orders: {e}")

    def place_sell_orders(self):
        try:
            lot_size = float(self.lot_size_input.text())
            num_orders = int(self.num_orders_input.text())
            symbol = self.currency_input.text()

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
                    self.logger.append(f"[INFO] {ts} - order was Successfully placed")
                else:
                    rc = getattr(result, "retcode", None)
                    self.logger.append(f"[ERROR] {ts} - Failed to SELL, {retcodedes(rc)}")
        except Exception as e:
            ts = datetime.now().strftime("%H:%M:%S")
            self.logger.append(f"[ERROR] {ts} - Error placing SELL orders: {e}")

    def closeEvent(self, event):
        mt5.shutdown()
        event.accept()

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = TradingApp()
    window.show()
    sys.exit(app.exec())