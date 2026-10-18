# TDS Sensor Configuration
# Adjust these values based on your specific TDS shield

# ADC Pin Configuration
ADC_PIN = 26  # GP26 (ADC0) - change if using different pin

# TDS Calibration
# Most TDS shields require calibration with a known solution
# Common calibration solution: 342 ppm
TDS_CALIBRATION_FACTOR = 0.5  # Adjust this value during calibration

# Temperature Compensation (if temperature sensor available)
# TDS readings vary with temperature
USE_TEMP_COMPENSATION = False
TEMP_PIN = None  # e.g., 27 for DS18B20 on GP27

# Reading Settings
READ_INTERVAL = 1.0  # Seconds between readings
SAMPLE_COUNT = 10  # Number of samples to average
ADC_RESOLUTION = 65535  # 16-bit ADC (0-65535)

# Voltage Reference
VREF = 3.3  # Pico ADC reference voltage in volts

# TDS Shield Output Range (check your shield specs)
# Most output 0-2.5V representing 0-1000 ppm or similar
OUTPUT_MAX_VOLTAGE = 2.5
TDS_MAX_PPM = 1000  # Maximum TDS value at max voltage
