"""
TDS Sensor Driver for Raspberry Pi Pico W
Reads TDS (Total Dissolved Solids) from analog TDS meter shields
"""

import machine
import time
import sys

# Import configuration
try:
    import tds_config
except ImportError:
    # Fallback if config not available (when running directly)
    print("Warning: Using default configuration")
    class tds_config:
        ADC_PIN = 26
        TDS_CALIBRATION_FACTOR = 0.5
        READ_INTERVAL = 1.0
        SAMPLE_COUNT = 10
        ADC_RESOLUTION = 65535
        VREF = 3.3
        OUTPUT_MAX_VOLTAGE = 2.5
        TDS_MAX_PPM = 1000
        USE_TEMP_COMPENSATION = False
        TEMP_PIN = None


class TDSSensor:
    """Driver for TDS meter sensors connected via ADC"""

    def __init__(self, pin=None, calibration_factor=None):
        """
        Initialize TDS sensor

        Args:
            pin: ADC pin number (default from config)
            calibration_factor: Calibration multiplier (default from config)
        """
        self.pin = pin or tds_config.ADC_PIN
        self.calibration_factor = calibration_factor or tds_config.TDS_CALIBRATION_FACTOR

        # Initialize ADC
        self.adc = machine.ADC(self.pin)

        # Temperature sensor (optional)
        self.temp_sensor = None
        self.temperature_measured = False
        if tds_config.USE_TEMP_COMPENSATION and tds_config.TEMP_PIN:
            self._init_temp_sensor()

        print(f"TDS Sensor initialized on GP{self.pin}")

    def _init_temp_sensor(self):
        """Initialize temperature sensor for compensation"""
        try:
            # DS18B20 on one-wire bus
            import onewire, ds18x20
            self.temp_pin = machine.Pin(tds_config.TEMP_PIN)
            self.temp_sensor = ds18x20.DS18X20(onewire.OneWire(self.temp_pin))
            print("Temperature sensor initialized")
        except ImportError:
            print("Warning: Temperature sensor libraries not available")
        except Exception as e:
            print(f"Warning: Could not init temp sensor: {e}")

    def read_voltage(self):
        """Read raw ADC value and convert to voltage"""
        raw = self.adc.read_u16()
        voltage = (raw / tds_config.ADC_RESOLUTION) * tds_config.VREF
        return voltage

    def read_temperature(self):
        """Read temperature if sensor available"""
        self.temperature_measured = False
        if not self.temp_sensor:
            return None

        try:
            devices = self.temp_sensor.scan()
            if devices:
                self.temp_sensor.convert_temp()
                time.sleep_ms(750)  # Wait for conversion
                value = self.temp_sensor.read_temp(devices[0])
                if isinstance(value, (int, float)) and -55 <= value <= 125:
                    self.temperature_measured = True
                    return value
        except Exception as e:
            print(f"Temp read error: {e}")

        return None

    def voltage_to_tds(self, voltage, temperature=25.0):
        """
        Convert voltage to TDS value (ppm)

        Args:
            voltage: ADC voltage reading
            temperature: Water temperature in Celsius

        Returns:
            TDS value in ppm
        """
        # Basic linear conversion (may need adjustment for your shield)
        tds = (voltage / tds_config.OUTPUT_MAX_VOLTAGE) * tds_config.TDS_MAX_PPM

        # Apply calibration factor
        tds *= self.calibration_factor

        # Temperature compensation (simplified)
        # TDS increases ~2% per °C above 25°C
        if temperature != 25.0:
            temp_factor = 1 + (temperature - 25.0) * 0.02
            tds *= temp_factor

        return max(0, tds)  # Ensure non-negative

    def read_tds(self, samples=None):
        """
        Read TDS value with averaging

        Args:
            samples: Number of samples to average (default from config)

        Returns:
            Dictionary with TDS value, voltage, and temperature
        """
        samples = samples or tds_config.SAMPLE_COUNT

        voltages = []
        for _ in range(samples):
            voltages.append(self.read_voltage())
            time.sleep_ms(10)

        avg_voltage = sum(voltages) / len(voltages)
        temperature = self.read_temperature()
        # 25 C is a compensation reference, never a reported measurement.
        tds = self.voltage_to_tds(avg_voltage, temperature if temperature is not None else 25.0)

        return {
            'tds_ppm': round(tds, 1),
            'voltage': round(avg_voltage, 3),
            'temperature': round(temperature, 1) if temperature is not None else None,
            'temperature_measured': self.temperature_measured,
            'raw_adc': int(self.adc.read_u16())
        }

    def calibrate(self, known_tds):
        """
        Auto-calibrate based on a known TDS solution

        Args:
            known_tds: Known TDS value in ppm of calibration solution

        Returns:
            New calibration factor
        """
        print(f"\nCalibrating with known TDS: {known_tds} ppm")
        print("Ensure sensor is in calibration solution...")

        time.sleep(2)  # Wait for stable reading

        reading = self.read_tds(samples=20)
        measured_tds = reading['tds_ppm']

        new_factor = self.calibration_factor * (known_tds / measured_tds)

        print(f"Measured: {measured_tds} ppm")
        print(f"New calibration factor: {new_factor:.4f}")

        self.calibration_factor = new_factor
        return new_factor


def main():
    """Test the TDS sensor"""
    print("TDS Sensor Test")
    print("=" * 40)

    sensor = TDSSensor()

    print("\nReading TDS values (Ctrl+C to stop)...")
    try:
        while True:
            reading = sensor.read_tds()
            print(f"TDS: {reading['tds_ppm']:6.1f} ppm | "
                  f"Voltage: {reading['voltage']:4.3f}V | "
                  f"Temp: {reading['temperature']}°C (None = unavailable)")
            time.sleep(tds_config.READ_INTERVAL)
    except KeyboardInterrupt:
        print("\nStopped by user")


if __name__ == "__main__":
    main()
