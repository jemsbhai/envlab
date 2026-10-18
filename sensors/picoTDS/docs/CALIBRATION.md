# TDS Sensor Calibration Guide

## Why Calibrate?

TDS sensors need calibration because:
- Manufacturing tolerances vary between sensors
- Temperature affects readings
- Sensors drift over time
- Different TDS shields have different output ranges

## Calibration Equipment Needed

- TDS calibration solution (typically 342 ppm or 1413 µS/cm)
- Clean container for the solution
- TDS sensor/shield

## Calibration Procedure

### Step 1: Initial Setup

1. Upload the code to your Pico W
2. Configure WiFi settings in `config/wifi.py`
3. Run the TDS sensor test:
   ```python
   import tds_sensor
   sensor = tds_sensor.TDSSensor()
   ```

### Step 2: First Reading

1. Place the sensor in the calibration solution
2. Wait 30 seconds for the reading to stabilize
3. Note the displayed TDS value

### Step 3: Calculate Calibration Factor

The calibration factor adjusts the raw reading to match the known value:

```
new_factor = current_factor × (known_tds / measured_tds)
```

Example:
- Known TDS: 342 ppm
- Measured TDS: 400 ppm
- Current factor: 0.5
- New factor: 0.5 × (342 / 400) = 0.4275

### Step 4: Apply Calibration

#### Method A: Automatic Calibration

Run the calibration mode:
```python
import main
app = main.PicoTDS()
app.initialize()
app.calibrate(342)  # Use your known TDS value
```

#### Method B: Manual Calibration

1. Edit `config/tds_config.py`
2. Update `TDS_CALIBRATION_FACTOR` with your calculated value
3. Save and restart the Pico

### Step 5: Verify

1. Rinse the sensor with distilled water
2. Place back in calibration solution
3. Verify the reading now matches the known value
4. Repeat if necessary

## Multi-Point Calibration (Advanced)

For better accuracy across a range, calibrate at multiple points:

1. Calibrate with low TDS solution (e.g., 70 ppm)
2. Calibrate with high TDS solution (e.g., 1000 ppm)
3. Update the voltage-to-TDS conversion formula to use a curve instead of linear

## Temperature Compensation

If you have a temperature sensor (e.g., DS18B20):

1. Enable it in `config/tds_config.py`:
   ```python
   USE_TEMP_COMPENSATION = True
   TEMP_PIN = 27  # Your temperature sensor pin
   ```

2. The sensor will automatically adjust readings based on temperature

## Troubleshooting

### Readings are consistently too high
- Decrease the calibration factor
- Check for contamination on the sensor

### Readings are consistently too low
- Increase the calibration factor
- Check for air bubbles on the sensor

### Readings fluctuate wildly
- Ensure sensor is fully submerged
- Check electrical connections
- Increase `SAMPLE_COUNT` in config

### Calibration doesn't help
- Sensor may be damaged or at end of life
- Check if calibration solution is expired
- Verify power supply is stable

## Re-calibration Schedule

- Initial calibration: When first setting up
- Weekly: For continuous monitoring applications
- Monthly: For occasional use
- After: Any physical shock or exposure to extreme conditions
